import os

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from PIL import Image


@cocotb.test()
async def image_sobel_test(dut):
    """Feeds an image through the Sobel filter and saves the outputs."""

    # 1. Configuration & Image Loading
    img_width = int(os.environ.get("IMG_WIDTH", "128"))
    img_height = int(os.environ.get("IMG_HEIGHT", "128"))
    expected_pixels = img_width * img_height

    module_dir = os.path.dirname(os.path.abspath(__file__))
    img_path = os.path.join(module_dir, "image_in.jpg")
    assert os.path.exists(img_path), f"'{img_path}' not found!"

    img = Image.open(img_path).convert("L").resize((img_width, img_height))
    flat_pixels = np.array(img, dtype=np.uint8).flatten()

    # 2. Pre-allocate Output Arrays (Massive Speedup)
    out_gx = np.zeros(expected_pixels, dtype=np.uint8)
    out_gy = np.zeros(expected_pixels, dtype=np.uint8)
    out_combined = np.zeros(expected_pixels, dtype=np.uint8)

    # 3. Start Clock & Initialize Signals
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axis_tuser.value = 0
    dut.m_axis_tready.value = 1

    # 4. Reset Sequence
    dut.resetn.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.resetn.value = 1
    await RisingEdge(dut.clk)

    # 5. Unified Driver & Monitor Loop
    sent = 0
    captured = 0

    while captured < expected_pixels:
        # Drive Inputs
        if sent < expected_pixels:
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tdata.value = int(flat_pixels[sent])
            dut.s_axis_tuser.value = 1 if sent == 0 else 0
            dut.s_axis_tlast.value = 1 if (sent + 1) % img_width == 0 else 0
        else:
            dut.s_axis_tvalid.value = 0
            dut.s_axis_tuser.value = 0
            dut.s_axis_tlast.value = 0

        # Step the clock exactly ONCE per iteration
        await RisingEdge(dut.clk)

        # Check if DUT accepted the input
        if sent < expected_pixels and dut.s_axis_tready.value == 1:
            sent += 1

        # Check if DUT produced an output
        if dut.m_axis_tvalid.value == 1 and dut.m_axis_tready.value == 1:
            out_gx[captured] = int(dut.m_axis_gx_tdata.value)
            out_gy[captured] = int(dut.m_axis_gy_tdata.value)
            out_combined[captured] = int(dut.m_axis_tdata.value) & 0xFF
            captured += 1

    dut.s_axis_tvalid.value = 0

    # 6. Save Outputs
    Image.fromarray(out_gx.reshape((img_height, img_width))).save("image_out_gx.jpg")
    Image.fromarray(out_gy.reshape((img_height, img_width))).save("image_out_gy.jpg")
    Image.fromarray(out_combined.reshape((img_height, img_width))).save(
        "image_out_combined.jpg"
    )
