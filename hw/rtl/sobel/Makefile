# Default simulator
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# 1. Define your parameters here
export IMG_WIDTH ?= 1920
export IMG_HEIGHT ?= 1080

# 2. Add your Verilog sources
VERILOG_SOURCES += $(PWD)/sobel_stage.v
VERILOG_SOURCES += $(PWD)/line_buffer.v
VERILOG_SOURCES += $(PWD)/pe.v

# 3. Define the top-level module and the Python test file
TOPLEVEL = sobel_stage
MODULE = test_sobel

# Include the standard Cocotb makefiles
include $(shell cocotb-config --makefiles)/Makefile.sim