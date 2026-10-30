# 根目录 VCS 构建入口：RATE 是原 smoke 回归标签（接口同时实例化 100/200/400）。
# bind-test 使用独立顶层和 build/bind 目录，验证实际 bind；各目录由 make 管理生成物。
# 仿真应在 10.11.10.53 上执行，并预先载入该主机的 VCS/UVM/license 环境。
.DEFAULT_GOAL := compile
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
BIND_SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
            checker/eth_seg_protocol_checker.sv bind/eth_seg_bind_wrapper.sv \
            test/bind/eth_seg_bind_test_pkg.sv test/bind/tb_bind.sv

.PHONY: compile run regress clean bind-test bind-run

# 递归 make 覆盖 BUILD，避免 bind 和原 smoke 的编译缓存或 simv 相互覆盖。
bind-test:
	$(MAKE) --no-print-directory bind-run BUILD=build/bind

bind-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_bind $(BIND_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/bind_test.log
	python3 scripts/check_log.py $(BUILD)/logs/bind_test.log run ETH_BIND_TEST_COMPLETE

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
