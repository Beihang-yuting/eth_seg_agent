// src 观察层：TX segmented client 引脚监视器。
// 本组件只读 eth_seg_if 的公共 TX 网络，逐个有效 segment 重建字节队列；
// 它拥有当前包的临时状态和发布事务，不驱动 interface，也不与 driver 共享可变对象。
// reset_state_port 只发布本方向采样到的复位变化，hub/test 决定缓存和预测清理策略。
// skip_crc 由引脚逐段采样并作为当前包的 FCS 格式依据；CRC 错误属于合法报文，
// 仅记录 fcs_ok=0，格式损坏才报告 UVM_ERROR。复位期间未结束的包被标记 aborted 丢弃。
class eth_seg_tx_monitor #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_tx_monitor#(RATE))

  eth_seg_config#(RATE) cfg;
  virtual eth_seg_if#(RATE) vif;
  uvm_analysis_port#(eth_seg_seq_item) item_collected_port;
  uvm_analysis_port#(bit) reset_state_port;
  bit reset_observed, previous_reset;
  int unsigned packets_seen, aborted_packets, valid_cycles, invalid_cycles;
  int unsigned idle_segments, data_segments, bytes_seen, same_cycle_boundaries;

  bit in_packet;
  bit packet_skip_crc;
  int segment_index;
  eth_seg_byte_queue_t packet_bytes;
  eth_seg_seq_item packet_item;

  // 创建端口和计数器；配置由 agent 在 build 后预设，run 时只读。
  function new(string name = "eth_seg_tx_monitor", uvm_component parent = null);
    super.new(name, parent);
    item_collected_port = new("item_collected_port", this);
    reset_state_port = new("reset_state_port", this);
  endfunction

  // 连接配置并检查虚接口；agent 也可直接写入 cfg/vif 后调用该组件。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg != null) vif = cfg.vif;
    if (vif == null) `uvm_fatal("ETH_SEG_TX_MON_CFG", "TX monitor virtual interface is null")
  endfunction

  // 判断监视器是否没有待完成报文；复位中断包也必须已经清空才算 idle。
  function bit is_idle();
    return !in_packet && packet_bytes.size() == 0;
  endfunction

  // 将一个 64-bit segment 的低端字节按 Ethernet 发送顺序追加到当前包。
  // nbytes 由 inframe/eop_empty 决定，EOP 至少保留一个字节；非法 empty 由调用方诊断。
  function void append_segment(input int seg, input int nbytes);
    for (int b = 0; b < nbytes; b++)
      packet_bytes.push_back(vif.tx_cb.i_tx_mac_data[seg*64 + b*8 +: 8]);
    bytes_seen += nbytes;
  endfunction

  // 在 EOP 处完成 codec 解码、填充边带并发布深拷贝事务；CRC 不匹配不视为格式错误。
  task automatic finish_packet(input int seg, input int empty, input bit error_bit);
    string reason;
    bit ok;
    packet_item.eop_segment = segment_index;
    packet_item.empty_bytes = empty;
    packet_item.inject_error = error_bit;
    packet_item.direction = ETH_SEG_TX;
    ok = eth_seg_codec::decode(packet_bytes, cfg.preamble_passthrough,
                               packet_skip_crc, packet_item, reason);
    if (!ok) begin
      `uvm_error("ETH_SEG_TX_MON_FORMAT", $sformatf("ETH_SEG_TX_FORMAT: %s", reason))
      packet_item.aborted = 1;
    end
    packet_item.end_time = $time;
    item_collected_port.write(packet_item);
    packets_seen++;
    packet_item = null;
    packet_bytes.delete();
    in_packet = 0;
  endtask

  // 在 TX 正沿采样；无效拍保持解析状态，按 segment 顺序支持同拍 EOP 后接 SOP。
  task run_phase(uvm_phase phase);
    bit ended_this_cycle;
    forever begin
      @(vif.tx_cb);
      // 同一采样域首次同步及复位边沿通知；先清理 hub，再消费本拍数据。
      // X 复位由接口检查负责，此处只将确定的低电平视为断言。
      if (!reset_observed || previous_reset != (vif.tx_cb.i_tx_rst_n === 1'b0)) begin
        reset_observed = 1;
        previous_reset = (vif.tx_cb.i_tx_rst_n === 1'b0);
        reset_state_port.write(previous_reset);
      end
      if (!vif.tx_cb.i_tx_rst_n) begin
        if (in_packet) aborted_packets++;
        in_packet = 0;
        packet_bytes.delete();
        packet_item = null;
        segment_index = 0;
        continue;
      end
      if (!vif.tx_cb.i_tx_mac_valid) begin
        invalid_cycles++;
        continue;
      end
      valid_cycles++;
      ended_this_cycle = 0;
      for (int s = 0; s < RATE/25; s++) begin
        bit seg_inframe = vif.tx_cb.i_tx_mac_inframe[s];
        int empty = vif.tx_cb.i_tx_mac_eop_empty[s*3 +: 3];
        int nbytes;
        if (!in_packet && !seg_inframe) begin
          idle_segments++;
          continue;
        end
        if (!in_packet) begin
          in_packet = 1;
          packet_skip_crc = vif.tx_cb.i_tx_mac_skip_crc[s];
          packet_bytes.delete();
          packet_item = new("tx_mon_item");
          packet_item.start_segment = segment_index;
          packet_item.start_time = $time;
          if (ended_this_cycle) same_cycle_boundaries++;
        end
        else if (vif.tx_cb.i_tx_mac_skip_crc[s] !== packet_skip_crc)
          `uvm_error("ETH_SEG_TX_MON_SKIP", "ETH_SEG_TX_SKIP_CRC_CHANGED: skip_crc changed in packet")
        data_segments++;
        nbytes = seg_inframe ? 8 : (8 - empty);
        if (!seg_inframe && (empty > 7 || nbytes < 1)) begin
          `uvm_error("ETH_SEG_TX_MON_EMPTY", "ETH_SEG_TX_EMPTY_INVALID: EOP empty must be 0..7")
          nbytes = 1;
        end
        append_segment(s, nbytes);
        if (!seg_inframe) begin
          finish_packet(s, empty, vif.tx_cb.i_tx_mac_error[s]);
          ended_this_cycle = 1;
        end
        segment_index++;
      end
    end
  endtask
endclass
