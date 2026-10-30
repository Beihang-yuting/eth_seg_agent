// Environment 层：创建 CLIENT 与 MAC 两个 agent，并将期望/实际分析端口接入 scoreboard。
// 两个 cfg 可分别指向独立 interface，或在 pin-level 自检中按需共享同一 interface；所有
// monitor 均保留，因此 passive/DUT 拓扑无需修改 env 结构即可复用。
// coverage 原类按合同提供 write()，这里用轻量 analysis sink 适配 UVM analysis_port。
class eth_seg_cov_sink #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_cov_sink#(RATE))
  uvm_analysis_imp#(eth_seg_seq_item, eth_seg_cov_sink#(RATE)) analysis_export;
  eth_seg_coverage#(RATE) target;
  // 创建 coverage 分析汇聚器；目标 coverage 由 env 在 build_phase 注入。
  function new(string name, uvm_component parent);
    super.new(name, parent);
    analysis_export = new("analysis_export", this);
  endfunction
  function void write(eth_seg_seq_item item);
    if (target != null) target.write(item);
  endfunction
endclass

class eth_seg_env #(int RATE = 100) extends uvm_env;
  `uvm_component_param_utils(eth_seg_env#(RATE))

  eth_seg_config#(RATE) client_cfg;
  eth_seg_config#(RATE) mac_cfg;
  bit enable_scoreboard = 1;
  bit enable_coverage = 1;
  eth_seg_agent#(RATE) client_agent;
  eth_seg_agent#(RATE) mac_agent;
  eth_seg_scoreboard scoreboard;
  eth_seg_coverage#(RATE) coverage;
  eth_seg_cov_sink#(RATE) coverage_sink;

  // 创建 env；client/mac 配置由父 test 在 build_phase 前填写。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 建立两个角色 agent；父 test 可在 build_phase 前直接填写 client_cfg/mac_cfg。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (client_cfg == null)
      client_cfg = eth_seg_config#(RATE)::type_id::create("client_cfg");
    if (mac_cfg == null)
      mac_cfg = eth_seg_config#(RATE)::type_id::create("mac_cfg");
    client_agent = eth_seg_agent#(RATE)::type_id::create("client_agent", this);
    mac_agent = eth_seg_agent#(RATE)::type_id::create("mac_agent", this);
    client_agent.cfg = client_cfg;
    mac_agent.cfg = mac_cfg;
    uvm_config_db#(eth_seg_config#(RATE))::set(this, "client_agent", "cfg", client_cfg);
    uvm_config_db#(eth_seg_config#(RATE))::set(this, "mac_agent", "cfg", mac_cfg);
    if (enable_scoreboard)
      scoreboard = eth_seg_scoreboard::type_id::create("scoreboard", this);
    if (enable_coverage) begin
      coverage = eth_seg_coverage#(RATE)::type_id::create("coverage", this);
      coverage.cfg = client_cfg;
      coverage_sink = eth_seg_cov_sink#(RATE)::type_id::create("coverage_sink", this);
      coverage_sink.target = coverage;
    end
  endfunction

  // TX 方向期望来自 active CLIENT driver，实际来自 CLIENT TX monitor；RX 同理由 MAC
  // active driver 与 CLIENT RX monitor 组成。若角色被设为 passive，连接仍安全地省略空端口。
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (enable_scoreboard && scoreboard != null) begin
      if (client_agent.tx_driver != null)
        client_agent.tx_driver.sent_ap.connect(scoreboard.expect_tx);
      if (client_agent.tx_monitor != null)
        client_agent.tx_monitor.item_collected_port.connect(scoreboard.actual_tx);
      if (mac_agent.rx_driver != null)
        mac_agent.rx_driver.sent_ap.connect(scoreboard.expect_rx);
      if (client_agent.rx_monitor != null)
        client_agent.rx_monitor.item_collected_port.connect(scoreboard.actual_rx);
    end
    if (enable_coverage && coverage != null) begin
      coverage.cfg = client_cfg;
      if (client_agent.tx_monitor != null)
        client_agent.tx_monitor.item_collected_port.connect(coverage_sink.analysis_export);
      if (client_agent.rx_monitor != null)
        client_agent.rx_monitor.item_collected_port.connect(coverage_sink.analysis_export);
    end
  endfunction
endclass
