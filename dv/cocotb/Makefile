SHELL := /bin/bash

# Simulator configuration
SIM ?= modelsim
TOPLEVEL_LANG ?= verilog
TESTCASE ?= test_gaussian_stage_small_frame
NMS_TESTCASE ?=
NMS_IMG_WIDTH ?= 20

# Paths
PWD_DIR = $(shell pwd)
HW_DIR = $(PWD_DIR)/../../hw
RTL_DIR = $(HW_DIR)/rtl
COMMON_DIR = $(RTL_DIR)/common
GAUSSIAN_DIR = $(RTL_DIR)/gaussian
NMS_DIR = $(RTL_DIR)/nms
INC_DIR = $(RTL_DIR)/inc

# Default args for compilation
# ModelSim uses SIM_ARGS, Verilator uses EXTRA_ARGS
EXTRA_ARGS += $(COMPILE_ARGS) -Wno-fatal --trace

# Python test path
export PYTHONPATH := $(PWD)/models:$(PYTHONPATH)

# Simulation timescale
export COCOTB_HDL_TIMEUNIT := 1ns
export COCOTB_HDL_TIMEPRECISION := 1ns

# Waveform dumping (set WAVES=1 to enable)
# For Icarus: generates VCD, view with GTKWave
# For Modelsim/Vivado: generates native format
ifeq ($(WAVES),1)
    export COCOTB_WAVES = 1
endif

# Clean command (used inline before each test)
CLEAN_CMD := rm -rf sim_build results.xml

# Default target - run tests sequentially with inline clean
.PHONY: all
all:
	@echo "=== Running PE Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/pe.v \
		TOPLEVEL=pe COCOTB_TEST_MODULES=tests.test_pe
	@echo "=== Running Line Buffer Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/line_buffer.v \
		TOPLEVEL=line_buffer COCOTB_TEST_MODULES=tests.test_line_buffer \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gLINE_WIDTH=32",EXTRA_ARGS="-GLINE_WIDTH=32 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal --trace")
	@echo "=== Running Row Buffer Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(GAUSSIAN_DIR)/line_buffer_5.v" \
		TOPLEVEL=line_buffer_5 COCOTB_TEST_MODULES=tests.test_row_buffer_5 \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=32",EXTRA_ARGS="-GIMG_WIDTH=32 -Wno-fatal --trace")
	@echo "=== Running Gaussian Core Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v" \
		TOPLEVEL=gaussian_5x5_core COCOTB_TEST_MODULES=tests.test_gaussian_5x5_core
	@echo "=== Running Gaussian Stage Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(COMMON_DIR)/line_buffer.v \
		                 $(GAUSSIAN_DIR)/line_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage COCOTB_TEST_MODULES=tests.test_gaussian_stage \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=32 -gIMG_HEIGHT=32",EXTRA_ARGS="-GIMG_WIDTH=32 -GIMG_HEIGHT=32 -Wno-fatal --trace")
	@echo "=== All Tests Complete ==="

# Individual Test Targets
.PHONY: test_pe
test_pe:
	$(CLEAN_CMD)
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/pe.v \
		TOPLEVEL=pe \
		COCOTB_TEST_MODULES=tests.test_pe \
		$(if $(filter verilator,$(SIM)),EXTRA_ARGS="-Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

.PHONY: test_line_buffer
test_line_buffer:
	$(CLEAN_CMD)
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/line_buffer.v \
		TOPLEVEL=line_buffer \
		COCOTB_TEST_MODULES=tests.test_line_buffer \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gLINE_WIDTH=32",EXTRA_ARGS="-GLINE_WIDTH=32 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

.PHONY: test_row_buffer
test_row_buffer:
	$(CLEAN_CMD)
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(GAUSSIAN_DIR)/line_buffer_5.v" \
		TOPLEVEL=line_buffer_5 \
		COCOTB_TEST_MODULES=tests.test_row_buffer_5 \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=32",EXTRA_ARGS="-GIMG_WIDTH=32 -Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

.PHONY: test_gaussian_core
test_gaussian_core:
	$(CLEAN_CMD)
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v" \
		TOPLEVEL=gaussian_5x5_core \
		COCOTB_TEST_MODULES=tests.test_gaussian_5x5_core \
		$(if $(filter verilator,$(SIM)),EXTRA_ARGS="-Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

.PHONY: test_gaussian_stage
test_gaussian_stage:
	rm -rf sim_build results.xml
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(COMMON_DIR)/line_buffer.v \
		                 $(GAUSSIAN_DIR)/line_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage \
		COCOTB_TEST_MODULES=tests.test_gaussian_stage \
		COCOTB_TESTCASE=$(TESTCASE) \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=5 -gIMG_HEIGHT=5",EXTRA_ARGS="-GIMG_WIDTH=5 -GIMG_HEIGHT=5 -Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

.PHONY: test_gaussian_stage_1080p
test_gaussian_stage_1080p:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(COMMON_DIR)/line_buffer.v \
		                 $(GAUSSIAN_DIR)/line_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage \
		COCOTB_TEST_MODULES=tests.test_gaussian_real_image \
		$(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=1920 -gIMG_HEIGHT=1080",EXTRA_ARGS="-GIMG_WIDTH=1920 -GIMG_HEIGHT=1080 -Wno-fatal")

.PHONY: test_nms
test_nms:
	$(CLEAN_CMD)
	WAVES=1 $(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
        VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(NMS_DIR)/row_buffer_3.v $(NMS_DIR)/nms_core.v $(NMS_DIR)/nms_stage.v" \
        TOPLEVEL=nms_stage \
        COCOTB_TEST_MODULES=tests.test_nms \
        COCOTB_TESTCASE=$(NMS_TESTCASE) \
        $(if $(filter modelsim,$(SIM)),SIM_ARGS="-gIMG_WIDTH=$(NMS_IMG_WIDTH)",EXTRA_ARGS="-GIMG_WIDTH=$(NMS_IMG_WIDTH) -Wno-fatal --trace")
	@mkdir -p waveform_dump/$@
	@-vcd2wlf dump.vcd waveform_dump/$@/$@.wlf 2>/dev/null || true

# Clean
.PHONY: clean
clean:
	rm -rf sim_build results.xml __pycache__ tests/__pycache__ models/__pycache__
	rm -rf *.vcd *.fst

# Waveform viewing 
.PHONY: wave
wave:
	vsim -view vsim.wlf

.PHONY: help
help:
	@echo "CEDA Cocotb Test Targets:"
	@echo "  make test_pe             - Test Processing Element"
	@echo "  make test_line_buffer    - Test Line Buffer"
	@echo "  make test_row_buffer     - Test 5-Row Buffer"
	@echo "  make test_gaussian_core  - Test Gaussian 5x5 Core"
	@echo "  make test_gaussian_stage - Test Gaussian Stage (default: test_gaussian_stage_small_frame)"
	@echo "                             Override with TESTCASE=<name>"
	@echo "  make test_gaussian_stage_1080p - Gaussian stage 1920x1080 real image"
	@echo "  make all                 - Run all tests"
	@echo "  make clean               - Clean build artifacts"
	@echo "  make wave                - View waveform in ModelSim"
