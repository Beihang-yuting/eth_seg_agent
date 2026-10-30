// src TX 驱动层：把字节事务切成并行 64-bit segments，并实现 ready→valid 两拍延迟。
// prefetch 线程在 item_done 时仅转移深拷贝；驱动线程在负沿更新私有代理，完成线程在正沿
// 采样 EOP 后发布 sent_ap，保证 sequence 完成与物理发送完成语义分离。
class eth_seg_tx_driver #(int RATE = 100) extends uvm_driver #(eth_seg_seq_item);
  `uvm_component_param_utils(eth_seg_tx_driver#(RATE))
  localparam int NUM_SEGMENTS = RATE/25;
  localparam int DATA_WIDTH = RATE/25*64;
  eth_seg_config#(RATE) cfg;
  uvm_analysis_port #(eth_seg_seq_item) sent_ap;
  int unsigned packets_sent = 0;
  eth_seg_seq_item pending[$], done_q[$];
  eth_seg_seq_item active;
  eth_seg_byte_queue_t encoded;
  int byte_ptr = 0;
  int idle_left = 0;
  bit have_active = 0;
  bit ready_d1 = 0, ready_d2 = 0;

  // 创建端口和队列；cfg 由 agent 在 build/connect 前注入，驱动不复制配置对象。
  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  // 判断发送队列、当前包及完成通知是否全部清空，用于 env 的 drain 等待。
  function bit is_idle();
    return pending.size() == 0 && !have_active && done_q.size() == 0;
  endfunction

  // 预取 sequence 项的深拷贝并尽早 item_done；队列达到 max_pending 时反压 sequence。
  // reset 期间丢弃副本，避免复位解除后意外续传旧包。
  task prefetch_thread();
    eth_seg_seq_item req, cp;
    forever begin
      if (cfg == null || cfg.vif == null) begin #1ns; continue; end
      while (pending.size() >= cfg.max_pending && cfg.vif.i_tx_rst_n) @(posedge cfg.vif.i_clk_tx);
      seq_item_port.get_next_item(req);
      cp = new("tx_prefetch_copy");
      cp.copy(req);
      seq_item_port.item_done();
      if (!cfg.vif.i_tx_rst_n) cp.aborted = 1;
      if (!cp.aborted) pending.push_back(cp);
    end
  endtask

  // 将当前 packet 的若干 segment 组合到私有代理；EOP 后允许同拍拉取下一个包的 SOP。
  // data 和所有边带在 valid=0 时保持上一次值，valid 仅由两拍 ready 历史决定。
  task drive_thread();
    bit current_ready, next_valid, cycle_idle;
    forever begin
      @(negedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin
        cfg.vif.drv_tx_valid <= 0;
        cfg.vif.drv_tx_data <= '0;
        cfg.vif.drv_tx_inframe <= '0;
        cfg.vif.drv_tx_eop_empty <= '0;
        cfg.vif.drv_tx_error <= '0;
        cfg.vif.drv_tx_skip_crc <= '0;
        ready_d1 = 0; ready_d2 = 0;
        active = null; have_active = 0; byte_ptr = 0;
        idle_left = 0;
        encoded.delete(); done_q.delete(); pending.delete();
        continue;
      end
      current_ready = cfg.vif.o_tx_mac_ready;
      // 两级历史分别保存上一拍和上两拍 ready；阻塞赋值让本次计算使用旧 d1，
      // 从而在下一个正沿得到 ready[t-1]，即相对采样正沿完整两拍延迟。
      ready_d2 = ready_d1;
      ready_d1 = current_ready;
      next_valid = ready_d2;
      cfg.vif.drv_tx_valid <= next_valid;
      if (!next_valid) continue;
      cycle_idle = 0;
      cfg.vif.drv_tx_data <= cfg.vif.drv_tx_data;
      cfg.vif.drv_tx_inframe <= cfg.vif.drv_tx_inframe;
      cfg.vif.drv_tx_eop_empty <= cfg.vif.drv_tx_eop_empty;
      cfg.vif.drv_tx_error <= cfg.vif.drv_tx_error;
      cfg.vif.drv_tx_skip_crc <= cfg.vif.drv_tx_skip_crc;
      for (int s = 0; s < NUM_SEGMENTS; s++) begin
        if (!have_active && idle_left == 0 && pending.size() != 0) begin
          active = pending.pop_front();
          if (active.frame_bytes.size() < 9) begin
            `uvm_error("ETH_TX_LEN", "TX frame must contain at least 9 bytes")
            active.aborted = 1;
          end
          eth_seg_codec::encode(active, cfg.preamble_passthrough, cfg.include_fcs, encoded);
          byte_ptr = 0; have_active = !active.aborted;
        end
        if (have_active) begin
          int remaining, nbytes;
          remaining = encoded.size() - byte_ptr;
          nbytes = (remaining > 8) ? 8 : remaining;
          for (int b = 0; b < 8; b++)
            cfg.vif.drv_tx_data[s*64 + b*8 +: 8] <= (b < nbytes) ? encoded[byte_ptr+b] : 8'h00;
          cfg.vif.drv_tx_inframe[s] <= (remaining > 8);
          cfg.vif.drv_tx_eop_empty[s*3 +: 3] <= (remaining > 8) ? 3'd0 : (8-nbytes);
          cfg.vif.drv_tx_error[s] <= (remaining <= 8) ? active.inject_error : 1'b0;
          cfg.vif.drv_tx_skip_crc[s] <= cfg.include_fcs;
          byte_ptr += nbytes;
          if (remaining <= 8) begin
            // sent_ap 事务必须与 monitor 的可见字节一致：自动 FCS 已并入数组，
            // 前导仍被 monitor 解码移除；因此这里复制编码结果而非发布原始 sequence 副本。
            eth_seg_seq_item sent = new("tx_sent_copy");
            sent.copy(active);
            sent.frame_bytes = new[encoded.size() - (cfg.preamble_passthrough ? 8 : 0)];
            for (int k = 0; k < sent.frame_bytes.size(); k++)
              sent.frame_bytes[k] = encoded[k + (cfg.preamble_passthrough ? 8 : 0)];
            sent.fcs_present = cfg.include_fcs;
            done_q.push_back(sent);
            active = null; have_active = 0; encoded.delete(); byte_ptr = 0;
            if (cfg.traffic_load_pct < 100) begin
              int pct = cfg.random_load ? $urandom_range(cfg.load_min_pct,cfg.load_max_pct) : cfg.traffic_load_pct;
              idle_left = (pct >= 100) ? 0 : $urandom_range(0, (100-pct)/10 + 1);
            end
          end
        end else begin
          // valid 仍由 ready 历史决定；包间节流以空闲 segment 表示，绝不改写 valid。
          cfg.vif.drv_tx_inframe[s] <= 1'b0;
          cfg.vif.drv_tx_eop_empty[s*3 +: 3] <= 3'd0;
          cfg.vif.drv_tx_error[s] <= 1'b0;
          cfg.vif.drv_tx_skip_crc[s] <= 1'b0;
          if (idle_left > 0) cycle_idle = 1'b1;
        end
      end
      if (cycle_idle && idle_left > 0) idle_left--;
    end
  endtask

  // 在 EOP 所在正沿读取真实 valid/inframe，按并行 segment 数发布已真正采样的报文。
  // reset 时清除待发布顺序，避免旧包在新一轮计数中出现。
  task completion_thread();
    forever begin
      @(posedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin done_q.delete(); packets_sent = 0; continue; end
      if (cfg.vif.i_tx_mac_valid) begin
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          if (!cfg.vif.i_tx_mac_inframe[s] && done_q.size() != 0) begin
            eth_seg_seq_item cp = done_q.pop_front();
            cp.direction = ETH_SEG_TX;
            cp.end_time = $time;
            sent_ap.write(cp);
            packets_sent++;
          end
        end
      end
    end
  endtask

  // 检查配置、领取 TX 所有权并启动并发线程；组件停止时释放所有权。
  task run_phase(uvm_phase phase);
    string reason;
    if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_TX_CFG", reason)
    cfg.vif.claim_tx(get_full_name());
    fork
      prefetch_thread();
      drive_thread();
      completion_thread();
    join_none
    forever @(posedge cfg.vif.i_clk_tx);
  endtask

  // release_phase 释放接口占用；正常 UVM 终止由父 phase kill 并发线程。
  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) cfg.vif.release_tx();
  endfunction
endclass
