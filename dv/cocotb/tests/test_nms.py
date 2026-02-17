import json
import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


# NMS direction constants
DIR_EW = 0
DIR_NE_SW = 1
DIR_NS = 2
DIR_NW_SE = 3


class WaveformDumper:
    def __init__(self, dut, signals):
        self.dut = dut
        self.signals = signals
        self.data = []
        self.cycle = 0
        self.task = None

    async def start(self):
        self.task = cocotb.start_soon(self._monitor())

    async def _monitor(self):
        while True:
            await RisingEdge(self.dut.clk)
            sample = {"cycle": self.cycle}
            for name in self.signals:
                try:
                    raw = getattr(self.dut, name).value
                    try:
                        sample[name] = int(raw)
                    except ValueError:
                        sample[name] = str(raw)
                except Exception:
                    sample[name] = "ERR"
            self.data.append(sample)
            self.cycle += 1

    def dump_to_file(self, filename="waveform.json"):
        if self.task is not None:
            self.task.cancel()
        with open(filename, "w", encoding="utf-8") as fp:
            json.dump(self.data, fp, indent=2)


async def reset_dut(dut):
    dut.rst_n.value = 0
    dut.s_tvalid.value = 0
    dut.s_tdata.value = 0
    dut.s_tuser.value = 0
    dut.s_tlast.value = 0
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def _pack_pixel(mag, direction):
    return (int(direction) << 12) | int(mag)


def _check_axi_sideband(dut):
    m_valid = int(dut.m_tvalid.value)
    m_last = int(dut.m_tlast.value)
    m_user = int(dut.m_tuser.value)
    assert not (m_last and not m_valid), "m_tlast asserted when m_tvalid=0"
    assert not (m_user and not m_valid), "m_tuser asserted when m_tvalid=0"


def _capture_handshake_output(dut, outputs):
    if int(dut.m_tvalid.value) and int(dut.m_tready.value):
        outputs.append(
            {
                "data": int(dut.m_tdata.value),
                "last": int(dut.m_tlast.value),
                "user": int(dut.m_tuser.value),
            }
        )


async def send_frame(dut, mag_image, dir_image, outputs):
    height, width = mag_image.shape
    for r in range(height):
        for c in range(width):
            dut.s_tdata.value = _pack_pixel(mag_image[r, c], dir_image[r, c])
            dut.s_tvalid.value = 1
            dut.s_tuser.value = 1 if (r == 0 and c == 0) else 0
            dut.s_tlast.value = 1 if c == (width - 1) else 0

            while True:
                will_accept = int(dut.s_tready.value) == 1
                await RisingEdge(dut.clk)
                _check_axi_sideband(dut)
                _capture_handshake_output(dut, outputs)
                if will_accept:
                    break

    dut.s_tvalid.value = 0
    dut.s_tuser.value = 0
    dut.s_tlast.value = 0


async def sample_idle(dut, outputs, cycles):
    start_len = len(outputs)
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        _check_axi_sideband(dut)
        _capture_handshake_output(dut, outputs)
    return len(outputs) - start_len


async def drain_then_check_idle(dut, outputs, width):
    # Tail depth is dominated by one line delay plus short local pipelines.
    drain_out = await sample_idle(dut, outputs, cycles=width + 8)
    quiet_out = await sample_idle(dut, outputs, cycles=8)
    return drain_out, quiet_out


@cocotb.test()
async def test_nms_basic_vertical(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    width = int(dut.IMG_WIDTH.value)
    height = max(8, width // 2)
    assert width >= 5, "IMG_WIDTH must be >= 5 for this test pattern"

    mag_image = np.zeros((height, width), dtype=np.uint16)
    dir_image = np.full((height, width), DIR_EW, dtype=np.uint8)

    center = width // 2
    for r in range(height):
        mag_image[r, center - 2] = 50
        mag_image[r, center - 1] = 100
        mag_image[r, center] = 255
        mag_image[r, center + 1] = 100
        mag_image[r, center + 2] = 50

    outputs = []
    await send_frame(dut, mag_image, dir_image, outputs)
    _, quiet_out = await drain_then_check_idle(dut, outputs, width)

    out_vals = [o["data"] for o in outputs]
    assert 255 in out_vals, "Did not find expected peak value in NMS output"

    count_100 = out_vals.count(100)
    assert count_100 <= 6, f"Too many unsuppressed 100-valued pixels: {count_100}"
    assert quiet_out == 0, f"Output did not go idle after drain, extra beats={quiet_out}"


@cocotb.test()
async def test_nms_diagonal_suppression(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    width = int(dut.IMG_WIDTH.value)
    height = max(10, width)

    mag_image = np.zeros((height, width), dtype=np.uint16)
    dir_image = np.full((height, width), DIR_NE_SW, dtype=np.uint8)

    # Center pixel should be suppressed by larger NE neighbor.
    r = min(5, height - 2)
    c = min(5, width - 2)
    mag_image[r, c] = 100
    mag_image[r - 1, c + 1] = 255
    mag_image[r + 1, c - 1] = 50

    outputs = []
    await send_frame(dut, mag_image, dir_image, outputs)
    _, quiet_out = await drain_then_check_idle(dut, outputs, width)

    out_vals = [o["data"] for o in outputs]
    assert 255 in out_vals, "Expected max pixel did not appear"
    assert 100 not in out_vals, "Suppressed pixel leaked through output"
    assert quiet_out == 0, f"Output did not go idle after drain, extra beats={quiet_out}"


@cocotb.test()
async def test_nms_stream_integrity_waveform(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    width = int(dut.IMG_WIDTH.value)
    height = max(5, width // 2)

    np.random.seed(42)
    mag_image = np.random.randint(0, 256, (height, width), dtype=np.uint16)
    dir_image = np.random.randint(0, 4, (height, width), dtype=np.uint8)

    signals_to_dump = [
        "clk",
        "rst_n",
        "s_tdata",
        "s_tvalid",
        "s_tready",
        "s_tlast",
        "s_tuser",
        "m_tdata",
        "m_tvalid",
        "m_tready",
        "m_tlast",
        "m_tuser",
        "enable",
        "flush_active",
        "frame_active",
        "pending_count",
        "stream_primed",
        "seen_first_line",
        "in_col",
        "u_pipe",
        "l_pipe",
        "v_pipe",
    ]

    dumper = WaveformDumper(dut, signals_to_dump)
    await dumper.start()

    outputs = []
    await send_frame(dut, mag_image, dir_image, outputs)
    _, quiet_out = await drain_then_check_idle(dut, outputs, width)
    await RisingEdge(dut.clk)

    waveform_path = os.path.join(os.getcwd(), "waveform.json")
    dumper.dump_to_file(waveform_path)

    user_count = sum(o["user"] for o in outputs)
    last_count = sum(o["last"] for o in outputs)
    assert len(outputs) == (width * height), (
        f"Expected {width * height} output beats, got {len(outputs)}"
    )
    assert last_count == height, f"Expected {height} output EOL pulses, got {last_count}"
    assert user_count <= 1, f"Expected at most one output SOF pulse, got {user_count}"
    assert quiet_out == 0, f"Output did not go idle after drain, extra beats={quiet_out}"


@cocotb.test()
async def test_nms_small_5x5(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    width = int(dut.IMG_WIDTH.value)
    height = 5
    if width != 5:
        dut._log.info(
            "Skipping test_nms_small_5x5 because IMG_WIDTH=%d (run with NMS_IMG_WIDTH=5)",
            width,
        )
        return

    # Deterministic small pattern for manual waveform inspection.
    mag_image = np.array(
        [
            [10, 20, 30, 40, 50],
            [15, 25, 35, 45, 55],
            [60, 70, 250, 80, 90],
            [16, 26, 36, 46, 56],
            [11, 21, 31, 41, 51],
        ],
        dtype=np.uint16,
    )
    dir_image = np.full((height, width), DIR_EW, dtype=np.uint8)

    signals_to_dump = [
        "clk",
        "rst_n",
        "s_tdata",
        "s_tvalid",
        "s_tready",
        "s_tlast",
        "s_tuser",
        "m_tdata",
        "m_tvalid",
        "m_tready",
        "m_tlast",
        "m_tuser",
        "enable",
        "flush_active",
        "frame_active",
        "pending_count",
        "stream_primed",
        "seen_first_line",
        "in_col",
        "u_pipe",
        "l_pipe",
        "v_pipe",
    ]

    dumper = WaveformDumper(dut, signals_to_dump)
    await dumper.start()

    outputs = []
    await send_frame(dut, mag_image, dir_image, outputs)
    _, quiet_out = await drain_then_check_idle(dut, outputs, width)
    await RisingEdge(dut.clk)

    waveform_path = os.path.join(os.getcwd(), "waveform_nms_small.json")
    dumper.dump_to_file(waveform_path)

    user_count = sum(o["user"] for o in outputs)
    last_count = sum(o["last"] for o in outputs)
    assert len(outputs) == 25, f"Expected 25 output beats, got {len(outputs)}"
    assert user_count == 1, f"Expected one output SOF pulse, got {user_count}"
    assert last_count == 5, f"Expected five output EOL pulses, got {last_count}"
    assert quiet_out == 0, f"Output did not go idle after drain, extra beats={quiet_out}"
