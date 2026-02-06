import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import numpy as np
import sys
import os

# NMS direction constants
DIR_EW = 0
DIR_NE_SW = 1
DIR_NS = 2
DIR_NW_SE = 3

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

@cocotb.test()
async def test_nms_basic_vertical(dut):
    """Test NMS with a simple vertical edge (Gradient Horizontal -> Direction East-West)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    
    width = 20
    height = 10
    
    # Construct input frame
    # Vertical edge at col 10
    # Gradient Direction should be Horizontal (0 = E-W)
    # Magnitude profile around col 10: 50, 100, 255, 100, 50
    # Expected output: Only the 255 should survive. Neighbors 100 should be suppressed.
    
    mag_image = np.zeros((height, width), dtype=np.uint16)
    dir_image = np.zeros((height, width), dtype=np.uint8)
    
    for r in range(height):
        mag_image[r, 8]  = 50
        mag_image[r, 9]  = 100
        mag_image[r, 10] = 255 # Max
        mag_image[r, 11] = 100
        mag_image[r, 12] = 50
        
        # Direction 0 for East-West check (Vertical Edge gradients point Horizontal)
        dir_image[r, :] = DIR_EW 
        
    # Stream it
    dut.m_tready.value = 1
    
    received_vals = []
    
    for r in range(height):
        for c in range(width):
            mag = mag_image[r, c]
            d   = dir_image[r, c]
            
            # Pack: [15:12]=0, [14:12]=Dir, [11:0]=Mag
            packed = (int(d) << 12) | int(mag)
            
            dut.s_tvalid.value = 1
            dut.s_tdata.value = packed
            dut.s_tuser.value = 1 if (r==0 and c==0) else 0
            dut.s_tlast.value = 1 if (c==width-1) else 0
            
            await RisingEdge(dut.clk)
            
            if dut.m_tvalid.value:
                received_vals.append(int(dut.m_tdata.value))
                
    # Flush
    dut.s_tvalid.value = 0
    for _ in range(width * 5):
        await RisingEdge(dut.clk)
        if dut.m_tvalid.value:
             received_vals.append(int(dut.m_tdata.value))
             
    # Analyze results
    # Reshape received to image? Hard due to startup latency.
    # Latency is ~1 line + 2 cycles.
    # We should look for the sequence 0, 0, ..., 0, 255, 0, ...
    
    # Check if we see 255s
    assert 255 in received_vals, "Did not find maximum 255 in output"
    
    # Check if 100s are SUPPRESSED (should be 0)
    # The inputs had 100s. The NMS should kill them because 100 < 255.
    # But wait, make sure we align correctly.
    # For a row: ..., 50, 100, 255, 100, 50, ...
    # NMS Output: ..., 0, 0, 255, 0, 0, ...
    # So we should NOT see '100' or '50' in the output, theoretically?
    # Unless boundary conditions (start of line) mess it up.
    # But for the middle cols, they should be 0.
    
    count_255 = received_vals.count(255)
    # We expect roughly (height-2) * 1 = ~8 pixels of 255 (top/bot rows invalid)
    
    dut._log.info(f"Found {count_255} max pixels")
    assert count_255 > 0
    
    # Ensure no '100' leaked through (except maybe at first line if buffering odd?)
    # Ideally 0.
    count_100 = received_vals.count(100)
    dut._log.info(f"Found {count_100} suppressed pixels (should be 0 or low)")
    
    # Allow some startup artifacts but mostly 0
    if count_100 > 5:
        # Dump section
        dut._log.error(f"Too many unsuppressed pixels: {received_vals[:100]}")
        assert False, "NMS failed to suppress non-maxima"

@cocotb.test()
async def test_nms_diagonal(dut):
    """Test NMS with a diagonal edge"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)
    
    width = 20
    height = 20
    
    # Diagonal line (NW to SE)
    # Gradient direction is NE-SW (Perpendicular) -> DIR 1 (45 deg)
    # Pixels on diagonal: (r, r) -> 255
    # Neighbors (r, r-1) and (r, r+1) -> 100
    
    mag_image = np.zeros((height, width), dtype=np.uint16)
    dir_image = np.zeros((height, width), dtype=np.uint8)
    
    for r in range(height):
        for c in range(width):
            if r == c:
                mag_image[r, c] = 255
            elif abs(r - c) == 1:
                mag_image[r, c] = 100
            else:
                mag_image[r, c] = 0
            
            # Use Direction 1 (NE-SW check)
            # Center (r,c) compares against (r-1, c+1) [NE] and (r+1, c-1) [SW]
            # Wait, diagonal is NW-SE line.
            # Gradient is normal to edge -> NE-SW.
            # So we check neighbors along NE-SW.
            # If (r,c) is max, neighbors at (r-1, c+1) and (r+1, c-1) should be smaller.
            # In our image, (r-1, c+1) is distance 2 from diagonal?
            # Let's trace:
            # P(2,2) is 255.
            # Neighbors for Dir 1: P(1,3) and P(3,1).
            # P(1,3) -> r=1, c=3. abs(1-3)=2. Mag=0.
            # So 255 > 0.
            # The adjacent pixels on the line width are P(2,1) and P(2,3) (Horizontal neighbors)
            # OR P(1,2) and P(3,2) (Vertical neighbors).
            # Depending on line thickness.
            # My construct `abs(r-c)==1` makes a thick line?
            # P(2,2)=255. P(2,1)=100. P(2,3)=100. P(1,2)=100. P(3,2)=100.
            # We want to ensure 255 survives.
            # Does 100 survive?
            # Take P(2,1)=100. Dir 1 check neighbors P(1,2) and P(3,0).
            # P(1,2)=100 (Equal). P(3,0)=0.
            # If equal? Usually stringent NMS requires strict > or >= one side.
            # My RTL: (center >= n1) && (center >= n2).
            # So 100 >= 100 is True.
            # So 100 might survive if plateau?
            # We want to test SUPPRESSION.
            # So we need a scenario where neighbor is LARGER.
            pass
            
    # Refined test pattern for suppression:
    # Set P(r,c) = 100. P(r-1, c+1) = 255. (Along gradient)
    # Then P(r,c) should be suppressed.
    
    mag_image[:] = 0
    dir_image[:] = 1 # Check NE-SW
    
    # At (5,5), put 100.
    # At (4,6) [NE], put 255.
    # At (6,4) [SW], put 50.
    # Result: (5,5) should be 0 because 100 < 255.
    
    mag_image[5, 5] = 100
    mag_image[4, 6] = 255
    mag_image[6, 4] = 50
    
    # Stream
    dut.m_tready.value = 1
    nms_output = []
    
    for r in range(height):
        for c in range(width):
            packed = (int(dir_image[r,c]) << 12) | int(mag_image[r,c])
            dut.s_tdata.value = packed
            dut.s_tvalid.value = 1
            await RisingEdge(dut.clk)
            if dut.m_tvalid.value:
                nms_output.append(int(dut.m_tdata.value))
                
    dut.s_tvalid.value = 0
    for _ in range(100):
        await RisingEdge(dut.clk)
        if dut.m_tvalid.value:
            nms_output.append(int(dut.m_tdata.value))
            
    # Check if we see 255 (Max) and NOT 100 (Suppressed)
    assert 255 in nms_output
    assert 100 not in nms_output, "Pixel 100 should have been suppressed by neighbor 255"

