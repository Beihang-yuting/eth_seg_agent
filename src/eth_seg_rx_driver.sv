// src RX 驱动层：将事务编码为 MAC 输出字节流，valid 节奏独立于 TX ready。
// 负沿更新 RX 私有代理；valid 低时不消费字节，故周期/随机节奏只插入有效气泡，
// 包内状态跨气泡保存。EOP 在正沿真正采样后通过 sent_ap 发布。
// 有效拍尾部没有下一包的 segment 必须显式置 idle，避免上拍 inframe 留下伪 SOP。
class eth_seg_rx_driver #(int RATE = 100) extends uvm_driver #(eth_seg_seq_item);
  `uvm_component_param_utils(eth_seg_rx_driver#(RATE))
  localparam int NUM_SEGMENTS = RATE/25;
  localparam int DATA_WIDTH = RATE/25*64;
  eth_seg_config#(RATE) cfg;
  uvm_analysis_port #(eth_seg_seq_item) sent_ap;
  int unsigned packets_sent = 0;
  eth_seg_seq_item pending[$], done_q[$], active;
  eth_seg_byte_queue_t encoded;
  int byte_ptr = 0, idle_left = 0, cycle_count = 0;
  bit have_active = 0;

  // 创建分析端口；RX 发送完成与 TX 相同，基于引脚 EOP 采样而非 item_done。
  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  // RX 无 ready，只有待发、在途和待发布队列为空时才报告 idle。
  function bit is_idle();
    return pending.size() == 0 && !have_active && done_q.size() == 0;
  endfunction

  // 预取并复制报文；复位时丢弃旧副本，保证 RX reset-in-packet 可恢复。
  task prefetch_thread();
    eth_seg_seq_item req, cp;
    forever begin
      if (cfg == null || cfg.vif == null) begin #1ns; continue; end
      while (pending.size() >= cfg.max_pending && cfg.vif.i_rx_rst_n) @(posedge cfg.vif.i_clk_rx);
      seq_item_port.get_next_item(req);
      cp = new("rx_prefetch_copy"); cp.copy(req); seq_item_port.item_done();
      if (!cfg.vif.i_rx_rst_n) cp.aborted = 1;
      if (!cp.aborted) pending.push_back(cp);
    end
  endtask

  // 依照 rx_valid_pattern 产生有效拍；traffic_load_pct 只在包间 idle segment 节流。
  // 一个有效周期最多输出 NUM_SEGMENTS 段，EOP 后剩余段可立刻承载下一包 SOP；
  // 若没有下一包则清空这些段的边界标记，不能把上一拍的数据段解释成新报文。
  task drive_thread();
    bit send_valid;
    forever begin
      @(negedge cfg.vif.i_clk_rx);
      if (!cfg.vif.i_rx_rst_n) begin
        cfg.vif.drv_rx_valid <= 0; cfg.vif.drv_rx_data <= '0;
        cfg.vif.drv_rx_inframe <= '0; cfg.vif.drv_rx_eop_empty <= '0;
        cfg.vif.drv_rx_fcs_error <= '0; cfg.vif.drv_rx_error <= '0; cfg.vif.drv_rx_status_data <= '0;
        pending.delete(); done_q.delete(); active = null; have_active = 0; encoded.delete(); byte_ptr = 0; idle_left = 0; cycle_count = 0;
        continue;
      end
      cycle_count++;
      send_valid = 1;
      case (cfg.rx_valid_pattern)
        ETH_SEG_CONTINUOUS: send_valid = 1;
        ETH_SEG_PERIODIC: begin
          int period = cfg.rx_valid_high_cycles + cfg.rx_valid_low_cycles;
          send_valid = ((cycle_count-1) % period) < cfg.rx_valid_high_cycles;
        end
        ETH_SEG_RANDOM: send_valid = ($urandom_range(0,99) < cfg.rx_valid_high_pct);
      endcase
      if (idle_left > 0 && !have_active) begin send_valid = 0; idle_left--; end
      // RX 没有待发事务时不产生伪造 valid；有事务后 pattern 再决定包内气泡。
      if (!have_active && pending.size() == 0) send_valid = 0;
      cfg.vif.drv_rx_valid <= send_valid;
      if (!send_valid) continue;
      for (int s = 0; s < NUM_SEGMENTS; s++) begin
        if (!have_active && pending.size() != 0) begin
          active = pending.pop_front();
          if (active.frame_bytes.size() < 9) begin `uvm_error("ETH_RX_LEN", "RX frame must contain at least 9 bytes"); active.aborted = 1; end
          eth_seg_codec::encode(active, cfg.preamble_passthrough, cfg.include_fcs, encoded);
          byte_ptr = 0; have_active = !active.aborted;
        end
        if (have_active) begin
          int remaining, nbytes;
          remaining = encoded.size() - byte_ptr; nbytes = (remaining > 8) ? 8 : remaining;
          for (int b = 0; b < 8; b++) cfg.vif.drv_rx_data[s*64+b*8 +: 8] <= (b<nbytes) ? encoded[byte_ptr+b] : 8'h00;
          cfg.vif.drv_rx_inframe[s] <= (remaining > 8);
          cfg.vif.drv_rx_eop_empty[s*3 +: 3] <= (remaining > 8) ? 3'd0 : (8-nbytes);
          cfg.vif.drv_rx_fcs_error[s] <= (remaining <= 8) ? active.rx_fcs_error : 1'b0;
          cfg.vif.drv_rx_error[s*2 +: 2] <= (remaining <= 8) ? active.rx_error : 2'b0;
          cfg.vif.drv_rx_status_data[s*3 +: 3] <= (remaining <= 8) ? active.rx_status : 3'b1;
          byte_ptr += nbytes;
          if (remaining <= 8) begin
            // sent_ap 与 RX monitor 的 frame_bytes 保持一致，包含启用的 FCS、但不包含前导。
            eth_seg_seq_item sent = new("rx_sent_copy");
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
          // o_rx_mac_valid 对整拍生效，尾部空段同样会被接收方检查 inframe。
          // 保留旧 inframe=1 会产生未结束的幽灵包，尤其易出现在宽总线的短尾拍。
          cfg.vif.drv_rx_data[s*64 +: 64] <= '0;
          cfg.vif.drv_rx_inframe[s] <= 1'b0;
          cfg.vif.drv_rx_eop_empty[s*3 +: 3] <= '0;
          cfg.vif.drv_rx_fcs_error[s] <= 1'b0;
          cfg.vif.drv_rx_error[s*2 +: 2] <= '0;
          cfg.vif.drv_rx_status_data[s*3 +: 3] <= '0;
        end
      end
    end
  endtask

  // 正沿确认 EOP 后按队列顺序发布 sent_ap；无效拍完全忽略 RX 边带。
  task completion_thread();
    forever begin
      @(posedge cfg.vif.i_clk_rx);
      if (!cfg.vif.i_rx_rst_n) begin done_q.delete(); packets_sent = 0; continue; end
      if (cfg.vif.o_rx_mac_valid) begin
        for (int s=0;s<NUM_SEGMENTS;s++) if (!cfg.vif.o_rx_mac_inframe[s] && done_q.size()!=0) begin
          eth_seg_seq_item cp = done_q.pop_front(); cp.direction = ETH_SEG_RX; cp.end_time = $time; sent_ap.write(cp); packets_sent++;
        end
      end
    end
  endtask

  // 校验配置并领取 RX 所有权；停止时 final_phase 归还网络驱动权。
  task run_phase(uvm_phase phase);
    string reason; if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_RX_CFG", reason)
    cfg.vif.claim_rx(get_full_name());
    fork prefetch_thread(); drive_thread(); completion_thread(); join_none
    forever @(posedge cfg.vif.i_clk_rx);
  endtask

  // 释放 RX 代理，避免下一次测试沿用本组件的占用标记。
  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) cfg.vif.release_rx();
  endfunction
endclass
