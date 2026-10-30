// src sequence 仲裁层：非参数化 sequencer 只处理字节事务，与接口带宽完全解耦。
// agent 创建并拥有本组件；driver 的 item_done 仅表示副本入队，物理完成以 sent_ap 为准。
// 静态 sqr 表仅借用句柄，按完整 agent 名称区分实例；100/200/400G 共用一张表。
class eth_seg_sequencer extends uvm_sequencer #(eth_seg_seq_item);
  `uvm_component_utils(eth_seg_sequencer)

  static eth_seg_sequencer sqr[string];

  // 建立标准 UVM sequencer，仲裁和 sequence 生命周期由 UVM 基类维护。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 在 agent.connect_phase 完成 driver 连接后登记；重复名字或空句柄立即失败。
  // 本表不创建 sequencer，禁止用一个静态单句柄覆盖多个 IP 的独立仲裁器。
  static function void register_sqr(string agent_name, eth_seg_sequencer handle);
    if (agent_name == "" || handle == null)
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", "agent name and sequencer must be non-null");
    if (sqr.exists(agent_name))
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", {"duplicate sequencer: ", agent_name});
    sqr[agent_name] = handle;
  endfunction

  // Tcl 命令或用户 sequence 查询入口；未完成 connect、名字错误或 passive 返回 null。
  // 查询不创建新表项，调用者须在启动需要 driver 的 sequence 前检查非空。
  static function eth_seg_sequencer get_sqr(string agent_name);
    if (!sqr.exists(agent_name)) return null;
    return sqr[agent_name];
  endfunction

  // 仿真 final 时撤销本 agent 的借用句柄；仅删除仍指向原对象的表项。
  static function void unregister_sqr(string agent_name, eth_seg_sequencer handle);
    if (sqr.exists(agent_name))
      if (sqr[agent_name] == handle) sqr.delete(agent_name);
  endfunction
endclass
