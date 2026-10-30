# 根目录 VCS 构建入口：RATE 是原 smoke 回归标签（接口同时实例化 100/200/400）。
# bind-test 验证实际 bind；aip/net-packet 目标使用外部依赖，构建目录互相独立。
# 仿真应在 10.11.10.53 上执行，并预先载入该主机的 VCS/UVM/license 环境。
.DEFAULT_GOAL := compile
VCS ?= vcs
RATE ?= 100
TEST ?= eth_seg_smoke_test
SEED ?= 1
BUILD ?= build/$(RATE)
SIMV := $(BUILD)/simv
UVM_HOME ?= $(VCS_HOME)/etc/uvm-1.2
# 外部依赖只用于相应的可选目标；普通 compile/run/bind-test 不需要它们。
AIP_CORE ?=
NET_PACKET ?=
INC := +incdir+src +incdir+rtl +incdir+seq_lib +incdir+test +incdir+$(UVM_HOME)/src
VCSFLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -Mdir=$(BUILD)/csrc -o $(SIMV) +define+ETH_SEG_BUILD_RATE=$(RATE) $(INC)
SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
       checker/eth_seg_protocol_checker.sv test/tb_top.sv test/eth_seg_smoke_test.sv
BIND_SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
            checker/eth_seg_protocol_checker.sv bind/eth_seg_bind_wrapper.sv \
            test/bind/eth_seg_bind_test_pkg.sv test/bind/tb_bind.sv
AIP_INC := +incdir+$(AIP_CORE) +incdir+$(AIP_CORE)/src/sv \
           +incdir+$(AIP_CORE)/src/sv/core +incdir+$(AIP_CORE)/src/sv/bridge \
           +incdir+$(AIP_CORE)/src/sv/util +incdir+$(AIP_CORE)/src/sv/plugin \
           +incdir+$(AIP_CORE)/src/sv/cpu_mem
AIP_SRC := $(AIP_CORE)/aip_core_pkg.sv \
           rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
           checker/eth_seg_protocol_checker.sv bind/eth_seg_bind_wrapper.sv \
           examples/aip/eth_seg_aip_pkg.sv test/aip/eth_seg_aip_test_pkg.sv test/aip/tb_aip.sv
NET_INC := $(addprefix +incdir+$(NET_PACKET)/src/,common protocols protocols/l2 protocols/l3 \
           protocols/l4 protocols/tunnel protocols/rdma protocols/storage protocols/app \
           core parser pcap sequence stream uvm_wrapper) +incdir+$(NET_PACKET)/src
NET_SRC := $(NET_PACKET)/src/net_packet_pkg.sv \
           rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv src/eth_net_packet_pkg.sv
NET_TEST_SRC := $(NET_SRC) checker/eth_seg_protocol_checker.sv \
                test/net_packet/eth_net_packet_test_pkg.sv test/net_packet/tb_net_packet.sv
NET_AIP_SRC := $(AIP_CORE)/aip_core_pkg.sv $(NET_SRC) \
               checker/eth_seg_protocol_checker.sv bind/eth_seg_bind_wrapper.sv \
               examples/aip/eth_net_packet_aip_pkg.sv test/net_packet/eth_net_packet_test_pkg.sv \
               test/net_packet/eth_net_packet_aip_test_pkg.sv test/net_packet/tb_net_packet_aip.sv
TIMING_SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
              checker/eth_seg_protocol_checker.sv test/timing/eth_timing_control.sv \
              test/timing/eth_timing_test_pkg.sv test/timing/tb_timing.sv
SCENARIO ?= all

# hub 契约测试无需 net_packet/AIP；源码与原 smoke 独立构建。
HUB_SRC := rtl/eth_seg_if.sv src/eth_seg_types.sv src/eth_seg_pkg.sv \
           test/sampling/eth_seg_hub_test_pkg.sv test/sampling/tb_hub.sv

.PHONY: hub-test hub-run
hub-test:
	$(MAKE) --no-print-directory hub-run BUILD=build/sampling_hub

hub-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_hub $(HUB_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/hub.log
	python3 scripts/check_log.py $(BUILD)/logs/hub.log run ETH_HUB_TEST_COMPLETE


# RM/SCB 示例使用网络报文，但不依赖可选 AIP；复位控制只属于测试。
SAMPLING_SRC := $(NET_SRC) checker/eth_seg_protocol_checker.sv \
                test/sampling/eth_sampling_control.sv examples/sampling/eth_rm_scb_example_pkg.sv \
                test/sampling/eth_rm_scb_test_pkg.sv test/sampling/tb_rm_scb.sv

.PHONY: sampling-test sampling-run
sampling-test:
	$(MAKE) --no-print-directory sampling-run BUILD=build/sampling

sampling-run:
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/src/net_packet_pkg.sv"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(NET_INC) -top tb_rm_scb $(SAMPLING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/sampling.log
	python3 scripts/check_log.py $(BUILD)/logs/sampling.log run ETH_SAMPLING_TEST_COMPLETE

.PHONY: compile run regress clean bind-test bind-run aip-test aip-run \
        net-packet-test net-packet-run net-packet-aip-test net-packet-aip-run timing-test timing-run \
        timing-checker-test timing-checker-run

timing-checker-test:
	$(MAKE) --no-print-directory timing-checker-run BUILD=build/timing_checker

# 非法 X/Z 用例按精确诊断判通过，不能套用普通测试的零 error 规则。
timing-checker-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -top tb_timing_checker -Mdir=$(BUILD)/csrc -o $(SIMV) checker/eth_seg_protocol_checker.sv test/timing/tb_timing_checker.sv -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	@for scenario in rx_invalid rx_z rx_dontcare rx_eop_x rx_data_x tx_dontcare tx_data_x; do \
		$(SIMV) +CASE=$$scenario -l $(BUILD)/logs/$$scenario.log; \
		python3 scripts/check_timing_checker.py $(BUILD)/logs/$$scenario.log $$scenario || exit $$?; \
	done

timing-test:
	$(MAKE) --no-print-directory timing-run BUILD=build/timing

# SCENARIO 可单独选择 ready/gap/load/random_load/reset；默认运行全部阶段。
timing-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_timing $(TIMING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +SCENARIO=$(SCENARIO) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/timing_$(SCENARIO).log
	python3 scripts/check_log.py $(BUILD)/logs/timing_$(SCENARIO).log run ETH_TIMING_TEST_COMPLETE

net-packet-test:
	$(MAKE) --no-print-directory net-packet-run BUILD=build/net_packet

# net_packet_pkg 使用独立 package 类型，不同时使用旧 filelist.f 的 $unit 声明。
net-packet-run:
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/src/net_packet_pkg.sv"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(NET_INC) -top tb_net_packet $(NET_TEST_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/net_packet_test.log
	python3 scripts/check_log.py $(BUILD)/logs/net_packet_test.log run ETH_NET_TEST_COMPLETE

net-packet-aip-test:
	$(MAKE) --no-print-directory net-packet-aip-run BUILD=build/net_packet_aip

# AIP 必须在 net_packet_pkg 之前编译，以启用 packet.load_params 的 Tcl 参数入口。
net-packet-aip-run:
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/src/net_packet_pkg.sv"
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core_pkg.sv"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(NET_INC) $(AIP_INC) -debug_access+all -top tb_net_packet_aip $(NET_AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(abspath $(AIP_CORE))" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/net_packet/send.tcl) -no_save -exitstatus -l $(BUILD)/logs/net_packet_aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/net_packet_aip_test.log run ETH_NET_AIP_TEST_COMPLETE

aip-test:
	$(MAKE) --no-print-directory aip-run BUILD=build/aip

# 指定 aip_core/update 的源码路径；不自动下载或修改用户的 AIP 仓库。
aip-run:
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core_pkg.sv"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(AIP_INC) -debug_access+all -top tb_aip $(AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(abspath $(AIP_CORE))" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/aip/send.tcl) -no_save -exitstatus -l $(BUILD)/logs/aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/aip_test.log run ETH_AIP_TEST_COMPLETE

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
