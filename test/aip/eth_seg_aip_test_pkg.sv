// test/aip UVM 验证层：test 不创建任何 agent/env，只检查 bind agent 的 monitor。
// 依赖 AIP、eth_seg_pkg 和示例命令 package；test 拥有四个只读 subscriber。
// Tcl 控制发包与参数，SV 独立核对物理接收字节，防止仅凭命令 OK 判断通过。
package eth_seg_aip_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_aip_pkg::*;
  `include "uvm_macros.svh"

  // 每个 IP 的期望队列归 subscriber；只比较 monitor 的真实采样，不读取 driver 队列。
  class eth_aip_port_check #(int RATE = 100) extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_agent#(RATE) agt;
    int lengths[$], indices[$];
    int received = 0;

    // 名字与 AGENT_NAME 一致，便于读取该端口的类型化句柄并诊断串包。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 获取已有 agent；验证本例仅使用 cfg 默认值，且没有依赖 env 创建组件。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_agent"}, agt))
        `uvm_fatal("AIP_TEST_HANDLE", "bound agent missing")
      if (agt.cfg.role != ETH_SEG_CLIENT || agt.cfg.is_active != UVM_ACTIVE ||
          agt.cfg.preamble_passthrough || agt.cfg.include_fcs || agt.cfg.traffic_load_pct != 100)
        `uvm_fatal("AIP_TEST_DEFAULT", "bind must retain cfg defaults")
    endfunction

    // build 全部完成后订阅 TX；不创建/转接任何 sequencer。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.tx_monitor.item_collected_port.connect(analysis_export);
    endfunction

    // 构建一条 Tcl count 命令的期望；基础 sequence 的帧编号在每次命令从零开始。
    function void expect_batch(int count, int length);
      for (int n = 0; n < count; n++) begin
        lengths.push_back(length);
        indices.push_back(n);
      end
    endfunction

    // 独立重建基础 sequence 的 DA/SA/Type/payload 公式，检查格式、长度及全部字节。
    // 超出期望数量的包也报错，不能因期望队列已清空而忽略尾包。
    function void write(eth_seg_seq_item t);
      int length, index;
      received++;
      if (lengths.size() == 0) begin
        `uvm_error("AIP_TEST_EXTRA", "unexpected packet")
        return;
      end
      length = lengths.pop_front();
      index = indices.pop_front();
      if (t.frame_bytes.size() != length || t.aborted || t.fcs_present || t.direction != ETH_SEG_TX)
        `uvm_error("AIP_TEST_FORMAT", t.convert2string())
      else foreach (t.frame_bytes[b]) begin
        byte unsigned expected;
        if (b < 6) expected = 8'h10 + b;
        else if (b < 12) expected = 8'h20 + b - 6;
        else if (b == 12) expected = 8'h08;
        else if (b == 13) expected = 8'h00;
        else expected = byte'(index * 17 + b);
        if (t.frame_bytes[b] !== expected) begin
          `uvm_error("AIP_TEST_BYTES", $sformatf("packet=%0d byte=%0d differs", received, b))
          break;
        end
      end
    endfunction

    // 只有全部期望被消费且 driver/monitor 无在途事务时才允许结束仿真。
    function bit complete();
      return lengths.size() == 0 && agt.tx_driver.is_idle() && agt.tx_monitor.is_idle();
    endfunction
  endclass

  // base test 只运行一个 Tcl bridge；bind module 是 agent 的唯一创建入口。
  class eth_seg_aip_test extends uvm_test;
    `uvm_component_utils(eth_seg_aip_test)
    eth_aip_port_check#(100) eth0, eth3;
    eth_aip_port_check#(200) eth1;
    eth_aip_port_check#(400) eth2;

    // test 由 run_test 创建，四个 subscriber 由 build 创建并归其管理。
    function new(string name = "eth_seg_aip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 期望来自 Tcl 用例的明确请求；eth0 第二次改长度，其他端口应不受影响。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      eth0 = new("eth0", this);
      eth1 = new("eth1", this);
      eth2 = new("eth2", this);
      eth3 = new("eth3", this);
      eth0.expect_batch(2, 256);
      eth0.expect_batch(1, 64);
      eth1.expect_batch(3, 128);
      eth2.expect_batch(1, 96);
      eth3.expect_batch(4, 512);
    endfunction

    // 复位解除后接收 Tcl；end_test 退出 bridge 后继续等真实发送结束，最多 10 us。
    // 通过静态表核对四个不同对象，证明同速率 eth0/eth3 没有共用一个 sqr。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      if (eth_seg_sequencer::sqr.num() != 4 ||
          eth_seg_sequencer::get_sqr("eth0") != eth0.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth1") != eth1.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth2") != eth2.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth3") != eth3.agt.sequencer ||
          eth0.agt.sequencer == eth3.agt.sequencer)
        `uvm_fatal("AIP_TEST_SQR", "four static sequencer bindings differ")
      wait (eth0.agt.cfg.vif.i_tx_rst_n && eth1.agt.cfg.vif.i_tx_rst_n &&
            eth2.agt.cfg.vif.i_tx_rst_n && eth3.agt.cfg.vif.i_tx_rst_n);
      aip_tcl_bridge::run_loop();
      for (int cycles = 0; cycles < 1000; cycles++) begin
        if (eth0.complete() && eth1.complete() && eth2.complete() && eth3.complete()) break;
        #10ns;
      end
      if (!eth0.complete() || !eth1.complete() || !eth2.complete() || !eth3.complete())
        `uvm_fatal("AIP_TEST_TIMEOUT", "Tcl requests did not complete on all four IPs")
      #20ns;
      if (eth0.received != 3 || eth1.received != 3 || eth2.received != 1 || eth3.received != 4)
        `uvm_fatal("AIP_TEST_COUNTS", "Tcl requests reached the wrong port or produced trailing packets")
      `uvm_info("ETH_AIP_TEST_COMPLETE", "four IPs: 3/3/1/4 frames matched; Tcl parameter isolation passed", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
