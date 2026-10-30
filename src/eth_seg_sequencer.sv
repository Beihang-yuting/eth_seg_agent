// src sequence 仲裁层：非参数化 sequencer 只处理字节事务，与接口带宽完全解耦。
// agent 创建并拥有本组件；driver 的 item_done 仅表示副本入队，物理完成以 sent_ap 为准。
// 静态 sqr 表仅借用句柄，按完整 agent 名称区分实例；100/200/400G 共用一张表。
// active/passive 均存在；monitor_hub 在 build 关联，can_send 在 connect 完成后发布。
class eth_seg_sequencer extends uvm_sequencer #(eth_seg_seq_item);
  `uvm_component_utils(eth_seg_sequencer)

  static eth_seg_sequencer sqr[string];
  eth_seg_monitor_hub monitor_hub;
  bit can_send = 0;

  // 建立标准 UVM sequencer，仲裁和 sequence 生命周期由 UVM 基类维护。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 在 agent.connect_phase 完成 driver 连接后登记；重复名字或空句柄立即失败。
  // 本表不创建 sequencer，禁止用一个静态单句柄覆盖多个 IP 的独立仲裁器。
  static function void register_sqr(string agent_name, eth_seg_sequencer handle);
    if (agent_name == "" || handle == null) begin
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", "agent name and sequencer must be non-null");
      return;
    end
    if (sqr.exists(agent_name)) begin
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", {"duplicate sequencer: ", agent_name});
      return;
    end
    sqr[agent_name] = handle;
  endfunction

  // Tcl/采样查询入口；未完成 connect 或名字错误返回 null，passive 返回仅供采样的 sqr。
  // 查询不创建新表项；发送 sequence 还需检查 can_send，避免等待不存在的 driver。
  static function eth_seg_sequencer get_sqr(string agent_name);
    if (!sqr.exists(agent_name)) return null;
    return sqr[agent_name];
  endfunction

  // 仿真 final 时撤销本 agent 的借用句柄；仅删除仍指向原对象的表项。
  static function void unregister_sqr(string agent_name, eth_seg_sequencer handle);
    if (sqr.exists(agent_name))
      if (sqr[agent_name] == handle) sqr.delete(agent_name);
  endfunction

  // 检查 agent 是否关联采样组件；独立手工构建 sequencer 时也必须显式提供 hub。
  protected function bit require_hub();
    if (monitor_hub == null) begin
      `uvm_fatal("ETH_SAMPLE_HUB", "sequencer has no monitor hub")
      return 0;
    end
    return 1;
  endfunction

  // 按方向登记订阅，portid 区分消费者；缓存归 agent，不归 sequence。
  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    if (require_hub()) monitor_hub.subscribe(dir, portid, depth);
  endfunction

  // 阻塞获取完整 EOP 事务；超时或取消返回 null，详细行为由 hub 统一实现。
  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    tr = null;
    if (require_hub()) monitor_hub.mon_xaction(tr, dir, portid, timeout);
  endtask

  // 撤销订阅并唤醒对应等待者；不影响其它方向或其它消费编号。
  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    if (require_hub()) monitor_hub.unsubscribe(dir, portid);
  endfunction
endclass
