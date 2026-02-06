import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'models'))

from gaussian_model import GAUSSIAN_KERNEL, gaussian_single_window

async def reset_dut(dut):
    """Apply reset to DUT"""
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.win_row_0.value = 0
    dut.win_row_1.value = 0
    dut.win_row_2.value = 0
    dut.win_row_3.value = 0
    dut.win_row_4.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

def drive_rows(dut, col_values):
    """Drive the 5 row inputs with a list/array of 5 values (one for each row)"""
    dut.win_row_0.value = int(col_values[0])
    dut.win_row_1.value = int(col_values[1])
    dut.win_row_2.value = int(col_values[2])
    dut.win_row_3.value = int(col_values[3])
    dut.win_row_4.value = int(col_values[4])

@cocotb.test()
async def test_gaussian_streaming(dut):
    """Test Gaussian core with streaming inputs against python reference"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    dut.enable.value = 1
    
    # Generate random image strip: 5 rows x N columns
    # We verify the output by taking sliding 5x5 windows of this strip
    width = 100
    # Use random values 0-255
    image_strip = np.random.randint(0, 256, (5, width), dtype=np.int32)
    
    expected_outputs = []
    # Calculate expected outputs
    # The DUT produces a valid output for every valid 5x5 window.
    # If we stream columns 0..width-1.
    # The first valid 5x5 window comprises columns 0,1,2,3,4.
    # The DUT latency is somewhat implementation dependent, but logically:
    # After feeding col 0..4 (5 cycles), the pipeline should have the result for window represented by cols 0..4.
    # The reference model `gaussian_single_window` takes a 5x5 array.
    
    for c in range(width - 5 + 1):
        window = image_strip[:, c:c+5]
        expected_outputs.append(gaussian_single_window(window, use_rounding=True))
        
    actual_outputs = []
    
    # Drive inputs
    # Need to handle latency. 
    # We feed column 0, then 1... 
    # Capture outputs.
    
    for c in range(width):
        col_vals = image_strip[:, c]
        drive_rows(dut, col_vals)
        await RisingEdge(dut.clk)
        
        # Capture output if valid? 
        # Or just capture everything and align later.
        # The valid_out signal should indicate when meaningful data is present.
        if dut.valid_out.value:
            actual_outputs.append(int(dut.pixel_out.value))
            
    # Flush pipeline
    drive_rows(dut, [0]*5)
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.valid_out.value:
            actual_outputs.append(int(dut.pixel_out.value))

    # Compare
    # The DUT might have some warmup latency before asserting valid_out.
    # We expect `len(expected_outputs)` valid outputs.
    # We should find the expected sequence within the actual sequence.
    
    # Trim to size
    # Based on the implementation:
    # OUT_LATENCY = 6. 
    # Cycle 0: Feed Col 0. PE0 has it.
    # ...
    # Cycle 4: Feed Col 4. PE4 has it. Sum ready at Cycle 5 inputs -> Reg -> Output at Cycle 6?
    # Let's align dynamically to be safe.
    
    matched = False
    for delay in range(10):
        # Slice actual to valid length
        # expected has length N. actual should have length >= N.
        subset = actual_outputs[delay : delay + len(expected_outputs)]
        if len(subset) == len(expected_outputs):
            diffs = np.array(subset) - np.array(expected_outputs)
            max_diff = np.max(np.abs(diffs))
            if max_diff <= 1:
                matched = True
                dut._log.info(f"Matched with delay offset {delay}. Max diff: {max_diff}")
                break
                
    if not matched:
        dut._log.error(f"Length expected: {len(expected_outputs)}, actual: {len(actual_outputs)}")
        dut._log.error(f"First 10 expected: {expected_outputs[:10]}")
        dut._log.error(f"First 10 actual:   {actual_outputs[:10]}")
        assert False, "Output sequence did not match expected convolution"

@cocotb.test()
async def test_impulse(dut):
    """Test impulse response (center pixel 255)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    dut.enable.value = 1
    
    # Create impulse sequence logic
    # K matrix center is at [2][2] (using 0-based indices).
    # Coeff is 36.
    # To hit K[2][2], we need row 2 to have value 255 at the appropriate time.
    # If we feed 255 at time T, and 0 otherwise.
    # The sum calculates sum(input[t-i] * K[i]).
    # K[0] pairs with input[t]. K[1] pairs with input[t-1]... K[2] pairs with input[t-2].
    # So if input is at t=0, it hits K[2] at output time corresponding to t=2 inputs later?
    # Simply put: we feed a sequence where col 2 is 255 (index 2 in 0..4).
    # Cols 0,1 = 0. Col 2 = 255. Cols 3,4 = 0.
    
    impulse_strip = np.zeros((5, 20), dtype=np.int32)
    impulse_strip[2, 2] = 255 # Impulse at col 2, row 2
    
    # Expected output for the window centered at this impulse:
    # The window at col 0 covers cols 0..4.
    # This window [0,0,255,0,0] (row 2) will align with the kernel row: [6, 24, 36, 24, 6]
    # Wait, simple math:
    # If window is [0, 0, 255, 0, 0]
    # And Kernel is [6, 24, 36, 24, 6]
    # Dot product is 255 * 36.
    # The output should be (255*36 + 128) >> 8 = 36.
    
    # We want to see '36' somewhere in the output.
    
    actual_outputs = []
    
    for c in range(20):
        drive_rows(dut, impulse_strip[:, c])
        await RisingEdge(dut.clk)
        if dut.valid_out.value:
            actual_outputs.append(int(dut.pixel_out.value))
            
    assert 36 in actual_outputs, f"Impulse response 36 not found in {actual_outputs}"

