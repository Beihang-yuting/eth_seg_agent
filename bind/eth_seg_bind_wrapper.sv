// bind 集成层：参照 module 内封装 interface + root agent 的用法，绑定已有 DUT net。
// 依赖 eth_seg_if、eth_seg_types_pkg、eth_seg_pkg 和 eth_seg_protocol_checker。
// wrapper 拥有 interface；agt 的生命周期由 UVM root 管理，cfg 由 wrapper 创建后共享。
// 顶层必须等待所有 wrapper.initialized 再调用唯一的 run_test()，避免 time-0 构建竞态。
module eth_seg_bind_wrapper #(
  parameter int RATE = 100,
  parameter string AGENT_NAME = "",
  parameter eth_seg_types_pkg::eth_seg_role_e ROLE = eth_seg_types_pkg::ETH_SEG_CLIENT,
  parameter uvm_pkg::uvm_active_passive_enum ACTIVE_MODE = uvm_pkg::UVM_ACTIVE,
  parameter bit PREAMBLE_PASSTHROUGH = 0,
  parameter bit INCLUDE_FCS = 0,
  // 与图片相同，默认用 supply 强度接管已有 strong net 驱动；0 则用普通 strong 驱动。
  parameter bit OVERRIDE_DUT = 1,
  parameter bit ENABLE_CHECKER = 1,
  parameter eth_seg_types_pkg::eth_seg_pattern_e READY_PATTERN = eth_seg_types_pkg::ETH_SEG_CONTINUOUS,
  parameter int READY_HIGH_CYCLES = 8,
  parameter int READY_LOW_CYCLES = 2,
  parameter int READY_HIGH_PCT = 70,
  parameter eth_seg_types_pkg::eth_seg_pattern_e RX_VALID_PATTERN = eth_seg_types_pkg::ETH_SEG_CONTINUOUS,
  parameter int RX_VALID_HIGH_CYCLES = 8,
  parameter int RX_VALID_LOW_CYCLES = 2,
  parameter int RX_VALID_HIGH_PCT = 70,
  parameter int TRAFFIC_LOAD_PCT = 100,
  parameter bit RANDOM_LOAD = 0,
  parameter int LOAD_MIN_PCT = 10,
  parameter int LOAD_MAX_PCT = 100,
  parameter int MAX_PENDING = 64,
  localparam int NUM_SEGMENTS = RATE / 25,
  localparam int DATA_WIDTH = NUM_SEGMENTS * 64
) (
  input wire i_clk_tx,
  input wire i_clk_rx,
  input wire i_tx_rst_n,
  input wire i_rx_rst_n,

  // 同一 wrapper 支持 CLIENT / MAC / passive，因此信号用解析型 inout net。
  // 名称仍按 MAC 视角：CLIENT 驱动 i_tx_*；MAC 驱动 o_tx_ready 与 o_rx_*。
  inout wire [DATA_WIDTH-1:0] i_tx_mac_data,
  inout wire i_tx_mac_valid,
  inout wire [NUM_SEGMENTS-1:0] i_tx_mac_inframe,
  inout wire [NUM_SEGMENTS*3-1:0] i_tx_mac_eop_empty,
  inout wire [NUM_SEGMENTS-1:0] i_tx_mac_error,
  inout wire [NUM_SEGMENTS-1:0] i_tx_mac_skip_crc,
  inout wire o_tx_mac_ready,

  inout wire [DATA_WIDTH-1:0] o_rx_mac_data,
  inout wire o_rx_mac_valid,
  inout wire [NUM_SEGMENTS-1:0] o_rx_mac_inframe,
  inout wire [NUM_SEGMENTS*3-1:0] o_rx_mac_eop_empty,
  inout wire [NUM_SEGMENTS-1:0] o_rx_mac_fcs_error,
  inout wire [NUM_SEGMENTS*2-1:0] o_rx_mac_error,
  inout wire [NUM_SEGMENTS*3-1:0] o_rx_mac_status_data
);
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;

  eth_seg_if #(RATE) u_eth_if(i_clk_tx, i_clk_rx, i_tx_rst_n, i_rx_rst_n);
  eth_seg_agent#(RATE) agt;
  eth_seg_config#(RATE) cfg;
  string resolved_name;
  bit initialized = 0;

  // 公共网络只用于读取实际 DUT 引脚；输出必须来自 drv_*，避免 assign 环路。
  // interface 内部还存在 strong 代理驱动，supply 回读保证 monitor 看见外部解析结果，
  // 包括冲突的 X，而不是只看见 agent 的驱动意图。这里的强度不反向驱动 DUT。
  assign (supply1, supply0) u_eth_if.i_tx_mac_data = i_tx_mac_data;
  assign (supply1, supply0) u_eth_if.i_tx_mac_valid = i_tx_mac_valid;
  assign (supply1, supply0) u_eth_if.i_tx_mac_inframe = i_tx_mac_inframe;
  assign (supply1, supply0) u_eth_if.i_tx_mac_eop_empty = i_tx_mac_eop_empty;
  assign (supply1, supply0) u_eth_if.i_tx_mac_error = i_tx_mac_error;
  assign (supply1, supply0) u_eth_if.i_tx_mac_skip_crc = i_tx_mac_skip_crc;
  assign (supply1, supply0) u_eth_if.o_tx_mac_ready = o_tx_mac_ready;
  assign (supply1, supply0) u_eth_if.o_rx_mac_data = o_rx_mac_data;
  assign (supply1, supply0) u_eth_if.o_rx_mac_valid = o_rx_mac_valid;
  assign (supply1, supply0) u_eth_if.o_rx_mac_inframe = o_rx_mac_inframe;
  assign (supply1, supply0) u_eth_if.o_rx_mac_eop_empty = o_rx_mac_eop_empty;
  assign (supply1, supply0) u_eth_if.o_rx_mac_fcs_error = o_rx_mac_fcs_error;
  assign (supply1, supply0) u_eth_if.o_rx_mac_error = o_rx_mac_error;
  assign (supply1, supply0) u_eth_if.o_rx_mac_status_data = o_rx_mac_status_data;

  // 领取驱动权后一直驱动，包含 reset 和 valid=0；不能用 valid 做高阻门控，
  // 否则 TX invalid hold 和两拍 ready 响应会被被接管的原驱动破坏。
  wire tx_enable = (ACTIVE_MODE == UVM_ACTIVE && ROLE == ETH_SEG_CLIENT) && u_eth_if.tx_drive_enabled;
  wire rx_enable = (ACTIVE_MODE == UVM_ACTIVE && ROLE == ETH_SEG_MAC) && u_eth_if.rx_drive_enabled;
  wire ready_enable = (ACTIVE_MODE == UVM_ACTIVE && ROLE == ETH_SEG_MAC) && u_eth_if.ready_drive_enabled;

  generate
    if (OVERRIDE_DUT) begin : g_supply
      assign (supply1, supply0) i_tx_mac_data = tx_enable ? u_eth_if.drv_tx_data : 'z;
      assign (supply1, supply0) i_tx_mac_valid = tx_enable ? u_eth_if.drv_tx_valid : 'z;
      assign (supply1, supply0) i_tx_mac_inframe = tx_enable ? u_eth_if.drv_tx_inframe : 'z;
      assign (supply1, supply0) i_tx_mac_eop_empty = tx_enable ? u_eth_if.drv_tx_eop_empty : 'z;
      assign (supply1, supply0) i_tx_mac_error = tx_enable ? u_eth_if.drv_tx_error : 'z;
      assign (supply1, supply0) i_tx_mac_skip_crc = tx_enable ? u_eth_if.drv_tx_skip_crc : 'z;
      assign (supply1, supply0) o_tx_mac_ready = ready_enable ? u_eth_if.drv_ready : 'z;
      assign (supply1, supply0) o_rx_mac_data = rx_enable ? u_eth_if.drv_rx_data : 'z;
      assign (supply1, supply0) o_rx_mac_valid = rx_enable ? u_eth_if.drv_rx_valid : 'z;
      assign (supply1, supply0) o_rx_mac_inframe = rx_enable ? u_eth_if.drv_rx_inframe : 'z;
      assign (supply1, supply0) o_rx_mac_eop_empty = rx_enable ? u_eth_if.drv_rx_eop_empty : 'z;
      assign (supply1, supply0) o_rx_mac_fcs_error = rx_enable ? u_eth_if.drv_rx_fcs_error : 'z;
      assign (supply1, supply0) o_rx_mac_error = rx_enable ? u_eth_if.drv_rx_error : 'z;
      assign (supply1, supply0) o_rx_mac_status_data = rx_enable ? u_eth_if.drv_rx_status_data : 'z;
    end
    else begin : g_strong
      assign i_tx_mac_data = tx_enable ? u_eth_if.drv_tx_data : 'z;
      assign i_tx_mac_valid = tx_enable ? u_eth_if.drv_tx_valid : 'z;
      assign i_tx_mac_inframe = tx_enable ? u_eth_if.drv_tx_inframe : 'z;
      assign i_tx_mac_eop_empty = tx_enable ? u_eth_if.drv_tx_eop_empty : 'z;
      assign i_tx_mac_error = tx_enable ? u_eth_if.drv_tx_error : 'z;
      assign i_tx_mac_skip_crc = tx_enable ? u_eth_if.drv_tx_skip_crc : 'z;
      assign o_tx_mac_ready = ready_enable ? u_eth_if.drv_ready : 'z;
      assign o_rx_mac_data = rx_enable ? u_eth_if.drv_rx_data : 'z;
      assign o_rx_mac_valid = rx_enable ? u_eth_if.drv_rx_valid : 'z;
      assign o_rx_mac_inframe = rx_enable ? u_eth_if.drv_rx_inframe : 'z;
      assign o_rx_mac_eop_empty = rx_enable ? u_eth_if.drv_rx_eop_empty : 'z;
      assign o_rx_mac_fcs_error = rx_enable ? u_eth_if.drv_rx_fcs_error : 'z;
      assign o_rx_mac_error = rx_enable ? u_eth_if.drv_rx_error : 'z;
      assign o_rx_mac_status_data = rx_enable ? u_eth_if.drv_rx_status_data : 'z;
    end
  endgenerate

  // 默认命名来自绑定层次，转换成合法 UVM 子组件名；显式名称必须全仿真唯一。
  // 创建在 time-0 完成，禁止在 wrapper 中 run_test 或再次在 env 内创建同名 agent。
  initial begin : create_agent
    uvm_root root;
    string reason;
    root = uvm_root::get();
    resolved_name = AGENT_NAME;
    if (resolved_name == "") begin
      resolved_name = $sformatf("%m");
      for (int i = 0; i < resolved_name.len(); i++)
        if (!(resolved_name.getc(i) inside {["a":"z"], ["A":"Z"], ["0":"9"], "_"}))
          resolved_name.putc(i, "_");
    end
    else begin
      for (int i = 0; i < resolved_name.len(); i++)
        if (!(resolved_name.getc(i) inside {["a":"z"], ["A":"Z"], ["0":"9"], "_"}))
          $fatal(1, "ETH_BIND_NAME: AGENT_NAME must contain only letters, digits and underscore");
    end
    if (root.has_child(resolved_name))
      $fatal(1, "ETH_BIND_NAME: duplicate root agent %s", resolved_name);
    cfg = eth_seg_config#(RATE)::type_id::create({resolved_name, "_cfg"});
    cfg.vif = u_eth_if;
    cfg.role = ROLE;
    cfg.is_active = ACTIVE_MODE;
    cfg.preamble_passthrough = PREAMBLE_PASSTHROUGH;
    cfg.include_fcs = INCLUDE_FCS;
    cfg.enable_protocol_check = ENABLE_CHECKER;
    cfg.ready_pattern = READY_PATTERN;
    cfg.ready_high_cycles = READY_HIGH_CYCLES;
    cfg.ready_low_cycles = READY_LOW_CYCLES;
    cfg.ready_high_pct = READY_HIGH_PCT;
    cfg.rx_valid_pattern = RX_VALID_PATTERN;
    cfg.rx_valid_high_cycles = RX_VALID_HIGH_CYCLES;
    cfg.rx_valid_low_cycles = RX_VALID_LOW_CYCLES;
    cfg.rx_valid_high_pct = RX_VALID_HIGH_PCT;
    cfg.traffic_load_pct = TRAFFIC_LOAD_PCT;
    cfg.random_load = RANDOM_LOAD;
    cfg.load_min_pct = LOAD_MIN_PCT;
    cfg.load_max_pct = LOAD_MAX_PCT;
    cfg.max_pending = MAX_PENDING;
    if (!cfg.validate(reason)) $fatal(1, "ETH_BIND_CFG: %s", reason);
    agt = eth_seg_agent#(RATE)::type_id::create(resolved_name, null);
    agt.cfg = cfg;
    // resource 字段名只用下划线，避免 UVM 把点号当作特殊字符发出 NOREGEX 警告。
    uvm_config_db#(eth_seg_agent#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_agent"}, agt);
    uvm_config_db#(eth_seg_config#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_cfg"}, cfg);
    uvm_config_db#(virtual eth_seg_if#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_vif"}, u_eth_if);
    initialized = 1;
  end

  // checker 读取绑定端口，而非内部驱动值；reset 边界与 DUT 使用相同的两个时钟。
  generate
    if (ENABLE_CHECKER) begin : g_check
      eth_seg_protocol_checker #(.RATE(RATE)) protocol_check (
        .i_clk_tx(i_clk_tx), .i_clk_rx(i_clk_rx),
        .i_tx_rst_n(i_tx_rst_n), .i_rx_rst_n(i_rx_rst_n),
        .i_tx_mac_data(i_tx_mac_data), .i_tx_mac_valid(i_tx_mac_valid),
        .i_tx_mac_inframe(i_tx_mac_inframe), .i_tx_mac_eop_empty(i_tx_mac_eop_empty),
        .i_tx_mac_error(i_tx_mac_error), .i_tx_mac_skip_crc(i_tx_mac_skip_crc),
        .o_tx_mac_ready(o_tx_mac_ready), .o_rx_mac_data(o_rx_mac_data),
        .o_rx_mac_valid(o_rx_mac_valid), .o_rx_mac_inframe(o_rx_mac_inframe),
        .o_rx_mac_eop_empty(o_rx_mac_eop_empty), .o_rx_mac_fcs_error(o_rx_mac_fcs_error),
        .o_rx_mac_error(o_rx_mac_error), .o_rx_mac_status_data(o_rx_mac_status_data),
        .enable_tx(1'b1), .enable_rx(1'b1)
      );
    end
  endgenerate
endmodule
