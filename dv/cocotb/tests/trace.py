import functools
import json
import os
from pathlib import Path
from typing import Iterable

import cocotb
from cocotb.triggers import RisingEdge


def _safe_name(name: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("_", "-", ".") else "_" for ch in name)


def _value_to_json_compatible(value) -> int | str:
    try:
        return int(value)
    except Exception:
        return str(value)


def _is_traceable_handle(handle) -> bool:
    # Skip unpacked arrays/memories (e.g. RAM "mem") which stringify into huge
    # nested LogicArray(...) payloads and are not useful for cycle traces.
    cls = handle.__class__.__name__
    if cls in {"ArrayObject", "HierarchyArrayObject"}:
        return False
    return True


def _collect_top_level_signal_names(dut) -> list[str]:
    names = []
    for child in dut:
        name = getattr(child, "_name", None)
        if not name:
            continue
        if not _is_traceable_handle(child):
            continue
        try:
            _ = child.value
        except Exception:
            continue
        names.append(name)
    return sorted(set(names))


class CycleTraceRecorder:
    def __init__(
        self,
        dut,
        signal_names: Iterable[str] | None = None,
        clock_signal: str = "clk",
        test_name: str | None = None,
        trace_dir: str | None = None,
    ):
        self.dut = dut
        self.clock_signal = clock_signal
        self.clock = getattr(dut, clock_signal)
        self.signal_names = list(signal_names) if signal_names is not None else _collect_top_level_signal_names(dut)
        self.test_name = test_name or "trace"
        self.trace_dir = trace_dir
        self.samples = []
        self._cycle = 0
        self._task = None

    async def start(self):
        self._task = cocotb.start_soon(self._monitor())

    async def _monitor(self):
        while True:
            await RisingEdge(self.clock)
            sample = {"cycle": self._cycle}
            for name in self.signal_names:
                try:
                    handle = getattr(self.dut, name)
                    sample[name] = _value_to_json_compatible(handle.value)
                except Exception:
                    sample[name] = "ERR"
            self.samples.append(sample)
            self._cycle += 1

    def stop(self):
        if self._task is not None:
            if hasattr(self._task, "cancel"):
                self._task.cancel()
            else:
                self._task.kill()
            self._task = None

    def dump(self) -> Path:
        sim_build = os.getenv("SIM_BUILD", ".")
        top = _safe_name(os.getenv("COCOTB_TOPLEVEL", getattr(self.dut, "_name", "dut")))
        trace_root = Path(self.trace_dir) if self.trace_dir else Path(sim_build) / "traces"
        trace_root.mkdir(parents=True, exist_ok=True)

        trace_file = trace_root / f"{_safe_name(self.test_name)}.json"
        payload = {
            "test": self.test_name,
            "toplevel": top,
            "clock": self.clock_signal,
            "signals": self.signal_names,
            "samples": self.samples,
        }
        with trace_file.open("w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
        return trace_file


def traced_test(
    _func=None,
    *,
    signal_names: Iterable[str] | None = None,
    clock_signal: str = "clk",
    trace_dir: str | None = None,
    **cocotb_test_kwargs,
):
    def _decorate(test_func):
        @functools.wraps(test_func)
        async def _wrapped(dut, *args, **kwargs):
            recorder = CycleTraceRecorder(
                dut,
                signal_names=signal_names,
                clock_signal=clock_signal,
                test_name=test_func.__name__,
                trace_dir=trace_dir,
            )
            await recorder.start()
            try:
                return await test_func(dut, *args, **kwargs)
            finally:
                recorder.stop()
                trace_path = recorder.dump()
                dut._log.info("Cycle trace JSON written to %s", trace_path)

        return cocotb.test(**cocotb_test_kwargs)(_wrapped)

    if _func is not None and callable(_func):
        return _decorate(_func)
    return _decorate
