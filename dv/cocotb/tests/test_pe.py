import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

async def reset_dut(dut):
    """Apply reset to DUT"""
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.clear.value = 0
    dut.pixel.value = 0
    dut.coeff.value = 0
    dut.acc_in.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)

@cocotb.test()
async def test_pe_reset(dut):
    """Test reset clears accumulator"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    assert int(dut.acc_out.value) == 0, "acc_out should be 0 after reset"

@cocotb.test()
async def test_pe_single_mac(dut):
    """Test single MAC operation"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # First MAC with clear (starts fresh)
    dut.enable.value = 1
    dut.clear.value = 1
    dut.pixel.value = 10
    dut.coeff.value = 5
    dut.acc_in.value = 0
    
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)
    
    # Expected: 10 * 5 = 50
    assert int(dut.acc_out.value) == 50, f"Expected 50, got {int(dut.acc_out.value)}"

@cocotb.test()
async def test_pe_accumulate(dut):
    """Test accumulation from previous PE"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # MAC with incoming accumulator value
    dut.enable.value = 1
    dut.clear.value = 0
    dut.pixel.value = 10
    dut.coeff.value = 5
    dut.acc_in.value = 100  # Previous PE output
    
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    
    # Expected: 100 + (10 * 5) = 150
    assert int(dut.acc_out.value) == 150, f"Expected 150, got {int(dut.acc_out.value)}"

@cocotb.test()
async def test_pe_chain_simulation(dut):
    """Simulate a chain of MACs (what happens in a row of PEs)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Simulate 5-element chain: [10, 20, 30, 40, 50] * [1, 2, 3, 4, 5]
    pixels = [10, 20, 30, 40, 50]
    coeffs = [1, 2, 3, 4, 5]
    expected_sum = sum(p * c for p, c in zip(pixels, coeffs))
    # Expected: 10*1 + 20*2 + 30*3 + 40*4 + 50*5 = 10 + 40 + 90 + 160 + 250 = 550
    
    running_sum = 0
    dut.enable.value = 1
    
    for i, (p, c) in enumerate(zip(pixels, coeffs)):
        dut.clear.value = 1 if i == 0 else 0
        dut.pixel.value = p
        dut.coeff.value = c
        dut.acc_in.value = running_sum
        
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        
        running_sum = int(dut.acc_out.value)
    
    assert running_sum == expected_sum, f"Expected {expected_sum}, got {running_sum}"

@cocotb.test()
async def test_pe_gaussian_coefficients(dut):
    """Test with actual Gaussian kernel coefficients"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Row 0 of Gaussian kernel: [1, 4, 6, 4, 1] with uniform pixel 128
    coeffs = [1, 4, 6, 4, 1]
    pixel_val = 128
    expected_sum = sum(pixel_val * c for c in coeffs)  # 128 * 16 = 2048
    
    running_sum = 0
    dut.enable.value = 1
    dut.pixel.value = pixel_val
    
    for i, c in enumerate(coeffs):
        dut.clear.value = 1 if i == 0 else 0
        dut.coeff.value = c
        dut.acc_in.value = running_sum
        
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        
        running_sum = int(dut.acc_out.value)
    
    assert running_sum == expected_sum, f"Expected {expected_sum}, got {running_sum}"

@cocotb.test()
async def test_pe_enable_freeze(dut):
    """Test that PE freezes when enable is low"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Do one MAC
    dut.enable.value = 1
    dut.clear.value = 1
    dut.pixel.value = 100
    dut.coeff.value = 2
    dut.acc_in.value = 0
    
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    
    saved_value = int(dut.acc_out.value)
    
    # Disable and try to change
    dut.enable.value = 0
    dut.pixel.value = 255
    dut.coeff.value = 255
    
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    
    assert int(dut.acc_out.value) == saved_value, "acc_out should not change when enable is low"
