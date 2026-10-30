# VCS 构建入口：RATE 是回归标签（接口本身同时实例化 100/200/400），每次构建使用独立目录。
VCS ?= vcs
RATE ?= 100
TEST ?= eth_seg_smoke_test
SEED ?= 1
BUILD ?= build/$(RATE)
SIMV := $(BUILD)/simv
UVM_HOME ?= $(VCS_HOME)/etc/uvm-1.2
INC := +incdir+src +incdir+rtl +incdir+seq_lib +incdir+test +incdir+$(UVM_HOME)/src
VCSFLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -Mdir=$(BUILD)/csrc -o $(SIMV) +define+ETH_SEG_BUILD_RATE=$(RATE) $(INC)
SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
       checker/eth_seg_protocol_checker.sv test/tb_top.sv test/eth_seg_smoke_test.sv

.PHONY: compile run regress clean

compile:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile

run: compile
	$(SIMV) +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/$(TEST).log
	python3 scripts/check_log.py $(BUILD)/logs/$(TEST).log run

regress:
	@mkdir -p logs
	@set -e; for r in 100 200 400; do \
		$(MAKE) --no-print-directory run RATE=$$r SEED=$${SEED:-1} BUILD=build/$$r; \
	done
	@python3 scripts/check_log.py build/100/logs/$(TEST).log run
	@python3 scripts/check_log.py build/200/logs/$(TEST).log run
	@python3 scripts/check_log.py build/400/logs/$(TEST).log run

clean:
	rm -rf build logs
