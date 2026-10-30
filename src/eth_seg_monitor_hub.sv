// src 整包采样层：agent 拥有本组件，双向 Monitor 在 EOP 发布的整包是唯一数据源。
// 每个 (direction, portid) 拥有独立副本队列；sequence 只借用 hub，命令结束不销毁缓存。
// 不驱动引脚，不解析 segment；复位按方向清空队列，订阅和等待者继续存活。
`uvm_analysis_imp_decl(_sample_tx)
`uvm_analysis_imp_decl(_sample_rx)
`uvm_analysis_imp_decl(_sample_reset_tx)
`uvm_analysis_imp_decl(_sample_reset_rx)

// 槽对象单独存在，使取消后的旧等待者仍引用旧槽，不会误取同编号新订阅的数据。
// hub 拥有有效槽；取消后最后一个等待者退出即可释放对象。
class eth_seg_subscription;
  eth_seg_seq_item frames[$];
  int unsigned depth;
  bit active = 1;
  process reader;

  // 深度由 hub 校验；构造不创建读取线程，不分配尚未收到的包。
  function new(int unsigned depth);
    this.depth = depth;
  endfunction
endclass

// 非参数化广播组件，速率只影响 Monitor 何时发布，采样层按整包维护 FIFO。
class eth_seg_monitor_hub extends uvm_component;
  `uvm_component_utils(eth_seg_monitor_hub)

  uvm_analysis_imp_sample_tx#(eth_seg_seq_item, eth_seg_monitor_hub) sample_tx;
  uvm_analysis_imp_sample_rx#(eth_seg_seq_item, eth_seg_monitor_hub) sample_rx;
  uvm_analysis_imp_sample_reset_tx#(bit, eth_seg_monitor_hub) reset_tx;
  uvm_analysis_imp_sample_reset_rx#(bit, eth_seg_monitor_hub) reset_rx;
  uvm_analysis_port#(eth_seg_reset_notice_t) reset_ap;

  protected eth_seg_subscription slots[2][int unsigned];
  protected bit reset_known[2], in_reset[2];
  protected int unsigned reset_epoch[2];

  // 创建 TLM 端口；未订阅时不分配报文缓存，复位消息按值传递。
  function new(string name = "monitor_hub", uvm_component parent = null);
    super.new(name, parent);
    sample_tx = new("sample_tx", this);
    sample_rx = new("sample_rx", this);
    reset_tx = new("reset_tx", this);
    reset_rx = new("reset_rx", this);
    reset_ap = new("reset_ap", this);
  endfunction

  // 防止非法枚举索引固定方向数组；fatal 被测试捕获时仍返回失败。
  protected function bit valid_dir(eth_seg_dir_e dir);
    if (!(dir inside {ETH_SEG_TX, ETH_SEG_RX})) begin
      `uvm_fatal("ETH_SAMPLE_CFG", "sampling direction must be TX or RX")
      return 0;
    end
    return 1;
  endfunction

  // 取已注册槽，缺失时报配置错误；不隐式订阅，不创建历史回放。
  protected function eth_seg_subscription get_slot(eth_seg_dir_e dir, int unsigned portid);
    if (!valid_dir(dir)) return null;
    if (!slots[dir].exists(portid)) begin
      `uvm_fatal("ETH_SAMPLE_SUB", $sformatf("unsubscribed %s consumer %0d", dir.name(), portid))
      return null;
    end
    return slots[dir][portid];
  endfunction

  // 注册独立消费者；重复注册和零容量报错，不改变原订阅及缓存。
  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    if (!valid_dir(dir)) return;
    if (depth == 0 || slots[dir].exists(portid)) begin
      `uvm_fatal("ETH_SAMPLE_CFG", "subscription requires positive depth and unused portid")
      return;
    end
    slots[dir][portid] = new(depth);
  endfunction

  // 取消会清空队列并唤醒旧等待者；重复取消无副作用，重订阅创建新对象。
  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_subscription slot;
    if (!valid_dir(dir)) return;
    if (!slots[dir].exists(portid)) return;
    slot = slots[dir][portid];
    slot.active = 0;
    slot.frames.delete();
    slots[dir].delete(portid);
  endfunction

  // 返回已缓存整包数；半包不进入 hub，非法订阅由 get_slot 明确诊断。
  function int unsigned pending(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_subscription slot = get_slot(dir, portid);
    return slot == null ? 0 : slot.frames.size();
  endfunction

  // 仅表明所有缓存为空；测试结束还需核对数量、driver/Monitor 及 RM 在途状态。
  function bit is_idle();
    foreach (slots[d,p]) if (slots[d][p].frames.size() != 0) return 0;
    return 1;
  endfunction

  // 获取一个完整帧。已有包立即返回；无包阻塞至入包、取消或非零 timeout 到期。
  // 复位清空队列但不重启 timeout。取消返回 null；超时返回 null 并报告 ERROR。
  // 读者进程死亡后允许新读者接管；同槽两个活跃读取者会报错，避免竞争消费。
  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    eth_seg_subscription slot;
    time started, remaining;
    tr = null;
    slot = get_slot(dir, portid);
    if (slot == null) return;
    if (slot.reader != null) begin
      if (!(slot.reader.status() inside {process::FINISHED, process::KILLED})) begin
        `uvm_fatal("ETH_SAMPLE_READER", "only one live reader is allowed per subscription")
        return;
      end
    end
    slot.reader = process::self();
    started = $time;
    forever begin
      if (!slot.active) begin
        slot.reader = null;
        return;
      end
      if (slot.frames.size() != 0) begin
        tr = slot.frames.pop_front();
        slot.reader = null;
        return;
      end
      if (timeout != 0 && $time-started >= timeout) begin
        slot.reader = null;
        `uvm_error("ETH_SAMPLE_TIMEOUT", $sformatf("no complete %s frame for consumer %0d within %0t", dir.name(), portid, timeout))
        return;
      end
      remaining = timeout == 0 ? 0 : timeout-($time-started);
      // 独立子进程限制 disable fork 的作用域，不能杀死调用者的其它线程。
      // 唤醒后重新检查：同一时刻复位可能已删除刚入队的包，必须继续等原截止时间。
      fork
        begin
          fork
            wait (!slot.active || slot.frames.size() != 0);
            begin
              if (timeout != 0) #(remaining);
              else wait (1'b0);
            end
          join_any
          disable fork;
        end
      join
    end
  endtask

  // 广播给已有订阅。先整体检查容量再复制，fatal 被捕获时也不产生部分广播。
  // 错误帧/aborted 保留元数据；没有订阅者时不保存任何历史对象。
  protected function void publish(eth_seg_dir_e dir, eth_seg_seq_item item);
    if (item == null) begin
      `uvm_fatal("ETH_SAMPLE_NULL", "monitor published a null frame")
      return;
    end
    if (reset_known[dir] && in_reset[dir]) return;
    foreach (slots[d,p]) if (d == int'(dir)) begin
      if (slots[dir][p].frames.size() >= slots[dir][p].depth) begin
        `uvm_fatal("ETH_SAMPLE_OVERFLOW", $sformatf("%s consumer %0d exceeded %0d frames", dir.name(), p, slots[dir][p].depth))
        return;
      end
    end
    foreach (slots[d,p]) if (d == int'(dir)) begin
      eth_seg_seq_item copy = eth_seg_seq_item::type_id::create("sample_copy");
      copy.copy(item);
      slots[dir][p].frames.push_back(copy);
    end
  endfunction

  // 接收 TX Monitor 的完整 EOP 事务，不读取 driver 的预取或完成队列。
  function void write_sample_tx(eth_seg_seq_item item);
    publish(ETH_SEG_TX, item);
  endfunction

  // 接收 RX Monitor 的完整 EOP 事务，保留所有错误边带。
  function void write_sample_rx(eth_seg_seq_item item);
    publish(ETH_SEG_RX, item);
  endfunction

  // 复位状态首次同步，后续只发布变化；先清理本方向缓存，再同步通知用户环境。
  // 通知按值传递 epoch；hub 不替用户清理已取出的包或预测线程。
  protected function void observe_reset(eth_seg_dir_e dir, bit asserted);
    eth_seg_reset_notice_t notice;
    if (reset_known[dir] && in_reset[dir] == asserted) return;
    reset_known[dir] = 1;
    in_reset[dir] = asserted;
    if (asserted) begin
      reset_epoch[dir]++;
      foreach (slots[d,p]) if (d == int'(dir)) slots[d][p].frames.delete();
    end
    notice.direction = dir;
    notice.asserted = asserted;
    notice.epoch = reset_epoch[dir];
    reset_ap.write(notice);
  endfunction

  // TX 复位来自 TX Monitor 的同一采样域，1 表示断言。
  function void write_sample_reset_tx(bit asserted);
    observe_reset(ETH_SEG_TX, asserted);
  endfunction

  // RX 复位只影响 RX 订阅；整链路清理策略由 RM/test 订阅 reset_ap 后决定。
  function void write_sample_reset_rx(bit asserted);
    observe_reset(ETH_SEG_RX, asserted);
  endfunction
endclass
