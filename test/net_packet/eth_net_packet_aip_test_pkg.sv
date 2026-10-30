// test/net_packet AIP 集成验证：实际 Tcl 命令驱动四个 bind agent，test 不创建 env/agent。
// 依赖 eth_net_packet_aip_pkg 和公共测试 sink；期望报文由 SV 显式字段构造，
// 不调用 load_params 或转换 sequence，以独立核对 Tcl 参数路由及线上字节。
package eth_net_packet_aip_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_net_packet_aip_pkg::*;
  import eth_net_packet_test_pkg::*;
  `include "uvm_macros.svh"

  // 每个 port 只借用已绑定 agent，持有独立 monitor sink 和期望计数。
  class eth_net_aip_port #(int RATE = 100) extends uvm_component;
    eth_seg_agent#(RATE) agt;
    eth_net_sink sink;
    int expected_count = 0;

    // 名字与 AGENT_NAME 一致；sink 在 build 阶段创建。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 读取 root agent，确认 bind 保持默认 CLIENT/无前导/无 FCS。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_agent"}, agt))
        `uvm_fatal("ETH_NET_AIP_HANDLE", "bound agent missing")
      if (agt.cfg.role != ETH_SEG_CLIENT || agt.cfg.preamble_passthrough || agt.cfg.include_fcs)
        `uvm_fatal("ETH_NET_AIP_DEFAULT", "bound agent defaults changed")
      sink = new("sink", this);
    endfunction

    // 订阅真实 TX 引脚采样；不依赖 command 返回值判断报文是否真正发送。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.tx_monitor.item_collected_port.connect(sink.analysis_export);
    endfunction

    // test 在 end_of_elaboration 后调用，复制一批明确的期望原始字节。
    function void expect_batch(input packet p, input int count);
      repeat (count) sink.expect_bytes(p.raw_data, 0, 0, ETH_SEG_TX);
      expected_count += count;
    endfunction

    // 队列、数量、驱动及监视器均完成才允许结束；多包也不能视为 complete。
    function bit complete();
      return sink.expected.size() == 0 && sink.received == expected_count &&
             agt.tx_driver.is_idle() && agt.tx_monitor.is_idle();
    endfunction
  endclass

  // Tcl 决定发送时间和参数，SV 验证端口隔离、默认参数以及同端口运行时改参。
  class eth_net_packet_aip_test extends uvm_test;
    `uvm_component_utils(eth_net_packet_aip_test)
    eth_net_aip_port#(100) eth0, eth3;
    eth_net_aip_port#(200) eth1;
    eth_net_aip_port#(400) eth2;

    // UVM 拥有 test 生命周期；本测试只新建观察组件。
    function new(string name = "eth_net_packet_aip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 四个端口包含重复的 100G，验证按名字查找而非按 RATE 共享 sqr。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      eth0 = new("eth0", this);
      eth1 = new("eth1", this);
      eth2 = new("eth2", this);
      eth3 = new("eth3", this);
    endfunction

    // 构建独立期望，显式字段对应 send.tcl；不用 AIP 参数解析或被测 packet_to_item。
    function packet reference_frame(input packet_template_e tmpl, input int length,
                                    input bit [47:0] dst_mac = 0,
                                    input byte unsigned payload_byte = 8'ha5);
      packet p = new();
      eth_header eh;

      p.build_from_template(tmpl);
      p.pkt_len = length;
      eh = p.get_eth();
      eh.dst_mac = dst_mac;
      p.payload_mode = PAYLOAD_FIXED;
      p.payload_fixed_val = payload_byte;
      p.do_pack();
      return p;
    endfunction

    // 子组件 build/connect 已完成，此时可安全登记期望并核对静态 sqr。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (eth_seg_sequencer::get_sqr("eth0") != eth0.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth1") != eth1.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth2") != eth2.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth3") != eth3.agt.sequencer ||
          eth0.agt.sequencer == eth3.agt.sequencer)
        `uvm_fatal("ETH_NET_AIP_SQR", "static sequencer isolation failed")
      eth0.expect_batch(reference_frame(ETH_IPV4_UDP, 256), 2);
      eth0.expect_batch(reference_frame(ETH_IPV4_UDP, 64, 48'h123456789abc, 8'h5a), 1);
      eth1.expect_batch(reference_frame(ETH_IPV6_TCP, 128, 48'hfedcba987654), 3);
      eth2.expect_batch(reference_frame(ETH_IPV4_UDP_ROCEV2, 129), 1);
      eth3.expect_batch(reference_frame(ETH_IPV4_UDP, 512, 48'h010203040506), 4);
    endfunction

    // Tcl bridge 在复位解除后启动；end_test 只停止命令循环，仍须等物理发包完成。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait (eth0.agt.cfg.vif.i_tx_rst_n && eth1.agt.cfg.vif.i_tx_rst_n &&
            eth2.agt.cfg.vif.i_tx_rst_n && eth3.agt.cfg.vif.i_tx_rst_n);
      aip_tcl_bridge::run_loop();
      for (int cycles = 0; cycles < 2000; cycles++) begin
        if (eth0.complete() && eth1.complete() && eth2.complete() && eth3.complete()) break;
        #10ns;
      end
      #20ns;
      if (!eth0.complete() || !eth1.complete() || !eth2.complete() || !eth3.complete())
        `uvm_fatal("ETH_NET_AIP_TIMEOUT", "Tcl network packets did not match on all four ports")
      `uvm_info("ETH_NET_AIP_TEST_COMPLETE", "4 named IPs: 3/3/1/4 network frames matched, including runtime parameters and RoCEv2 ICRC", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
