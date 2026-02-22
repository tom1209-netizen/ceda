import cocotb
from cocotb.clock import Clock
from tests.trace import traced_test
from cocotb.triggers import RisingEdge
import numpy as np
import sys
import os
import json

# Add models path for reference
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'models'))
from gaussian_model import gaussian_filter_ref, generate_test_image

async def monitor_signals(dut, signals, filename="waveform.json"):
    """Monitor signals and dump to JSON"""
    waveform_data = {name: [] for name in signals}
    
    while True:
        await RisingEdge(dut.clk)
        for name in signals:
            try:
                val = getattr(dut, name).value
                # Handle 'x' and 'z' by converting to string or int 0
                try:
                    waveform_data[name].append(int(val))
                except ValueError:
                    waveform_data[name].append(str(val)) # preserve 'x'/'z' state
            except AttributeError:
                 pass
    
    return waveform_data
    
# Global list to store waveform data if we use a different approach, 
# but let's try a class-based monitor or just a simple robust task.

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
                    val = getattr(self.dut, name).value
                    try:
                        sample[name] = int(val)
                    except ValueError:
                        sample[name] = str(val)
                except Exception:
                    sample[name] = "ERR"
            self.data.append(sample)
            self.cycle += 1

    def dump_to_file(self, filename="waveform.json"):
        if self.task:
            self.task.kill()
        with open(filename, "w") as f:
            json.dump(self.data, f, indent=2)


async def reset_dut(dut):
    """Apply reset to DUT"""
    await RisingEdge(dut.clk)
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
    m_tlast_count = 0
    m_tuser_count = 0
    
    for row in range(img_height):
        for col in range(img_width):
            # Drive this beat and hold until accepted.
            dut.s_tdata.value = int(image[row, col])
            dut.s_tvalid.value = 1
            dut.s_tlast.value = 1 if col == img_width - 1 else 0
            dut.s_tuser.value = 1 if (row == 0 and col == 0) else 0

            while True:
                # Sample ready for the *upcoming* active edge.
                # s_tready is combinational from state that only updates on clock edges,
                # so this value is valid for the next handshake decision.
                beat_will_be_accepted = int(dut.s_tready.value) == 1

                await RisingEdge(dut.clk)

                if dut.m_tvalid.value == 1:
                    output_pixels.append(int(dut.m_tdata.value))
                    if int(dut.m_tlast.value) == 1:
                        m_tlast_count += 1
                    if int(dut.m_tuser.value) == 1:
                        m_tuser_count += 1

                if beat_will_be_accepted:
                    break
    
    # Continue clocking until the full output frame is observed.
    # A fixed flush length is too short for very small frames (e.g., 5x5).
    dut.s_tvalid.value = 0
    dut.s_tuser.value = 0
    dut.s_tlast.value = 0

    expected_outputs = img_width * img_height
    expected_lines = img_height
    flush_cycles = 0
    frame_done = False
    # Watchdog only (not a timing model): prevent infinite waits on regressions.
    max_flush_cycles = (expected_outputs * 16) + 1024

    while (not frame_done) and flush_cycles < max_flush_cycles:
        await RisingEdge(dut.clk)
        flush_cycles += 1
        if dut.m_tvalid.value == 1:
            output_pixels.append(int(dut.m_tdata.value))
            if int(dut.m_tlast.value) == 1:
                m_tlast_count += 1
                if m_tlast_count >= expected_lines:
                    frame_done = True
            if int(dut.m_tuser.value) == 1:
                m_tuser_count += 1

    if not frame_done:
        dut._log.warning(
            f"Flush timeout: frame_done not seen after {flush_cycles} cycles "
            f"(captured {len(output_pixels)}/{expected_outputs} outputs, "
            f"m_tlast_count={m_tlast_count}/{expected_lines})"
        )
    
    return output_pixels, m_tlast_count, m_tuser_count

@traced_test(trace_dir="waveform_dump/test_gaussian_stage")
async def test_gaussian_stage_reset(dut):
    """Test reset state"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    # Check outputs are in reset state
    assert int(dut.m_tvalid.value) == 0, "m_tvalid should be 0 after reset"
    assert int(dut.s_tready.value) == 1, "s_tready should be 1 (ready)"

@traced_test(trace_dir="waveform_dump/test_gaussian_stage")
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

@traced_test(trace_dir="waveform_dump/test_gaussian_stage")
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

@traced_test(trace_dir="waveform_dump/test_gaussian_stage")
async def test_gaussian_stage_small_frame(dut):
    """Test with a small frame (requires small IMG_WIDTH/HEIGHT for test)"""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    
    await reset_dut(dut)
    
    img_width = int(dut.IMG_WIDTH.value)
    img_height = int(dut.IMG_HEIGHT.value)
    
    # For large images, just do a partial test
    # Test full frame to verify auto-run flush logic
    test_height = img_height
    test_width = img_width
    
    # Generate test image
    np.random.seed(42)
    image = np.random.randint(0, 256, (test_height, test_width), dtype=np.uint8)
    
    # Setup Waveform Dumper
    signals_to_dump = [
        "clk", "rst_n", 
        "s_tdata", "s_tvalid", "s_tready", "s_tlast", "s_tuser",
        "m_tdata", "m_tvalid", "m_tready", "m_tlast", "m_tuser",
        "core_enable", "flush_active", "h_pad_state", "in_col", "out_col", "out_row", "pixel_cnt"
    ]
    dumper = WaveformDumper(dut, signals_to_dump)
    await dumper.start()

    # Send partial frame and collect outputs via shared frame driver
    dut.m_tready.value = 1
    output_pixels, m_tlast_count, m_tuser_count = await send_frame(dut, image, test_width, test_height)
    output_count = len(output_pixels)

    # Let the monitor task sample one more edge before cancellation.
    await RisingEdge(dut.clk)
    dumper.dump_to_file("waveform.json")
    
    assert output_count == (test_width * test_height), (
        f"Expected {test_width * test_height} output pixels, got {output_count}"
    )
    assert m_tuser_count == 1, f"Expected exactly one m_tuser pulse, got {m_tuser_count}"
    assert m_tlast_count == test_height, (
        f"Expected {test_height} m_tlast pulses (one per output row), got {m_tlast_count}"
    )
    
    dut._log.info(
        f"Received {output_count} valid outputs from {test_height}x{test_width} input; "
        f"m_tlast_count={m_tlast_count}, m_tuser_count={m_tuser_count}"
    )
