import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from tests.trace import traced_test
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "models"))
from gaussian_model import gaussian_filter_ref


def _load_grayscale_png(path: str) -> np.ndarray:
    from PIL import Image

    img = Image.open(path).convert("L")
    arr = np.asarray(img, dtype=np.uint8)
    if arr.ndim != 2:
        raise ValueError(f"Expected a grayscale image, got shape {arr.shape} from {path}")
    return arr


def _resize_nearest(image: np.ndarray, *, width: int, height: int) -> np.ndarray:
    src_h, src_w = image.shape
    if (src_w, src_h) == (width, height):
        return image

    x_idx = (np.arange(width, dtype=np.int64) * src_w) // width
    y_idx = (np.arange(height, dtype=np.int64) * src_h) // height
    return image[np.ix_(y_idx, x_idx)]


async def _reset_dut(dut):
    dut.rst_n.value = 0
    dut.s_tdata.value = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value = 0
    dut.s_tuser.value = 0
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def _try_int(v):
    try:
        return int(v)
    except ValueError:
        return None


async def _stream_frame_and_capture(dut, image: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    img_height, img_width = image.shape
    in_flat = image.reshape(-1)

    outputs = np.zeros(in_flat.size, dtype=np.uint8)
    resolved = np.zeros(in_flat.size, dtype=np.bool_)
    out_count = 0

    dut.m_tready.value = 1
    dut.s_tvalid.value = 1

    for i, pixel in enumerate(in_flat):
        dut.s_tdata.value = int(pixel)
        dut.s_tuser.value = 1 if i == 0 else 0
        dut.s_tlast.value = 1 if (i % img_width) == (img_width - 1) else 0

        await RisingEdge(dut.clk)

        if _try_int(dut.m_tvalid.value) == 1:
            m_data = _try_int(dut.m_tdata.value)
            if m_data is not None:
                outputs[out_count] = m_data
                resolved[out_count] = True
            out_count += 1

    dut.s_tvalid.value = 0
    dut.s_tuser.value = 0
    dut.s_tlast.value = 0
    await RisingEdge(dut.clk)

    return outputs[:out_count], resolved[:out_count]


def _best_alignment_offset(
    observed: np.ndarray,
    observed_resolved: np.ndarray,
    expected_flat: np.ndarray,
    *,
    max_offset: int,
    sample_len: int,
) -> tuple[int, float]:
    if observed.size == 0 or expected_flat.size == 0:
        raise ValueError("Empty streams for alignment")

    # Spread samples across the observed stream; using only the start can pick a
    # locally-good but globally-wrong offset when there are transient regions.
    chunk_len = min(2048, sample_len, observed.size)
    if chunk_len <= 0:
        raise ValueError("Invalid alignment chunk length")

    starts = [0]
    if observed.size > chunk_len:
        starts = [
            0,
            (observed.size - chunk_len) // 3,
            2 * (observed.size - chunk_len) // 3,
            observed.size - chunk_len,
        ]

    max_offset = min(max_offset, expected_flat.size - (starts[-1] + chunk_len))
    best_offset = 0
    best_err = float("inf")
    for offset in range(max_offset + 1):
        errs = []
        for start in starts:
            obs = observed[start : start + chunk_len].astype(np.int16)
            res = observed_resolved[start : start + chunk_len]
            if not bool(np.any(res)):
                continue
            exp = expected_flat[offset + start : offset + start + chunk_len].astype(np.int16)
            errs.append(float(np.mean(np.abs(obs[res] - exp[res]))))
        if not errs:
            continue
        err = float(np.mean(errs))
        if err < best_err:
            best_err = err
            best_offset = offset
            if best_err == 0.0:
                break
    return best_offset, best_err


@traced_test(trace_dir="waveform_dump/test_gaussian_real_image")
async def test_gaussian_stage_real_image_1080p(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    await _reset_dut(dut)

    here = os.path.dirname(__file__)
    img_dir = os.path.join(here, "test_output")
    input_path = os.path.join(img_dir, "input_pattern.png")
    expected_path = os.path.join(img_dir, "expected_pattern.png")

    if not os.path.exists(input_path):
        raise AssertionError(f"Missing test image: {input_path}")

    image = _load_grayscale_png(input_path)
    dut_w = int(dut.IMG_WIDTH.value)
    dut_h = int(dut.IMG_HEIGHT.value)
    image = _resize_nearest(image, width=dut_w, height=dut_h)
    img_height, img_width = image.shape

    if os.path.exists(expected_path) and (img_width, img_height) == (1920, 1080):
        expected_img = _load_grayscale_png(expected_path)
    else:
        expected_img = gaussian_filter_ref(image, use_rounding=True)

    expected_flat = expected_img.reshape(-1)

    observed, observed_resolved = await _stream_frame_and_capture(dut, image)
    if observed.size == 0:
        raise AssertionError("No output samples observed (m_tvalid never asserted)")

    # Heuristic: search within a couple lines for the best alignment into the expected stream.
    offset, align_err = _best_alignment_offset(
        observed,
        observed_resolved,
        expected_flat,
        max_offset=(2 * img_width + 256),
        sample_len=8192,
    )
    dut._log.info(f"Best alignment offset={offset}, mean_abs_err={align_err:.4f}")

    compare_len = min(observed.size, expected_flat.size - offset)
    if compare_len <= 0:
        raise AssertionError("Alignment offset places expected window out of range")

    obs_cmp = observed[:compare_len].astype(np.int16)
    exp_cmp = expected_flat[offset : offset + compare_len].astype(np.int16)

    idx = np.arange(compare_len, dtype=np.int64) + offset
    cols = idx % img_width
    rows = idx // img_width
    interior_cols = (cols >= 4) & (cols < (img_width - 4))
    interior_rows = (rows >= 4) & (rows < (img_height - 4))
    mask = observed_resolved[:compare_len] & interior_cols & interior_rows
    if not bool(np.any(mask)):
        raise AssertionError("No comparable samples (all X/Z or filtered out)")

    diffs = np.abs(obs_cmp[mask] - exp_cmp[mask])
    max_diff = int(diffs.max(initial=0))
    mean_diff = float(diffs.mean())
    dut._log.info(
        f"Compared {int(np.count_nonzero(mask))}/{compare_len} samples "
        f"(mean_abs_diff={mean_diff:.4f}, max_abs_diff={max_diff})"
    )

    save_outputs = os.environ.get("GAUSSIAN_SAVE_OUTPUT", "") not in ("", "0", "false", "False")
    if save_outputs:
        from PIL import Image

        # Keep output artifacts minimal: only the aligned RTL output and the abs-diff image.
        for stale_name in (
            "rtl_output_stream_padded.png",
            "rtl_output_stream_aligned.png",
            "rtl_output_stream_interior.png",
            "rtl_expected_absdiff.png",
        ):
            stale_path = os.path.join(img_dir, stale_name)
            if os.path.exists(stale_path):
                os.remove(stale_path)

        aligned = np.zeros(expected_flat.size, dtype=np.uint8)
        n_al = min(observed.size, expected_flat.size - offset)
        if n_al > 0:
            aligned[offset : offset + n_al] = observed[:n_al]
        aligned_img = aligned.reshape(img_height, img_width)
        Image.fromarray(aligned_img, mode="L").save(
            os.path.join(img_dir, "rtl_output.png")
        )

        absdiff = np.abs(aligned_img.astype(np.int16) - expected_img.astype(np.int16)).astype(np.uint8)
        # Mask out pixels we intentionally did not compare (border + unresolved X/Z).
        mask_flat = np.zeros(expected_flat.size, dtype=np.bool_)
        mask_flat[offset : offset + compare_len] = mask
        absdiff[~mask_flat.reshape(img_height, img_width)] = 0
        Image.fromarray(absdiff, mode="L").save(os.path.join(img_dir, "rtl_expected_absdiff.png"))

    assert max_diff <= 1, (
        f"RTL vs expected mismatch: compare_len={compare_len}, offset={offset}, "
        f"mean_abs_diff={mean_diff:.4f}, max_abs_diff={max_diff}"
    )
