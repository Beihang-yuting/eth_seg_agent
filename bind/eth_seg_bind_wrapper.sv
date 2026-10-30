// bind 集成层：参照 module 内封装 interface + root agent 的用法，绑定已有 DUT net。
// 依赖 eth_seg_if、eth_seg_types_pkg、eth_seg_pkg 和 eth_seg_protocol_checker。
// wrapper 拥有 interface；agt 的生命周期由 UVM root 管理，cfg 由 wrapper 创建后共享。
// initial 内仅有零时间的同步创建；顶层 initial 先 #0，再调用唯一 run_test()。
// bind 只暴露名字和速率，行为配置保留 eth_seg_config 默认值，由用户在 build 前调整。
module eth_seg_bind_wrapper #(
  parameter int RATE = 100,
  parameter string AGENT_NAME = "",
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
  // agent 按 cfg.role / cfg.is_active 创建 driver，driver 领取所属方向的所有权。
  // 因此不再用静态 ROLE 参数二次门控，用户在 build 前改 cfg 也能正确选择方向。
  wire tx_enable = u_eth_if.tx_drive_enabled;
  wire rx_enable = u_eth_if.rx_drive_enabled;
  wire ready_enable = u_eth_if.ready_drive_enabled;

  // 固定采用图片中的 supply 接管方式；未领取的方向始终为 Z。
  generate
    begin : g_supply
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
    if (!cfg.validate(reason)) $fatal(1, "ETH_BIND_CFG: %s", reason);
    agt = eth_seg_agent#(RATE)::type_id::create(resolved_name, null);
    agt.cfg = cfg;
    // resource 字段名只用下划线，避免 UVM 把点号当作特殊字符发出 NOREGEX 警告。
    uvm_config_db#(eth_seg_agent#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_agent"}, agt);
    uvm_config_db#(eth_seg_config#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_cfg"}, cfg);
    uvm_config_db#(virtual eth_seg_if#(RATE))::set(null, "uvm_test_top*", {resolved_name, "_vif"}, u_eth_if);
  end

  // checker 读取绑定端口；开关来自默认 cfg，用户需在 reset/build 前设置，
  // 不支持在已有 ready 历史或在途报文中途开关检查器。
  // VCS 不允许连续赋值直接引用 class handle；各时钟负沿采样配置，供下一正沿使用。
  bit check_tx_enable = 0, check_rx_enable = 0;
  always @(negedge i_clk_tx)
    check_tx_enable <= (cfg != null) ? cfg.enable_protocol_check : 1'b0;
  always @(negedge i_clk_rx)
    check_rx_enable <= (cfg != null) ? cfg.enable_protocol_check : 1'b0;
  generate
    begin : g_check
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
        .enable_tx(check_tx_enable), .enable_rx(check_rx_enable)
      );
    end
  endgenerate
endmodule
