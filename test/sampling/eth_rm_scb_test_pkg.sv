// test/sampling 整包预测链路测试：两个独立刺激源模拟 DUT 入口/出口，验证公共采样流程。
// 不包含厂商或用户 DUT；出口字节由独立输入模板产生，不从 RM/hub 回灌实际数据。
// test 拥有 agent、控制接口借用句柄和示例组件，所有结束条件都有计数及超时约束。
package eth_rm_scb_test_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import net_packet_pkg::*;
  import eth_net_packet_pkg::*;
  import eth_rm_scb_example_pkg::*;
  `include "uvm_macros.svh"

  // 仅增加预测耗时，证明实际先到不丢包，且复位能终止已经取走的旧包预测。
  class delayed_packet_rm extends eth_rm_scb_example;
    time prediction_delay;

    // 由 case 直接创建，保持普通示例的 agent 借用关系。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 每次调用使用延时快照，防止测试下一阶段改参影响已开始的预测。
    virtual task model_predict(input eth_seg_seq_item input_pkt,
                               output eth_seg_seq_item expected_pkt);
      time delay_snapshot = prediction_delay;
      #(delay_snapshot);
      super.model_predict(input_pkt, expected_pkt);
    endtask
  endclass

  // 只安装到当前 case 的 scoreboard，三速率同时负向测试也不能互相吞报告。
  class sample_mismatch_catcher extends uvm_report_catcher;
    int caught;

    // 独立统计一个预期坏包。
    function new();
      super.new("sample_mismatch");
    endfunction

    // 其它严重级别或 ID 一律继续交给 UVM。
    virtual function action_e catch();
      if (get_severity() == UVM_ERROR && get_id() == "ETH_SEG_SB_TX") begin
        caught++;
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass

  // 一个速率一条独立链路；例程只借用 mac，client 专供模拟出口引脚刺激。
  class sampling_rate_case #(int RATE = 100) extends uvm_component;
    eth_seg_agent#(RATE) client, mac;
    eth_seg_config#(RATE) client_cfg, mac_cfg;
    virtual eth_sampling_control control;
    delayed_packet_rm model;
    bit done;

    // typed vif 与 RATE 的一致性在 build 校验。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 创建测试专用两端刺激，示例组件自身不创建 agent；完整名按当前 case 隔离。
    function void build_phase(uvm_phase phase);
      virtual eth_seg_if#(RATE) vif;
      super.build_phase(phase);
      if (!uvm_config_db#(virtual eth_seg_if#(RATE))::get(this, "", "vif", vif) ||
          !uvm_config_db#(virtual eth_sampling_control)::get(this, "", "control", control))
        `uvm_fatal("ETH_SAMPLING_VIF", "typed link or reset control missing")
      client_cfg = new("client_cfg");
      mac_cfg = new("mac_cfg");
      client_cfg.vif = vif;
      mac_cfg.vif = vif;
      mac_cfg.role = ETH_SEG_MAC;
      client = eth_seg_agent#(RATE)::type_id::create("client", this);
      mac = eth_seg_agent#(RATE)::type_id::create("mac", this);
      client.cfg = client_cfg;
      mac.cfg = mac_cfg;
      model = new("model", this);
      model.agent_name = mac.get_full_name();
    endfunction

    // 独立构造网络报文；入口和出口分别调用，不能共享被测预测的对象。
    function packet reference_packet(int salt, int length = 256);
      packet p = new();
      eth_header header;
      p.build_from_template(ETH_IPV4_UDP);
      p.pkt_len = length;
      p.payload_mode = PAYLOAD_FIXED;
      p.payload_fixed_val = byte'(salt);
      header = p.get_eth();
      header.dst_mac = 48'h102030400000 + salt;
      p.do_pack();
      return p;
    endfunction

    // 向一个方向入队，是否完成仍由下方 drain 核对真实 Monitor 和采样计数。
    task send_frames(bit is_rx, int salt, int count = 3, int length = 256, bit corrupt = 0);
      eth_base_seq seq = new("stimulus");
      seq.pkt = reference_packet(salt, length);
      seq.count = count;
      if (corrupt) seq.pkt.raw_data[52] ^= 8'h80;
      seq.start(is_rx ? mac.sequencer : client.sequencer);
    endtask

    // 有界排空检查同时包含当前 epoch 的处理数和 SCB 累计匹配/失败数。
    task drain(int matched, int mismatches, int epoch_packets);
      for (int cycles = 0; cycles < 5000; cycles++) begin
        if (model.predictions == epoch_packets && model.outputs == epoch_packets &&
            model.sb.matched_tx == matched && model.sb.mismatch_tx == mismatches &&
            model.is_idle() && client.tx_driver.is_idle() && mac.rx_driver.is_idle() &&
            mac.tx_monitor.is_idle() && mac.rx_monitor.is_idle()) begin
          repeat (4) @(negedge control.clk);
          if (model.outputs != epoch_packets || !model.is_idle())
            `uvm_fatal("ETH_SAMPLING_EXTRA", "unexpected trailing packet")
          return;
        end
        @(negedge control.clk);
      end
      `uvm_fatal("ETH_SAMPLING_DRAIN", $sformatf("RATE=%0d predicted=%0d outputs=%0d matched=%0d mismatch=%0d", RATE, model.predictions, model.outputs, model.sb.matched_tx, model.sb.mismatch_tx))
    endtask

    // 复位驱动在下降沿后更新，避开正沿采样竞态；等待示例完成重订阅才释放下一批流量。
    task reset_link();
      @(negedge control.clk);
      control.tx_rst_n = 0;
      control.rx_rst_n = 0;
      repeat (4) @(negedge control.clk);
      if (model.sampling_ready || model.in_prediction || !model.sb.is_idle())
        `uvm_fatal("ETH_SAMPLING_RESET", "reset did not cancel previous prediction")
      control.tx_rst_n = 1;
      control.rx_rst_n = 1;
      wait (model.sampling_ready);
    endtask

    // 先实际/先期望两种真实队列顺序都必须出现，不能仅从最后总计推断覆盖。
    task arrival_orders();
      model.prediction_delay = 250ns;
      fork
        send_frames(1, 11);
        send_frames(0, 11);
        begin
          #100ns;
          if (model.sb.actual_tx_fifo.size() == 0 || model.predictions != 0)
            `uvm_fatal("ETH_SAMPLING_ORDER", "actual-first window not observed")
        end
      join
      drain(3, 0, 3);
      model.prediction_delay = 0;
      fork
        send_frames(1, 22);
        begin #400ns; send_frames(0, 22); end
        begin
          #100ns;
          if (model.sb.expect_tx_fifo.size() == 0)
            `uvm_fatal("ETH_SAMPLING_ORDER", "expected-first window not observed")
        end
      join
      drain(6, 0, 6);
    endtask

    // 同时制造已取走包、缓存完整包和 Monitor 半包，复位后不同字节新包只能匹配新期望。
    task reset_inflight();
      int seen = mac.rx_monitor.packets_seen;
      int aborted = mac.rx_monitor.aborted_packets;
      model.prediction_delay = 2us;
      send_frames(1, 33, 1);
      wait (model.in_prediction);
      send_frames(1, 34, 1);
      wait (mac.rx_monitor.packets_seen >= seen+2);
      send_frames(1, 35, 1, 4096);
      wait (mac.rx_monitor.in_packet);
      if (mac.monitor_hub.pending(ETH_SEG_RX) == 0)
        `uvm_fatal("ETH_SAMPLING_RESET", "no queued complete packet before reset")
      reset_link();
      if (mac.rx_monitor.aborted_packets != aborted+1 ||
          mac.monitor_hub.pending(ETH_SEG_RX) != 0 || model.predictions != 0 || model.outputs != 0)
        `uvm_fatal("ETH_SAMPLING_RESET", "old epoch state survived reset")
      model.prediction_delay = 0;
      fork
        send_frames(1, 91, 2);
        send_frames(0, 91, 2);
      join
      drain(8, 0, 2);
    endtask

    // 坏实际字节必须经过同一公共采样路径触发一次比较错误，证明示例并非只计数。
    task mismatch_case();
      sample_mismatch_catcher catcher = new();
      uvm_report_cb::add(model.sb, catcher);
      fork
        send_frames(1, 92, 1);
        send_frames(0, 92, 1, 256, 1);
      join
      drain(8, 1, 3);
      uvm_report_cb::delete(model.sb, catcher);
      if (catcher.caught != 1) `uvm_fatal("ETH_SAMPLING_NEGATIVE", "expected one precise mismatch")
    endtask

    // 测试对象不自行结束 UVM；顶层等三速率全部完成后才释放 objection。
    task run_phase(uvm_phase phase);
      reset_link();
      arrival_orders();
      reset_inflight();
      mismatch_case();
      model.stop_sampling();
      `uvm_info("ETH_SAMPLING_RATE_PASS", $sformatf("RATE=%0d matched=8 expected_mismatch=1 aborted_half_frame=1 reset_inflight=3", RATE), UVM_NONE)
      done = 1;
    endtask
  endclass

  // 三速率并行使用相同示例 API；包内容、复位和队列在实例间完全独立。
  class eth_rm_scb_test extends uvm_test;
    `uvm_component_utils(eth_rm_scb_test)
    sampling_rate_case#(100) r100;
    sampling_rate_case#(200) r200;
    sampling_rate_case#(400) r400;

    // 身份由 run_test/factory 管理。
    function new(string name = "eth_rm_scb_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 名称与 HDL 发布的 typed vif 路径一致。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      r100 = new("r100", this);
      r200 = new("r200", this);
      r400 = new("r400", this);
    endfunction

    // HDL 侧100us保护所有等待；完成标志只在所有 case 真正排空后发布。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait (r100.done && r200.done && r400.done);
      `uvm_info("ETH_SAMPLING_TEST_COMPLETE", "three rates: 24 matches, 3 expected mismatches, whole-packet reset recovery", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
