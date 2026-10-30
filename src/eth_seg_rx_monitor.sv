// src 观察层：RX segmented MAC 引脚监视器。
// 组件只在 o_rx_mac_valid 为 1 时消费各 segment；invalid 拍完全忽略数据和边带，
// 因而可跨任意气泡保存当前包。EOP 段提取 empty、fcs_error、error、status_data，
// 合法 CRC 错误通过事务字段传播而不触发 uvm_error；复位中断包计入 aborted_packets。
class eth_seg_rx_monitor #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_rx_monitor#(RATE))

  eth_seg_config#(RATE) cfg;
  virtual eth_seg_if#(RATE) vif;
  uvm_analysis_port#(eth_seg_seq_item) item_collected_port;
  int unsigned packets_seen, aborted_packets, valid_cycles, invalid_cycles;
  int unsigned idle_segments, data_segments, bytes_seen, same_cycle_boundaries;

  bit in_packet;
  int segment_index;
  eth_seg_byte_queue_t packet_bytes;
  eth_seg_seq_item packet_item;

  // 创建发布端口；monitor 不拥有 virtual interface 的生命周期。
  function new(string name = "eth_seg_rx_monitor", uvm_component parent = null);
    super.new(name, parent);
    item_collected_port = new("item_collected_port", this);
  endfunction

  // 取得父 agent 提供的配置和虚接口，缺失时立即终止以避免静默空循环。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg != null) vif = cfg.vif;
    if (vif == null) `uvm_fatal("ETH_SEG_RX_MON_CFG", "RX monitor virtual interface is null")
  endfunction

  // 返回无未完成报文；复位丢弃的包不会留在任何内部队列。
  function bit is_idle();
    return !in_packet && packet_bytes.size() == 0;
  endfunction

  // 按 segment 号和字节数提取低位优先的数据；只由有效拍调用。
  function void append_segment(input int seg, input int nbytes);
    for (int b = 0; b < nbytes; b++)
      packet_bytes.push_back(vif.rx_cb.o_rx_mac_data[seg*64 + b*8 +: 8]);
    bytes_seen += nbytes;
  endfunction

  // EOP 完成事务解析并发布；错误边带仅记录在事务中，CRC 错误允许继续比较。
  task automatic finish_packet(input int seg, input int empty);
    string reason;
    bit ok;
    packet_item.eop_segment = segment_index;
    packet_item.empty_bytes = empty;
    packet_item.rx_fcs_error = vif.rx_cb.o_rx_mac_fcs_error[seg];
    packet_item.rx_error = vif.rx_cb.o_rx_mac_error[seg*2 +: 2];
    packet_item.rx_status = vif.rx_cb.o_rx_mac_status_data[seg*3 +: 3];
    packet_item.direction = ETH_SEG_RX;
    ok = eth_seg_codec::decode(packet_bytes, cfg.preamble_passthrough,
                               cfg.include_fcs, packet_item, reason);
    if (!ok) begin
      `uvm_error("ETH_SEG_RX_MON_FORMAT", $sformatf("ETH_SEG_RX_FORMAT: %s", reason))
      packet_item.aborted = 1;
    end
    packet_item.end_time = $time;
    item_collected_port.write(packet_item);
    packets_seen++;
    packet_item = null;
    packet_bytes.delete();
    in_packet = 0;
  endtask

  // 在 RX 正沿逐 segment 解析；invalid 周期不改变 segment_index、边界或数据状态。
  task run_phase(uvm_phase phase);
    bit ended_this_cycle;
    forever begin
      @(vif.rx_cb);
      if (!vif.rx_cb.i_rx_rst_n) begin
        if (in_packet) aborted_packets++;
        in_packet = 0;
        packet_bytes.delete();
        packet_item = null;
        segment_index = 0;
        continue;
      end
      if (!vif.rx_cb.o_rx_mac_valid) begin
        invalid_cycles++;
        continue;
      end
      valid_cycles++;
      ended_this_cycle = 0;
      for (int s = 0; s < RATE/25; s++) begin
        bit seg_inframe = vif.rx_cb.o_rx_mac_inframe[s];
        int empty = vif.rx_cb.o_rx_mac_eop_empty[s*3 +: 3];
        int nbytes;
        if (!in_packet && !seg_inframe) begin
          idle_segments++;
          continue;
        end
        if (!in_packet) begin
          in_packet = 1;
          packet_bytes.delete();
          packet_item = new("rx_mon_item");
          packet_item.start_segment = segment_index;
          packet_item.start_time = $time;
          if (ended_this_cycle) same_cycle_boundaries++;
        end
        data_segments++;
        nbytes = seg_inframe ? 8 : (8 - empty);
        if (!seg_inframe && (empty > 7 || nbytes < 1)) begin
          `uvm_error("ETH_SEG_RX_MON_EMPTY", "ETH_SEG_RX_EMPTY_INVALID: EOP empty must be 0..7")
          nbytes = 1;
        end
        append_segment(s, nbytes);
        if (!seg_inframe) begin
          finish_packet(s, empty);
          ended_this_cycle = 1;
        end
        segment_index++;
      end
    end
  endtask
endclass
