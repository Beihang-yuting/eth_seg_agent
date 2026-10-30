// seq_lib 公共网络报文 sequence：在 eth_net_packet_pkg 内编译，依赖 net_packet_pkg
// 和 eth_seg_pkg；不包含 net_packet 单文件，避免同名 packet 出现在不同 package。
// pkt 是调用方借出的报文；已打包内容只读，首次自动打包会更新该报文的 raw_data/校验字段。
// 每次转换都创建独立事务及字节数组，driver 仍按现有约定再深拷贝入队。
class eth_base_seq extends uvm_sequence#(eth_seg_seq_item);
  `uvm_object_utils(eth_base_seq)

  // 直接 start 时发送这一帧；批量/协议流程通过派生 body 调用 send_packet。
  // 本类不拥有协议头，也不在发送后清空 pkt，调用者可显式重复发送同一份字节快照。
  net_packet_pkg::packet pkt;

  // 初始化 UVM sequence 身份；不隐式创建或随机化网络报文，漏传 pkt 应明确失败。
  function new(string name = "eth_base_seq");
    super.new(name);
  endfunction

  // 返回新事务，逐字节保持网络顺序：raw_data[0] 对应目的 MAC 第一个字节。
  // 非空 raw_data 是权威输入，不重新打包、不修复校验和、不补齐短帧、不剥离尾部 ICRC。
  // raw_data 为空时只允许从 Ethernet 协议栈自动打包；空句柄、空栈、非 Ethernet 栈、
  // 小于 14B 的结果立即 fatal 并返回 null，避免禁用 fatal 动作后继续访问非法数据。
  // packet_to_item 可脱离 sequencer 单独使用；返回值由调用方拥有，可调整事务边带。
  virtual function eth_seg_seq_item packet_to_item(input net_packet_pkg::packet net_pkt);
    eth_seg_seq_item item;

    if (net_pkt == null) begin
      `uvm_fatal("ETH_NET_NULL", "packet must not be null")
      return null;
    end

    if (net_pkt.raw_data.size() == 0) begin
      if (net_pkt.layer_stack.size() == 0) begin
        `uvm_fatal("ETH_NET_EMPTY", "packet has neither packed bytes nor protocol layers")
        return null;
      end
      foreach (net_pkt.layer_stack[i]) begin
        if (net_pkt.layer_stack[i] == null) begin
          `uvm_fatal("ETH_NET_LAYER", "packet contains a null protocol layer")
          return null;
        end
      end
      if (net_pkt.layer_stack[0].proto_type != net_packet_pkg::PROTO_ETHERNET) begin
        `uvm_fatal("ETH_NET_LAYER", "unpacked packet must start with Ethernet")
        return null;
      end
      net_pkt.do_pack();
    end

    if (net_pkt.raw_data.size() < 14) begin
      `uvm_fatal("ETH_NET_LENGTH", "Ethernet packet must contain at least 14 bytes")
      return null;
    end

    item = eth_seg_seq_item::type_id::create("net_frame");
    item.frame_bytes = new[net_pkt.raw_data.size()];
    foreach (item.frame_bytes[i]) item.frame_bytes[i] = net_pkt.raw_data[i];
    // net_packet 的输出不含 Ethernet FCS；其 RoCEv2 ICRC 是上层报文内容。
    // 前导与 Ethernet FCS 由 agent cfg/codec 添加，不根据末尾四字节猜测帧格式。
    item.fcs_present = 0;
    return item;
  endfunction

  // 在已启动的本 sequence 所属 sqr 上发送一帧；支持 CLIENT TX 和 MAC RX，
  // 方向由 agent 的 driver 决定，不需要 RATE 或额外虚拟 sequencer。
  // finish_item 仅表示 driver 已复制入队；调用者须等待 monitor/scoreboard 才能结束 test。
  virtual task send_packet(input net_packet_pkg::packet net_pkt);
    eth_seg_seq_item item;

    if (get_sequencer() == null) begin
      `uvm_fatal("ETH_NET_SQR", "start eth_base_seq on an active Ethernet sequencer before sending")
      return;
    end
    item = packet_to_item(net_pkt);
    if (item == null) return;
    start_item(item);
    finish_item(item);
  endtask

  // 默认单包路径；业务子类可覆写 body 并反复调用 send_packet，转换逻辑只有一份。
  virtual task body();
    send_packet(pkt);
  endtask
endclass
