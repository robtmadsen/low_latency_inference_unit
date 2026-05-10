VERILATOR   ?= verilator
RTL_DIR     := ../rtl
REPORT_DIR  := ../reports

VFLAGS := --binary --timing \
          --coverage \
          +incdir+$(RTL_DIR) \
          --top-module tb_top \
          --Mdir obj_dir \
          -j $$(nproc) \
          -Wno-fatal \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
          -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
          -Wno-UNDRIVEN -Wno-DECLFILENAME \
          -Wno-CASEINCOMPLETE -Wno-BLKSEQ \
          -Wno-INITIALDLY

SRCS := uvm_pkg.sv \
        $(RTL_DIR)/lliu_pkg.sv \
        $(RTL_DIR)/itch_field_extract.sv \
        tb_top.sv

.PHONY: all compile test coverage clean

all: compile

compile:
	$(VERILATOR) $(VFLAGS) $(SRCS)

test: compile
	@mkdir -p $(REPORT_DIR)
	-./obj_dir/Vtb_top 2>&1 | tee sim.log
	@grep -q "TEST PASSED" sim.log
	verilator_coverage --write-info coverage.info coverage.dat 2>/dev/null || true
	@python3 gen_coverage.py coverage.info > $(REPORT_DIR)/coverage.txt 2>&1 || true
	@cat $(REPORT_DIR)/coverage.txt 2>/dev/null || true

coverage:
	@mkdir -p $(REPORT_DIR)
	verilator_coverage --write-info coverage.info coverage.dat
	python3 gen_coverage.py coverage.info > $(REPORT_DIR)/coverage.txt
	@cat $(REPORT_DIR)/coverage.txt

clean:
	rm -rf obj_dir coverage.dat coverage.info sim.log
