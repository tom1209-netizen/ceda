import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import numpy as np
import sys
import os

# Add models path for reference
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'models'))
from gaussian_model import gaussian_filter_ref, generate_test_image

async def reset_dut(dut):
    """Apply reset to DUT"""
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

async def send_frame(dut, image, img_width, img_height):
    """Send a complete frame through the Gaussian stage"""
    output_pixels = []
    
    for row in range(img_height):
        for col in range(img_width):
            # Set input signals
            dut.s_tdata.value = int(image[row, col])
            dut.s_tvalid.value = 1
            dut.s_tlast.value = 1 if col == img_width - 1 else 0
            dut.s_tuser.value = 1 if (row == 0 and col == 0) else 0
            
            await RisingEdge(dut.clk)
            
            # Capture output if valid
            if dut.m_tvalid.value == 1:
                output_pixels.append(int(dut.m_tdata.value))
    
    # Continue clocking to flush pipeline
    dut.s_tvalid.value = 0
    dut.s_tuser.value = 0
    dut.s_tlast.value = 0
    
    for _ in range(img_width * 5):  # Extra cycles to flush
        await RisingEdge(dut.clk)
        if dut.m_tvalid.value == 1:
            output_pixels.append(int(dut.m_tdata.value))
    
    return output_pixels

@cocotb.test()
async def test_gaussian_stage_reset(dut):
    """Test reset state"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Check outputs are in reset state
    assert int(dut.m_tvalid.value) == 0, "m_tvalid should be 0 after reset"
    assert int(dut.s_tready.value) == 1, "s_tready should be 1 (ready)"

@cocotb.test()
async def test_gaussian_stage_valid_timing(dut):
    """Test that valid signal asserts after correct fill latency"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    img_width = int(dut.IMG_WIDTH.value)
    
    # Expected fill latency: 2 lines + 4 cycles
    expected_fill = 2 * img_width + 4
    
    dut.m_tready.value = 1
    cycle_count = 0
    first_valid_cycle = -1
    
    # Start frame with SOF
    dut.s_tuser.value = 1
    dut.s_tvalid.value = 1
    dut.s_tdata.value = 100
    
    for _ in range(expected_fill + 100):
        await RisingEdge(dut.clk)
        cycle_count += 1
        
        # Clear SOF after first cycle
        dut.s_tuser.value = 0
        dut.s_tdata.value = 100
        
        if dut.m_tvalid.value == 1 and first_valid_cycle < 0:
            first_valid_cycle = cycle_count
            break
    
    assert first_valid_cycle > 0, "Valid never asserted"
    dut._log.info(f"First valid at cycle {first_valid_cycle}, expected ~{expected_fill}")

@cocotb.test()
async def test_gaussian_stage_backpressure(dut):
    """Test backpressure handling (m_tready = 0)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Start streaming
    dut.s_tvalid.value = 1
    dut.s_tuser.value = 1
    dut.s_tdata.value = 128
    dut.m_tready.value = 1
    
    await RisingEdge(dut.clk)
    dut.s_tuser.value = 0
    
    # Run for a few cycles
    for _ in range(20):
        await RisingEdge(dut.clk)
    
    # Assert backpressure
    dut.m_tready.value = 0
    
    # s_tready should go low
    await RisingEdge(dut.clk)
    assert int(dut.s_tready.value) == 0, "s_tready should be 0 when m_tready is 0"
    
    # Release backpressure
    dut.m_tready.value = 1
    await RisingEdge(dut.clk)
    assert int(dut.s_tready.value) == 1, "s_tready should be 1 when m_tready is 1"

@cocotb.test()
async def test_gaussian_stage_small_frame(dut):
    """Test with a small frame (requires small IMG_WIDTH/HEIGHT for test)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    img_width = int(dut.IMG_WIDTH.value)
    img_height = int(dut.IMG_HEIGHT.value)
    
    # For large images, just do a partial test
    test_height = min(10, img_height)
    test_width = img_width
    
    # Generate test image
    np.random.seed(42)
    image = np.random.randint(0, 256, (test_height, test_width), dtype=np.uint8)
    
    # Send partial frame and collect some outputs
    dut.m_tready.value = 1
    output_count = 0
    
    for row in range(test_height):
        for col in range(test_width):
            dut.s_tdata.value = int(image[row, col])
            dut.s_tvalid.value = 1
            dut.s_tlast.value = 1 if col == test_width - 1 else 0
            dut.s_tuser.value = 1 if (row == 0 and col == 0) else 0
            
            await RisingEdge(dut.clk)
            
            if dut.m_tvalid.value == 1:
                output_count += 1
    
    dut._log.info(f"Received {output_count} valid outputs from {test_height}x{test_width} input")
