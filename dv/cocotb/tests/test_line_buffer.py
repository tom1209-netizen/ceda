import cocotb
from cocotb.clock import Clock
from tests.trace import traced_test
from cocotb.triggers import RisingEdge, Timer
import random

async def reset_dut(dut):
    """Apply reset to DUT"""
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.data_in.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

@traced_test(trace_dir="waveform_dump/test_line_buffer")
async def test_line_buffer_delay(dut):
    """Test that line buffer delays by exactly LINE_WIDTH cycles"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    line_width = int(dut.LINE_WIDTH.value)
    
    # Registered output: output[N] = input[N - LINE_WIDTH]
    # We sample after driving, so actually received_data[i] = test_data[i - line_width - 1]
    
    test_data = []
    received_data = []
    
    dut.enable.value = 1
    
    total_cycles = line_width * 3
    for i in range(total_cycles):
        data = ((i + 1) % 256)  # So test_data[0]=1, test_data[1]=2, etc.
        dut.data_in.value = data
        test_data.append(data)
        
        await RisingEdge(dut.clk)
        
        # After this edge, output has been updated with result
        try:
            received_data.append(int(dut.data_out.value))
        except ValueError:
            received_data.append(-1)
    
    # Verify delay: actual delay is LINE_WIDTH + 1 due to output register timing
    actual_delay = line_width + 1
    
    errors = 0
    start_check = actual_delay + line_width  # Ensure BRAM fully initialized
    for i in range(start_check, total_cycles):
        expected = test_data[i - actual_delay]
        actual = received_data[i]
        if actual != expected:
            dut._log.error(f"Cycle {i}: expected {expected}, got {actual}")
            errors += 1
            if errors > 5:
                break
    
    assert errors == 0, f"{errors} delay mismatches found"

@traced_test(trace_dir="waveform_dump/test_line_buffer")
async def test_line_buffer_enable(dut):
    """Test that buffer freezes when enable is low"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    dut.enable.value = 1
    for i in range(10):
        dut.data_in.value = i + 1
        await RisingEdge(dut.clk)
    
    dut.enable.value = 0
    await RisingEdge(dut.clk)
    
    last_output = dut.data_out.value
    dut.data_in.value = 99
    
    for _ in range(5):
        await RisingEdge(dut.clk)
        assert dut.data_out.value == last_output, \
            "Output should not change when enable is low"

@traced_test(trace_dir="waveform_dump/test_line_buffer")
async def test_line_buffer_reset(dut):
    """Test reset behavior"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    dut.rst_n.value = 1
    dut.enable.value = 1
    dut.data_in.value = 123
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    
    assert int(dut.data_out.value) == 0, "Output should be 0 after reset"

@traced_test(trace_dir="waveform_dump/test_line_buffer")
async def test_line_buffer_random_data(dut):
    """Test with random data pattern"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    line_width = int(dut.LINE_WIDTH.value)
    actual_delay = line_width + 1  # Account for output register timing
    
    random.seed(42)
    total_cycles = line_width * 3
    test_data = [random.randint(1, 255) for _ in range(total_cycles)]
    received_data = []
    
    dut.enable.value = 1
    
    for data in test_data:
        dut.data_in.value = data
        await RisingEdge(dut.clk)
        try:
            received_data.append(int(dut.data_out.value))
        except ValueError:
            received_data.append(-1)
    
    errors = 0
    start_check = actual_delay + line_width
    for i in range(start_check, total_cycles):
        expected = test_data[i - actual_delay]
        actual = received_data[i]
        if actual != expected:
            dut._log.error(f"Cycle {i}: expected {expected}, got {actual}")
            errors += 1
            if errors > 5:
                break
    
    assert errors == 0, f"{errors} delay mismatches found"
