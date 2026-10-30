// test/aip HDL 层：四个 MAC 响应壳提供 ready/RX idle，CLIENT agent 由 bind 自动创建。
// 依赖 eth_seg_bind_wrapper 与 eth_seg_aip_test_pkg；顶层拥有时钟/复位，不创建 env。
// 100/200/400/100 四个实例证明静态 sqr 按名字区分，非按 RATE 共用一个句柄。
`timescale 1ns/1ps
module eth_seg_aip_target #(
  parameter int RATE = 100,
  parameter string PORT_NAME = "eth0",
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

  // 只模拟持续可接收的 MAC 引脚行为，不包含真实 MAC RTL。
  assign o_tx_mac_ready = i_tx_rst_n;
  assign o_rx_mac_data = '0;
  assign o_rx_mac_valid = '0;
  assign o_rx_mac_inframe = '0;
  assign o_rx_mac_eop_empty = '0;
  assign o_rx_mac_fcs_error = '0;
  assign o_rx_mac_error = '0;
  assign o_rx_mac_status_data = '0;
endmodule

bind eth_seg_aip_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME(PORT_NAME)
) u_eth_bind (.*);

// #0 只保证同步 initial 创建完成；run_test 的 build/connect 会继续创建并登记 sqr。
module tb_aip;
  import uvm_pkg::*;
  import eth_seg_aip_test_pkg::*;
  logic clk = 0, rst_n = 0;
  always #2ns clk = ~clk;
  initial #41ns rst_n = 1;

  eth_seg_aip_target #(.RATE(100), .PORT_NAME("eth0")) ip0(clk, clk, rst_n, rst_n);
  eth_seg_aip_target #(.RATE(200), .PORT_NAME("eth1")) ip1(clk, clk, rst_n, rst_n);
  eth_seg_aip_target #(.RATE(400), .PORT_NAME("eth2")) ip2(clk, clk, rst_n, rst_n);
  eth_seg_aip_target #(.RATE(100), .PORT_NAME("eth3")) ip3(clk, clk, rst_n, rst_n);

  initial begin
    #0;
    run_test("eth_seg_aip_test");
  end

  // bridge、Tcl 或数据通路卡住时必须明确失败，不以进程退出码替代仿真完成标记。
  initial begin
    #50us;
    $fatal(1, "ETH_AIP_GLOBAL_TIMEOUT: Tcl test did not finish");
  end
endmodule
