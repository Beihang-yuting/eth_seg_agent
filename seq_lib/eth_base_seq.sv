// seq_lib 公共网络报文 sequence：在 eth_net_packet_pkg 内编译，依赖 net_packet_pkg
// 和 eth_seg_pkg；不包含 net_packet 单文件，避免同名 packet 出现在不同 package。
// pkt 是调用方借出的报文；已打包内容只读，首次自动打包会更新该报文的 raw_data/校验字段。
// 每次转换都创建独立事务及字节数组，driver 仍按现有约定再深拷贝入队。
// 采样方法借用 agent 的永久 hub；RM/SCB 用独立对象 set_sequencer，不启动发送 body。
class eth_base_seq extends uvm_sequence#(eth_seg_seq_item);
  `uvm_object_utils(eth_base_seq)

  // 非空 pkt 按原字节重放 count 次；为空则每轮 create_packet 构造新的报文。
  // 显式 pkt 属于调用方；生成路径只用局部对象，不能覆盖此输入而误切换为重放。
  net_packet_pkg::packet pkt;
  int count = 1;
  protected bit last_send_ok;

  // 初始化 UVM 身份；构造不发送，默认报文仅在 body 的逐包生成阶段建立。
  function new(string name = "eth_base_seq");
    super.new(name);
  endfunction

  // 统一校验 sqr 类型和发送能力；采样允许 passive，发送拒绝无 driver 的仲裁器。
  protected function eth_seg_sequencer require_sqr(bit sending = 0);
    eth_seg_sequencer handle;
    if (!$cast(handle, get_sequencer()) || handle == null) begin
      `uvm_fatal("ETH_NET_SQR", "an Ethernet sequencer must be associated before use")
      return null;
    end
    if (sending && !handle.can_send) begin
      `uvm_fatal("ETH_NET_PASSIVE", "this Ethernet sequencer has no sending driver")
      return null;
    end
    return handle;
  endfunction

  // 注册整包消费者；portid 按当前 agent/方向区分，与 IP 编号无关。
  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    eth_seg_sequencer handle = require_sqr();
    if (handle != null) handle.subscribe(dir, portid, depth);
  endfunction

  // 一次取一个完整 Ethernet 帧，组包由 Monitor 完成；timeout=0 无限等待。
  // 超时/取消返回 null，复位清缓存但继续等待；调用者必须检查返回句柄。
  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    eth_seg_sequencer handle = require_sqr();
    tr = null;
    if (handle != null) handle.mon_xaction(tr, dir, portid, timeout);
  endtask

  // 撤销订阅并唤醒等待者；发送命令结束不会自动取消其它对象使用的持久订阅。
  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_sequencer handle = require_sqr();
    if (handle != null) handle.unsubscribe(dir, portid);
  endfunction

  // 无显式 pkt 时每包新建默认 256B IPv4/UDP；业务/AIP 子类覆写此函数读取参数。
  // 本函数不修改输入 pkt；修改协议头后应重新 do_pack，返回的字节才会反映新字段。
  virtual function net_packet_pkg::packet create_packet(int unsigned packet_index);
    net_packet_pkg::packet generated = new();
    generated.build_from_template(net_packet_pkg::ETH_IPV4_UDP);
    generated.pkt_len = 256;
    generated.payload_mode = net_packet_pkg::PAYLOAD_FIXED;
    generated.payload_fixed_val = 8'ha5;
    generated.do_pack();
    return generated;
  endfunction

  // 每包成功入队后的可选通知；基础 VIP 无外部活动计数依赖，也不表示物理完成。
  virtual function void packet_queued(int unsigned packet_index);
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

    last_send_ok = 0;
    if (require_sqr(1) == null) return;
    item = packet_to_item(net_pkt);
    if (item == null) return;
    start_item(item);
    finish_item(item);
    last_send_ok = 1;
  endtask

  // 唯一的 count 循环；生成器或转换失败时停止，不触发成功通知。调用者持有 objection
  // 直到 Monitor/RM/SCB 排空；Tcl 命令返回不等于线上 count 个包已经全部结束。
  virtual task body();
    if (require_sqr(1) == null) return;
    if (count <= 0) begin
      `uvm_fatal("ETH_NET_COUNT", "count must be positive")
      return;
    end
    for (int n = 0; n < count; n++) begin
      net_packet_pkg::packet current_packet;
      current_packet = (pkt != null) ? pkt : create_packet(n);
      if (current_packet == null) begin
        `uvm_fatal("ETH_NET_NULL", "packet generator returned null")
        return;
      end
      send_packet(current_packet);
      if (!last_send_ok) return;
      packet_queued(n);
    end
  endtask
endclass
