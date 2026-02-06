import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import numpy as np

async def reset_dut(dut):
    """Apply reset to DUT"""
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.pixel_in.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_row_buffer_basic(dut):
    """Test basic row buffering functionality"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    width = int(dut.LINE_WIDTH.value)
    
    # Enable module
    dut.enable.value = 1
    
    # Feed test pattern: Line 0 has value 0, Line 1 has 1, etc.
    # We want to see if rows appear at the outputs in correct order.
    # row_4 is current input. row_0 is delayed by 4 lines.
    
    num_lines = 10
    
    for line_idx in range(num_lines):
        pixel_val = line_idx % 256
        for col in range(width):
            dut.pixel_in.value = pixel_val
            await RisingEdge(dut.clk)
            
            # Check outputs
            # row_4 should equal input (pixel_val) immediately (assuming 0 delay from input to row_4, but check RTL)
            # RTL: assign row_4 = row_delay[4][3]; row_delay[4][0]<=input. Wait, logic trace:
            # lb_out[4] = input.
            # row_delay[4][0] <= lb_out[4] = input.
            # row_delay[4][1] <= [0]
            # row_delay[4][2] <= [1]
            # row_delay[4][3] <= [2]
            # row_4 = [3].
            # So row_4 is delayed by 4 clock cycles relative to input.
            
            # row_0 is from lb_out[0].
            # lb_out[4] (input) -> LB3 -> lb_out[3] -> LB2 -> lb_out[2] -> LB1 -> lb_out[1] -> LB0 -> lb_out[0].
            # Each LB adds 'width' delay? No, LB reads then writes.
            # line_buffer: data_out <= buffer[addr]; buffer[addr] <= data_in; addr++.
            # So delay is exactly 'width' cycles if addr starts at 0.
            
            # Since we have Per-Row Delays (`row_delay`), all rows should be ALIGNED.
            # This means `row_0` at time T should be the same column as `row_4` at time T.
            # But `row_0` is from 4 lines ago.
            # So if input is Line N, Col C.
            # row_4 should output Line N, Col C (delayed by alignment latency).
            # row_0 should output Line N-4, Col C (delayed by same alignment latency).
            
            # The alignment latency is MAX_ROW_DELAY = 4 cycles.
            # So verify: output at T corresponds to input at T-4.
            pass

    # Basic verification logic:
    # Just check that after N lines, we see line N at row_4, line N-1 at row_3...
    
    dut._log.info("Finished driving lines")

@cocotb.test()
async def test_row_buffer_verify_content(dut):
    """Verify exact content with random data"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    dut.enable.value = 1
    
    width = 100 # Small width for test speed if parameter settable (test_row_buffer targets LINE_WIDTH=32)
    # The Makefile sets LINE_WIDTH=32.
    width = 32
    
    # Generate 10 lines of data
    lines = []
    for i in range(10):
        lines.append(np.random.randint(0, 256, width, dtype=np.int32))
        
    # Drive and monitor
    # Alignment latency is 4 cycles.
    LATENCY = 4 
    
    # To check output at cycle T (processing col C of line L), we need valid history.
    
    for l_idx in range(10):
        current_line = lines[l_idx]
        for c_idx in range(width):
            dut.pixel_in.value = int(current_line[c_idx])
            await RisingEdge(dut.clk)
            
            # Check outputs after latency
            # At cycle (l_idx * width + c_idx) + 1 (next EDGE), signals are updated.
            # But we are AT the RisingEdge. The signals reflect state from PREVIOUS edge.
            # row_4 should correspond to value driven 4 cycles ago?
            
            # Ideally, capture expected inputs in a FIFO and compare outputs.
            pass

    # Let's use a simpler check:
    # After feeding Line 5 complete.
    # row_4 should output Line 5.
    # row_3 should output Line 4.
    # ...
    # row_0 should output Line 1.
    # All horizontally aligned.
    
    # Restart validation
    await reset_dut(dut)
    dut.enable.value = 1
    
    received_rows = [[], [], [], [], []]
    
    # Feed 10 lines
    for l_idx in range(10):
        for c_idx in range(width):
            dut.pixel_in.value = int(lines[l_idx][c_idx])
            await RisingEdge(dut.clk)
            
            # Capture outputs
            # Valid data starts appearing after initial fill.
            # Due to 4 cycle alignment delay, we expect valid data for col 0 at cycle 4.
            # But we just simplify: capture everything, align later.
            received_rows[0].append(int(dut.row_0.value))
            received_rows[1].append(int(dut.row_1.value))
            received_rows[2].append(int(dut.row_2.value))
            received_rows[3].append(int(dut.row_3.value))
            received_rows[4].append(int(dut.row_4.value))
            
    # Flush
    dut.pixel_in.value = 0
    for _ in range(300):
        await RisingEdge(dut.clk)
        received_rows[0].append(int(dut.row_0.value))
        received_rows[1].append(int(dut.row_1.value))
        received_rows[2].append(int(dut.row_2.value))
        received_rows[3].append(int(dut.row_3.value))
        received_rows[4].append(int(dut.row_4.value))

    # Verification
    # row_4 should match lines[0], lines[1]... delayed by 4 cycles.
    # row_3 should match lines[0]... delayed by 4 cycles + 1 line (width).
    
    # Check row_4
    # Expected: 4 zeros, then Line 0, Line 1...
    # Actual: received_rows[4]
    
    def check_stream(name, actual, expected_lines, delay_cycles):
        # Construct expected stream
        expected_stream = []
        for l in expected_lines:
            expected_stream.extend(l)
            
        # Check alignment
        # Search for first 10 pixels of expected in actual
        # or simplified: actual[delay] == expected[0]
        
        subset = actual[delay_cycles : delay_cycles + len(expected_stream)]
        if len(subset) < len(expected_stream):
             dut._log.error(f"{name}: Not enough data. Got {len(subset)}, want {len(expected_stream)}")
             return False
             
        diffs = np.array(subset) - np.array(expected_stream)
        if np.any(diffs != 0):
            dut._log.error(f"{name}: Mismatch. First 10 expected: {expected_stream[:10]}")
            dut._log.error(f"{name}: Mismatch. First 10 actual(offset): {subset[:10]}")
            return False
        return True

    # ROW 4: Input, aligned 4 cycles.
    assert check_stream("row_4", received_rows[4], lines, 4)
    
    # ROW 3: Line buffer 3. Should be 1 line behind row_4.
    assert check_stream("row_3", received_rows[3], lines, 4 + width)
    
    # ROW 2: Delayed by 2*width
    assert check_stream("row_2", received_rows[2], lines, 4 + 2*width)
    
    # ROW 1: Delayed by 3*width
    assert check_stream("row_1", received_rows[1], lines, 4 + 3*width)
    
    # ROW 0: Delayed by 4*width
    assert check_stream("row_0", received_rows[0], lines, 4 + 4*width)
    
    dut._log.info("All rows verified correctly")
