// 基础 smoke test：在同一仿真中驱动三个独立 RATE interface，覆盖连续与周期 ready/valid、
// FCS/preamble 组合和 400G 长帧。测试结束前等待固定窗口，物理完成仍以 monitor/scoreboard 诊断为准。
import uvm_pkg::*;
import eth_seg_pkg::*;
import eth_seg_types_pkg::*;
class eth_seg_smoke_test extends uvm_test;
  `uvm_component_utils(eth_seg_smoke_test)

  eth_seg_env#(100) env100;
  eth_seg_env#(200) env200;
  eth_seg_env#(400) env400;
  virtual eth_seg_if#(100) vif100;
  virtual eth_seg_if#(200) vif200;
  virtual eth_seg_if#(400) vif400;

  // 创建 smoke test；三个参数化 env 在 build_phase 中分别绑定 virtual interface。
  function new(string name = "eth_seg_smoke_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  // 为每个 RATE 建立一对 active role config；client 发送 TX，MAC 发送 RX 并生成 ready。
  function void build_phase(uvm_phase phase);
    eth_seg_config#(100) c100; eth_seg_config#(100) m100;
    eth_seg_config#(200) c200; eth_seg_config#(200) m200;
    eth_seg_config#(400) c400; eth_seg_config#(400) m400;
    super.build_phase(phase);
    if (!uvm_config_db#(virtual eth_seg_if#(100))::get(this, "", "vif100", vif100))
      `uvm_fatal("ETH_TB", "missing vif100")
    if (!uvm_config_db#(virtual eth_seg_if#(200))::get(this, "", "vif200", vif200))
      `uvm_fatal("ETH_TB", "missing vif200")
    if (!uvm_config_db#(virtual eth_seg_if#(400))::get(this, "", "vif400", vif400))
      `uvm_fatal("ETH_TB", "missing vif400")

    env100 = eth_seg_env#(100)::type_id::create("env100", this);
    env200 = eth_seg_env#(200)::type_id::create("env200", this);
    env400 = eth_seg_env#(400)::type_id::create("env400", this);
    c100 = eth_seg_config#(100)::type_id::create("client_cfg100"); m100 = eth_seg_config#(100)::type_id::create("mac_cfg100");
    c200 = eth_seg_config#(200)::type_id::create("client_cfg200"); m200 = eth_seg_config#(200)::type_id::create("mac_cfg200");
    c400 = eth_seg_config#(400)::type_id::create("client_cfg400"); m400 = eth_seg_config#(400)::type_id::create("mac_cfg400");
    c100.vif=vif100; m100.vif=vif100; c100.role=ETH_SEG_CLIENT; m100.role=ETH_SEG_MAC;
    c200.vif=vif200; m200.vif=vif200; c200.role=ETH_SEG_CLIENT; m200.role=ETH_SEG_MAC;
    c400.vif=vif400; m400.vif=vif400; c400.role=ETH_SEG_CLIENT; m400.role=ETH_SEG_MAC;
    c100.ready_pattern=ETH_SEG_CONTINUOUS; m100.ready_pattern=ETH_SEG_CONTINUOUS;
    c200.ready_pattern=ETH_SEG_PERIODIC; m200.ready_pattern=ETH_SEG_PERIODIC; c200.ready_high_cycles=4; c200.ready_low_cycles=3; m200.ready_high_cycles=4; m200.ready_low_cycles=3;
    m200.rx_valid_pattern=ETH_SEG_PERIODIC; m200.rx_valid_high_cycles=3; m200.rx_valid_low_cycles=1;
    c400.ready_pattern=ETH_SEG_RANDOM; m400.ready_pattern=ETH_SEG_RANDOM; m400.ready_high_pct=80; m400.ready_low_cycles=1;
    m400.rx_valid_pattern=ETH_SEG_RANDOM; m400.rx_valid_high_pct=75;
    c400.random_load=1; c400.traffic_load_pct=70; c400.load_min_pct=30; c400.load_max_pct=90;
    m400.random_load=1; m400.traffic_load_pct=65; m400.load_min_pct=25; m400.load_max_pct=85;
    c100.include_fcs=1; m100.include_fcs=1;
    c200.preamble_passthrough=1; m200.preamble_passthrough=1; c200.include_fcs=0; m200.include_fcs=0;
    c400.include_fcs=1; m400.include_fcs=1; c400.preamble_passthrough=1; m400.preamble_passthrough=1;
    env100.client_cfg=c100; env100.mac_cfg=m100;
    env200.client_cfg=c200; env200.mac_cfg=m200;
    env400.client_cfg=c400; env400.mac_cfg=m400;
  endfunction

  task run_phase(uvm_phase phase);
    eth_seg_frame_seq tx100, rx100, tx200, rx200, tx400, rx400;
    phase.raise_objection(this);
    tx100=eth_seg_frame_seq::type_id::create("tx100"); rx100=eth_seg_frame_seq::type_id::create("rx100");
    tx200=eth_seg_frame_seq::type_id::create("tx200"); rx200=eth_seg_frame_seq::type_id::create("rx200");
    tx400=eth_seg_frame_seq::type_id::create("tx400"); rx400=eth_seg_frame_seq::type_id::create("rx400");
    tx100.frame_count=4; rx100.frame_count=4; tx100.frame_length=64; rx100.frame_length=64; tx100.include_fcs=1; rx100.include_fcs=1;
    tx200.frame_count=4; rx200.frame_count=4; tx200.frame_length=128; rx200.frame_length=128;
    tx400.frame_count=3; rx400.frame_count=3; tx400.frame_length=2048; rx400.frame_length=2048; tx400.include_fcs=1; rx400.include_fcs=1;
    // 顶层复位由时钟线程释放；等待全部接口稳定后再把事务交给 driver，避免 reset 丢弃预取副本。
    wait (vif100.i_tx_rst_n && vif100.i_rx_rst_n &&
          vif200.i_tx_rst_n && vif200.i_rx_rst_n &&
          vif400.i_tx_rst_n && vif400.i_rx_rst_n);
    fork
      tx100.start(env100.client_agent.sequencer);
      rx100.start(env100.mac_agent.sequencer);
      tx200.start(env200.client_agent.sequencer);
      rx200.start(env200.mac_agent.sequencer);
      tx400.start(env400.client_agent.sequencer);
      rx400.start(env400.mac_agent.sequencer);
    join
    #2000;
    phase.drop_objection(this);
  endtask

  // 汇总每个速率的物理完成、monitor 重建和时序 coverage 计数；任何丢包或未覆盖
  // 的连续/间歇节奏都在 report_phase 变成 UVM_ERROR，不能只依赖仿真退出码。
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("ETH_SMOKE_COUNTS", $sformatf(
      "100G tx_match=%0d rx_match=%0d tx_seen=%0d rx_seen=%0d ready_low_max=%0d valid_rise=%0d valid_fall=%0d",
      env100.scoreboard.matched_tx, env100.scoreboard.matched_rx,
      env100.client_agent.tx_monitor.packets_seen, env100.client_agent.rx_monitor.packets_seen,
      env100.coverage.max_ready_low_run, env100.coverage.valid_rise, env100.coverage.valid_fall), UVM_LOW)
    `uvm_info("ETH_SMOKE_COUNTS", $sformatf(
      "200G tx_match=%0d rx_match=%0d tx_seen=%0d rx_seen=%0d ready_low_max=%0d valid_rise=%0d valid_fall=%0d",
      env200.scoreboard.matched_tx, env200.scoreboard.matched_rx,
      env200.client_agent.tx_monitor.packets_seen, env200.client_agent.rx_monitor.packets_seen,
      env200.coverage.max_ready_low_run, env200.coverage.valid_rise, env200.coverage.valid_fall), UVM_LOW)
    `uvm_info("ETH_SMOKE_COUNTS", $sformatf(
      "400G tx_match=%0d rx_match=%0d tx_seen=%0d rx_seen=%0d ready_low_max=%0d valid_rise=%0d valid_fall=%0d",
      env400.scoreboard.matched_tx, env400.scoreboard.matched_rx,
      env400.client_agent.tx_monitor.packets_seen, env400.client_agent.rx_monitor.packets_seen,
      env400.coverage.max_ready_low_run, env400.coverage.valid_rise, env400.coverage.valid_fall), UVM_LOW)
    if (env100.scoreboard.matched_tx != 4 || env100.scoreboard.matched_rx != 4 ||
        env100.client_agent.tx_monitor.packets_seen != 4 || env100.client_agent.rx_monitor.packets_seen != 4)
      `uvm_error("ETH_SMOKE_COUNT", "100G packet completion count mismatch")
    if (env200.scoreboard.matched_tx != 4 || env200.scoreboard.matched_rx != 4 ||
        env200.client_agent.tx_monitor.packets_seen != 4 || env200.client_agent.rx_monitor.packets_seen != 4)
      `uvm_error("ETH_SMOKE_COUNT", "200G packet completion count mismatch")
    if (env400.scoreboard.matched_tx != 3 || env400.scoreboard.matched_rx != 3 ||
        env400.client_agent.tx_monitor.packets_seen != 3 || env400.client_agent.rx_monitor.packets_seen != 3)
      `uvm_error("ETH_SMOKE_COUNT", "400G packet completion count mismatch")
    if (env100.coverage.continuous_cycles == 0 || env200.coverage.intermittent_cycles == 0 ||
        env400.coverage.ready_low_runs == 0 || env400.coverage.transactions_seen < 6)
      `uvm_error("ETH_SMOKE_COVERAGE", "continuous/intermittent/random timing coverage is incomplete")
  endfunction
endclass
