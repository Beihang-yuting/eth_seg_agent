// test/bind HDL 验证层：提供只有解析 net 的目标壳，通过模块类型 bind 注入三个 wrapper。
// 目标壳拥有原始 strong 驱动；wrapper 拥有 interface，UVM root 拥有 agent。
// 四个 IP 覆盖三种速率；验证 supply 接管、默认 cfg 和 #0 启动，均使用真实 bind。
`timescale 1ns/1ps
module eth_seg_bind_target #(
  parameter int RATE = 100,
  parameter string PORT_NAME = "case100",
  parameter bit OVERRIDE = 1,
  localparam int NUM_SEGMENTS = RATE/25,
  localparam int DATA_WIDTH = NUM_SEGMENTS*64
) (
  input wire i_clk_tx, i_clk_rx, i_tx_rst_n, i_rx_rst_n
);
  wire [DATA_WIDTH-1:0] i_tx_mac_data;
  wire i_tx_mac_valid;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_inframe;
  wire [NUM_SEGMENTS*3-1:0] i_tx_mac_eop_empty;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_error;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_skip_crc;
  wire o_tx_mac_ready;
  wire [DATA_WIDTH-1:0] o_rx_mac_data;
  wire o_rx_mac_valid;
  wire [NUM_SEGMENTS-1:0] o_rx_mac_inframe;
  wire [NUM_SEGMENTS*3-1:0] o_rx_mac_eop_empty;
  wire [NUM_SEGMENTS-1:0] o_rx_mac_fcs_error;
  wire [NUM_SEGMENTS*2-1:0] o_rx_mac_error;
  wire [NUM_SEGMENTS*3-1:0] o_rx_mac_status_data;

  // 原驱动故意保持全 1，与 agent 的空闲值和数据相冲突，供 supply 接管验证。
  // 关闭 OVERRIDE 时原驱动为 Z，wrapper 成为该方向的唯一驱动。
  assign i_tx_mac_data = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_valid = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_inframe = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_eop_empty = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_error = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_skip_crc = OVERRIDE ? '1 : 'z;
  assign o_tx_mac_ready = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_data = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_valid = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_inframe = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_eop_empty = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_fcs_error = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_error = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_status_data = OVERRIDE ? '1 : 'z;

  // 比较的是实际解析后的全部引脚和每个 wrapper 的公开 interface，包含 invalid 拍。
  // 任一字段漏连/错位、passive 反向驱动或原 strong 驱动未被接管都会在这里暴露。
  localparam int VIEW_WIDTH = 2*DATA_WIDTH + 16*NUM_SEGMENTS + 3;
  wire [VIEW_WIDTH-1:0] pins_view = {
    i_tx_mac_data,
    i_tx_mac_valid,
    i_tx_mac_inframe,
    i_tx_mac_eop_empty,
    i_tx_mac_error,
    i_tx_mac_skip_crc,
    o_tx_mac_ready,
    o_rx_mac_data,
    o_rx_mac_valid,
    o_rx_mac_inframe,
    o_rx_mac_eop_empty,
    o_rx_mac_fcs_error,
    o_rx_mac_error,
    o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] client_view = {
    u_client.u_eth_if.i_tx_mac_data,
    u_client.u_eth_if.i_tx_mac_valid,
    u_client.u_eth_if.i_tx_mac_inframe,
    u_client.u_eth_if.i_tx_mac_eop_empty,
    u_client.u_eth_if.i_tx_mac_error,
    u_client.u_eth_if.i_tx_mac_skip_crc,
    u_client.u_eth_if.o_tx_mac_ready,
    u_client.u_eth_if.o_rx_mac_data,
    u_client.u_eth_if.o_rx_mac_valid,
    u_client.u_eth_if.o_rx_mac_inframe,
    u_client.u_eth_if.o_rx_mac_eop_empty,
    u_client.u_eth_if.o_rx_mac_fcs_error,
    u_client.u_eth_if.o_rx_mac_error,
    u_client.u_eth_if.o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] mac_view = {
    u_mac.u_eth_if.i_tx_mac_data,
    u_mac.u_eth_if.i_tx_mac_valid,
    u_mac.u_eth_if.i_tx_mac_inframe,
    u_mac.u_eth_if.i_tx_mac_eop_empty,
    u_mac.u_eth_if.i_tx_mac_error,
    u_mac.u_eth_if.i_tx_mac_skip_crc,
    u_mac.u_eth_if.o_tx_mac_ready,
    u_mac.u_eth_if.o_rx_mac_data,
    u_mac.u_eth_if.o_rx_mac_valid,
    u_mac.u_eth_if.o_rx_mac_inframe,
    u_mac.u_eth_if.o_rx_mac_eop_empty,
    u_mac.u_eth_if.o_rx_mac_fcs_error,
    u_mac.u_eth_if.o_rx_mac_error,
    u_mac.u_eth_if.o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] observer_view = {
    u_observer.u_eth_if.i_tx_mac_data,
    u_observer.u_eth_if.i_tx_mac_valid,
    u_observer.u_eth_if.i_tx_mac_inframe,
    u_observer.u_eth_if.i_tx_mac_eop_empty,
    u_observer.u_eth_if.i_tx_mac_error,
    u_observer.u_eth_if.i_tx_mac_skip_crc,
    u_observer.u_eth_if.o_tx_mac_ready,
    u_observer.u_eth_if.o_rx_mac_data,
    u_observer.u_eth_if.o_rx_mac_valid,
    u_observer.u_eth_if.o_rx_mac_inframe,
    u_observer.u_eth_if.o_rx_mac_eop_empty,
    u_observer.u_eth_if.o_rx_mac_fcs_error,
    u_observer.u_eth_if.o_rx_mac_error,
    u_observer.u_eth_if.o_rx_mac_status_data
  };
  int pin_checks = 0;

  // 延后一个精度单位检查，避开同一时刻其他时钟负沿的 NBA/continuous assign 收敛。
  // reset 内允许 time-0 尚未领取驱动权，reset 外则每拍都必须完全已知且正确读回。
  always @(posedge i_clk_tx) begin
    if (i_tx_rst_n && i_rx_rst_n) begin
      #1ps;
      if ($isunknown(pins_view) || pins_view !== client_view ||
          pins_view !== mac_view || pins_view !== observer_view)
        $fatal(1, "ETH_BIND_PIN_READBACK: RATE=%0d resolved pins differ from interface", RATE);
      pin_checks++;
    end
  end
endmodule

// bind 仅传 RATE 和名字；cfg 使用默认值，测试在 #0 后、run_test 前自行调整。
// 同一 module 类型的四个实例都会绑定；observer 留空测试层次自动命名。
bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_client"})
) u_client (.*);

bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_mac"})
) u_mac (.*);

bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE)
) u_observer (.*);

// 顶层只生成时钟/复位并协调 time-0；不能在任何 wrapper 内各自调用 run_test。
module tb_bind;
  import uvm_pkg::*;
  import eth_seg_bind_test_pkg::*;
  logic clk_tx = 0, clk_rx = 0, rst_n = 0;

  always #2ns clk_tx = ~clk_tx;
  always #3ns clk_rx = ~clk_rx;

  eth_seg_bind_target #(.RATE(100), .PORT_NAME("case100"), .OVERRIDE(1)) link100
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(200), .PORT_NAME("case200"), .OVERRIDE(0)) link200
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(400), .PORT_NAME("case400"), .OVERRIDE(1)) link400
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(100), .PORT_NAME("case100b"), .OVERRIDE(1)) link100b
    (clk_tx, clk_rx, rst_n, rst_n);

  // 41 ns 避开两种时钟的正负沿，给所有 root driver 留出多个完整复位周期。
  initial #41ns rst_n = 1;

  initial begin
    // 所有 wrapper 在 Active 区同步创建 cfg/agent；#0 进入 Inactive 区再取句柄。
    // 此处还没有 sequencer，后续 run_test 的 build/connect 才会创建并注册它。
    #0;
    bind_rate_case#(100)::configure(link100.u_client.cfg, link100.u_mac.cfg, link100.u_observer.cfg);
    bind_rate_case#(200)::configure(link200.u_client.cfg, link200.u_mac.cfg, link200.u_observer.cfg);
    bind_rate_case#(400)::configure(link400.u_client.cfg, link400.u_mac.cfg, link400.u_observer.cfg);
    bind_rate_case#(100)::configure(link100b.u_client.cfg, link100b.u_mac.cfg, link100b.u_observer.cfg);
    uvm_config_db#(string)::set(null, "uvm_test_top.case100", "observer_name", link100.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case200", "observer_name", link200.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case400", "observer_name", link400.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case100b", "observer_name", link100b.u_observer.resolved_name);
    run_test("eth_seg_bind_test");
  end

  // 独立 HDL watchdog 也覆盖 run_test 前的初始化卡死；正常 UVM finish 会提前结束仿真。
  initial begin
    #25us;
    $fatal(1, "ETH_BIND_STARTUP_TIMEOUT: test did not finish");
  end
endmodule
