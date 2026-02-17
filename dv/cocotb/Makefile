SHELL := /bin/bash

# Simulator configuration
SIM ?= modelsim
TOPLEVEL_LANG ?= verilog
TESTCASE ?= test_gaussian_stage_small_frame

# Project paths
RTL_DIR := ../../hw/rtl
COMMON_DIR := $(RTL_DIR)/common
GAUSSIAN_DIR := $(RTL_DIR)/gaussian
NMS_DIR := $(RTL_DIR)/nms
INC_DIR := $(RTL_DIR)/inc

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
		COMPILE_ARGS="-Pline_buffer.LINE_WIDTH=32"
	@echo "=== Running Row Buffer Tests ==="
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(GAUSSIAN_DIR)/row_buffer_5.v" \
		TOPLEVEL=row_buffer_5 COCOTB_TEST_MODULES=tests.test_row_buffer_5 \
		COMPILE_ARGS="-Prow_buffer_5.LINE_WIDTH=32"
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
		                 $(GAUSSIAN_DIR)/row_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage COCOTB_TEST_MODULES=tests.test_gaussian_stage \
		COMPILE_ARGS="-Pgaussian_stage.IMG_WIDTH=32 -Pgaussian_stage.IMG_HEIGHT=32"
	@echo "=== All Tests Complete ==="

# Individual Test Targets
.PHONY: test_pe
test_pe:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/pe.v \
		TOPLEVEL=pe \
		COCOTB_TEST_MODULES=tests.test_pe

.PHONY: test_line_buffer
test_line_buffer:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES=$(COMMON_DIR)/line_buffer.v \
		TOPLEVEL=line_buffer \
		COCOTB_TEST_MODULES=tests.test_line_buffer \
		COMPILE_ARGS="-Pline_buffer.LINE_WIDTH=32"

.PHONY: test_row_buffer
test_row_buffer:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(GAUSSIAN_DIR)/row_buffer_5.v" \
		TOPLEVEL=row_buffer_5 \
		COCOTB_TEST_MODULES=tests.test_row_buffer_5 \
		COMPILE_ARGS="-Prow_buffer_5.LINE_WIDTH=32"

.PHONY: test_gaussian_core
test_gaussian_core:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v" \
		TOPLEVEL=gaussian_5x5_core \
		COCOTB_TEST_MODULES=tests.test_gaussian_5x5_core

.PHONY: test_gaussian_stage
test_gaussian_stage:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(COMMON_DIR)/line_buffer.v \
		                 $(GAUSSIAN_DIR)/row_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage \
		COCOTB_TEST_MODULES=tests.test_gaussian_stage \
		COCOTB_TESTCASE=$(TESTCASE) \
		SIM_ARGS="-GIMG_WIDTH=5 -GIMG_HEIGHT=5"

.PHONY: test_gaussian_stage_1080p
test_gaussian_stage_1080p:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
		VERILOG_SOURCES="$(COMMON_DIR)/pe.v $(COMMON_DIR)/line_buffer.v \
		                 $(GAUSSIAN_DIR)/row_buffer_5.v $(GAUSSIAN_DIR)/gaussian_5x5_core.v \
		                 $(GAUSSIAN_DIR)/gaussian_stage.v" \
		TOPLEVEL=gaussian_stage \
		COCOTB_TEST_MODULES=tests.test_gaussian_real_image \
		SIM_ARGS="-GIMG_WIDTH=1920 -GIMG_HEIGHT=1080"

.PHONY: test_nms
test_nms:
	$(CLEAN_CMD)
	$(MAKE) -f $(shell cocotb-config --makefiles)/Makefile.sim \
		SIM=$(SIM) \
		TOPLEVEL_LANG=$(TOPLEVEL_LANG) \
        VERILOG_SOURCES="$(COMMON_DIR)/line_buffer.v $(NMS_DIR)/row_buffer_3.v $(NMS_DIR)/nms_core.v $(NMS_DIR)/nms_stage.v" \
        TOPLEVEL=nms_stage \
        COCOTB_TEST_MODULES=tests.test_nms \
        SIM_ARGS="-GIMG_WIDTH=20"

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