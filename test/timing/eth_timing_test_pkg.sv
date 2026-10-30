// test/timing 时序审查：独立的 pin 段计数器检查包间隔，monitor 检查字节和完成通知。
// 依赖产品 driver/monitor/interface；case 拥有组件、事务快照和 pin 记录，借用 HDL vif。
// DUT ready 由 HDL 分别在正/负沿寄存，避免仅用 VIP ready driver 掩盖采样相位错误。
package eth_timing_test_pkg;
  import uvm_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_types_pkg::*;
  `include "uvm_macros.svh"

  // 只负责送出已有事务，测试在外部检查物理完成，不能以 finish_item 结束用例。
  class timing_seq extends uvm_sequence#(eth_seg_seq_item);
    eth_seg_seq_item items[$];

    // 刺激事务由 case 构造并在发送期间保持不变。
    function new(string name = "timing_seq");
      super.new(name);
    endfunction

    // 按队列顺序交给 driver，max_pending 边界应由 driver 自行反压。
    task body();
      foreach (items[i]) begin
        start_item(items[i]);
        finish_item(items[i]);
      end
    endtask
  endclass

  // 收集真实 monitor/driver 通知的副本，避免回调之后对象复用影响比较。
  class timing_sink extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_seq_item items[$];

    // 接收器由 case 创建，随 UVM 层次退出。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 每次回调保存独立数据；不改变来源事务，也不引入仿真延时。
    function void write(eth_seg_seq_item t);
      eth_seg_seq_item cp = new("observed");
      cp.copy(t);
      items.push_back(cp);
    endfunction
  endclass

  // 每种 RATE 有正沿 ready、负沿 ready 两条独立 link；TX/RX 使用不同周期。
  class timing_case #(int RATE = 100) extends uvm_component;
    localparam int SEGMENTS = RATE/25;
    virtual eth_seg_if#(RATE) vif;
    virtual eth_timing_control ctl;
    eth_seg_config#(RATE) tc, rc;
    eth_seg_tx_driver#(RATE) tx;
    eth_seg_rx_driver#(RATE) rx;
    eth_seg_tx_monitor#(RATE) tm;
    eth_seg_rx_monitor#(RATE) rm;
    eth_seg_sequencer ts, rs;
    timing_sink ta, ra, te, re;
    int tx_sop[$], tx_eop[$], rx_sop[$], rx_eop[$];
    int tx_slot = 0, rx_slot = 0;
    bit tx_packet = 0, rx_packet = 0, done = 0;
    string scenario = "all";

    // case 名称匹配 HDL config_db 路径，不依赖 factory 特化字符串。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 直接组合被测 driver/monitor；ready 为外部 DUT 驱动，不创建 VIP ready driver。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual eth_seg_if#(RATE))::get(this, "", "vif", vif) ||
          !uvm_config_db#(virtual eth_timing_control)::get(this, "", "control", ctl))
        `uvm_fatal("TIMING_VIF", "missing timing fixture interfaces")
      void'($value$plusargs("SCENARIO=%s", scenario));
      tc = new("tx_cfg"); rc = new("rx_cfg");
      tc.vif = vif; rc.vif = vif;
      rc.role = ETH_SEG_MAC;
      tc.max_pending = 2; rc.max_pending = 2;
      tx = new("tx", this); rx = new("rx", this);
      tm = new("tm", this); rm = new("rm", this);
      ts = new("ts", this); rs = new("rs", this);
      tx.cfg = tc; tm.cfg = tc; rx.cfg = rc; rm.cfg = rc;
      ta = new("tx_actual", this); ra = new("rx_actual", this);
      te = new("tx_sent", this); re = new("rx_sent", this);
    endfunction

    // monitor 与 sent_ap 分别记录，检查数量、方向、字节及同一 EOP 采样时间。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      tx.seq_item_port.connect(ts.seq_item_export);
      rx.seq_item_port.connect(rs.seq_item_export);
      tm.item_collected_port.connect(ta.analysis_export);
      rm.item_collected_port.connect(ra.analysis_export);
      tx.sent_ap.connect(te.analysis_export);
      rx.sent_ap.connect(re.analysis_export);
    endfunction

    // 记录有效拍内所有段的绝对位置，包含 idle 段；用于独立测量 EOP→SOP 间隔。
    task track_tx();
      forever begin
        @(vif.tx_cb);
        if (!vif.tx_cb.i_tx_rst_n) begin
          tx_slot = 0; tx_packet = 0; tx_sop.delete(); tx_eop.delete();
        end
        else if (vif.tx_cb.i_tx_mac_valid) begin
          for (int s = 0; s < SEGMENTS; s++) begin
            if (!tx_packet && vif.tx_cb.i_tx_mac_inframe[s]) begin tx_sop.push_back(tx_slot); tx_packet = 1; end
            else if (tx_packet && !vif.tx_cb.i_tx_mac_inframe[s]) begin tx_eop.push_back(tx_slot); tx_packet = 0; end
            tx_slot++;
          end
        end
      end
    endtask

    // RX valid 气泡不消费 segment；valid=1 的尾部 idle 仍占段位置。
    task track_rx();
      forever begin
        @(vif.rx_cb);
        if (!vif.rx_cb.i_rx_rst_n) begin
          rx_slot = 0; rx_packet = 0; rx_sop.delete(); rx_eop.delete();
        end
        else if (vif.rx_cb.o_rx_mac_valid) begin
          for (int s = 0; s < SEGMENTS; s++) begin
            if (!rx_packet && vif.rx_cb.o_rx_mac_inframe[s]) begin rx_sop.push_back(rx_slot); rx_packet = 1; end
            else if (rx_packet && !vif.rx_cb.o_rx_mac_inframe[s]) begin rx_eop.push_back(rx_slot); rx_packet = 0; end
            rx_slot++;
          end
        end
      end
    endtask

    // 复位覆盖两种时钟的多个正/负沿；解除在边沿之外，TX/RX 分开释放。
    // 此处只清测试快照；产品 driver/monitor 必须自行丢弃在途状态。
    task reset_link();
      #1ns;
      ctl.tx_rst_n = 0; ctl.rx_rst_n = 0; ctl.ready_request = 0;
      #37ns;
      ctl.tx_rst_n = 1;
      #7ns;
      ctl.rx_rst_n = 1; ctl.ready_request = 1;
      #30ns;
      ta.items.delete(); ra.items.delete(); te.items.delete(); re.items.delete();
      tc.traffic_load_pct = 100; rc.traffic_load_pct = 100;
      tc.random_load = 0; rc.random_load = 0;
      rc.rx_valid_pattern = ETH_SEG_CONTINUOUS;
    endtask

    // 生成独特数据及不同 EOP 边带，所有长度不少于 9B；gap 单位为有效 idle segment。
    function void fill(input timing_seq seq, input int count, input int length, input int gap);
      for (int n = 0; n < count; n++) begin
        eth_seg_seq_item item = new("stimulus");
        item.frame_bytes = new[length];
        foreach (item.frame_bytes[i]) item.frame_bytes[i] = byte'(n*37 + i*13 + RATE);
        item.gap_segments = gap;
        item.inject_error = n[0]; item.rx_error = n[1:0]; item.rx_status = n[2:0];
        item.rx_fcs_error = n[0];
        seq.items.push_back(item);
      end
    endfunction

    // 核对独立刺激与 monitor 字节，并检查 sent_ap 没有早报、漏报或复位后旧包复活。
    function void compare(input timing_seq seq, input timing_sink actual, input timing_sink sent, input bit is_rx);
      if (actual.items.size() != seq.items.size() || sent.items.size() != seq.items.size()) begin
        `uvm_error("TIMING_COUNT", $sformatf("rx=%0b expected=%0d actual=%0d sent=%0d", is_rx, seq.items.size(), actual.items.size(), sent.items.size()))
        return;
      end
      foreach (seq.items[n]) begin
        eth_seg_seq_item exp = seq.items[n];
        eth_seg_seq_item got = actual.items[n];
        if (got.frame_bytes != exp.frame_bytes || sent.items[n].frame_bytes != exp.frame_bytes ||
            got.end_time != sent.items[n].end_time || got.direction != (is_rx ? ETH_SEG_RX : ETH_SEG_TX) || got.aborted)
          `uvm_error("TIMING_DATA", $sformatf("rx=%0b packet=%0d bytes/time/direction differ", is_rx, n))
        if (is_rx ? ({got.rx_error,got.rx_status,got.rx_fcs_error} != {exp.rx_error,exp.rx_status,exp.rx_fcs_error}) :
                     (got.inject_error != exp.inject_error))
          `uvm_error("TIMING_EOP", "EOP sidebands differ")
      end
    endfunction

    // 带超时地等物理完成；is_idle 也检查最终 EOP 之后不存在幽灵包。
    task drain(input timing_seq seq);
      for (int i = 0; i < 5000; i++) begin
        if (ta.items.size() >= seq.items.size() && ra.items.size() >= seq.items.size() &&
            tx.is_idle() && rx.is_idle() && tm.is_idle() && rm.is_idle()) break;
        #10ns;
      end
      #24ns;
      compare(seq, ta, te, 0); compare(seq, ra, re, 1);
      if (!tx.is_idle() || !rx.is_idle() || !tm.is_idle() || !rm.is_idle())
        `uvm_error("TIMING_DRAIN", "driver or monitor did not drain")
    endtask

    // 队列全程有包，独立 pin 记录应至少观察到配置规定的 idle 段数。
    function void check_gaps(input int minimum);
      foreach (tx_sop[i]) if (i > 0 && i-1 < tx_eop.size() && tx_sop[i]-tx_eop[i-1]-1 < minimum)
        `uvm_error("TIMING_TX_GAP", $sformatf("packet=%0d gap=%0d minimum=%0d", i, tx_sop[i]-tx_eop[i-1]-1, minimum))
      foreach (rx_sop[i]) if (i > 0 && i-1 < rx_eop.size() && rx_sop[i]-rx_eop[i-1]-1 < minimum)
        `uvm_error("TIMING_RX_GAP", $sformatf("packet=%0d gap=%0d minimum=%0d", i, rx_sop[i]-rx_eop[i-1]-1, minimum))
    endfunction

    // 运行独立阶段：ready 单拍脉冲/包内停顿、显式间隔、固定/随机负载和中途复位。
    // SCENARIO 用于在未修复基线上分别复现，默认 all 作为固定回归。
    task exercise();
      if (scenario inside {"all", "ready"}) begin
        timing_seq a = new("ready_tx"), b = new("ready_rx");
        reset_link();
        rc.rx_valid_pattern = ETH_SEG_PERIODIC;
        rc.rx_valid_high_cycles = 1; rc.rx_valid_low_cycles = 3;
        for (int i = 9; i < 17; i++) begin fill(a,1,i,0); fill(b,1,i,0); end
        fill(a,2,257,0); fill(b,2,257,0);
        fork
          a.start(ts);
          b.start(rs);
          begin
            for (int i = 0; i < 32; i++) begin
              @(negedge ctl.tx_clk); #1ns;
              ctl.ready_request = (i % 7 == 0 || i % 7 >= 4);
            end
            ctl.ready_request = 1;
          end
        join
        drain(a);
      end
      if (scenario inside {"all", "gap", "load", "random_load"}) begin
        for (int mode = 0; mode < 3; mode++) begin
          timing_seq a = new("gap_tx"), b = new("gap_rx");
          int minimum = (mode == 0) ? 3 : (mode == 1) ? 2 : 6;
          if (scenario != "all" && scenario != ((mode == 0) ? "gap" : (mode == 1) ? "load" : "random_load")) continue;
          reset_link();
          if (mode == 0) begin
            rc.rx_valid_pattern = ETH_SEG_PERIODIC;
            rc.rx_valid_high_cycles = 1; rc.rx_valid_low_cycles = 3;
          end
          if (mode == 1) begin tc.traffic_load_pct = 50; rc.traffic_load_pct = 50; end
          if (mode == 2) begin
            tc.random_load = 1; rc.random_load = 1;
            tc.load_min_pct = 25; tc.load_max_pct = 25;
            rc.load_min_pct = 25; rc.load_max_pct = 25;
          end
          fill(a,12,9,(mode == 0) ? 3 : 0);
          fill(b,12,9,(mode == 0) ? 3 : 0);
          fork
            a.start(ts);
            b.start(rs);
            begin
              if (mode == 0) begin
                // 包间隔遇到 ready/valid 气泡仍应以有效段计数，不能按物理时钟偷减。
                for (int i = 0; i < 60; i++) begin
                  @(negedge ctl.tx_clk); #1ns;
                  ctl.ready_request = (i % 4 == 0);
                end
                ctl.ready_request = 1;
              end
            end
          join
          drain(a);
          check_gaps(minimum);
        end
      end
      if (scenario inside {"all", "reset"}) begin
        timing_seq a = new("aborted_tx"), b = new("aborted_rx");
        timing_seq c = new("recovery_tx"), d = new("recovery_rx");
        reset_link();
        fill(a,3,2048,0); fill(b,3,2048,0);
        fork a.start(ts); b.start(rs); join
        #12ns;
        reset_link();
        if (tm.aborted_packets == 0 || rm.aborted_packets == 0)
          `uvm_error("TIMING_RESET_COVER", "reset did not interrupt both directions")
        fill(c,4,65,0); fill(d,4,65,0);
        fork c.start(ts); d.start(rs); join
        drain(c);
      end
      `uvm_info("TIMING_CASE_COMPLETE", $sformatf("RATE=%0d scenario=%s", RATE, scenario), UVM_NONE)
      done = 1;
    endtask

    // 观察线程与刺激并行，UVM phase 结束时统一终止观察线程。
    task run_phase(uvm_phase phase);
      fork track_tx(); track_rx(); join_none
      exercise();
    endtask
  endclass

  // 六条 link 同时执行，测试只持有一个 objection，HDL watchdog 保证卡死可见。
  class eth_timing_test extends uvm_test;
    `uvm_component_utils(eth_timing_test)
    timing_case#(100) c100[2];
    timing_case#(200) c200[2];
    timing_case#(400) c400[2];

    // 构造 UVM test 身份，子 case 由 build 创建。
    function new(string name = "eth_timing_test", uvm_component parent = null);
      super.new(name,parent);
    endfunction

    // phase=0/1 对应 HDL 在负沿/正沿寄存 ready 的两种 DUT 行为。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      for (int p = 0; p < 2; p++) begin
        c100[p] = new($sformatf("r100_p%0d",p),this);
        c200[p] = new($sformatf("r200_p%0d",p),this);
        c400[p] = new($sformatf("r400_p%0d",p),this);
      end
    endfunction

    // 所有 case 完成后才结束；错误仍由 check_log.py 从 UVM summary/native error 判定。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      foreach (c100[i]) wait (c100[i].done && c200[i].done && c400[i].done);
      `uvm_info("ETH_TIMING_TEST_COMPLETE", "six timing fixtures completed", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
