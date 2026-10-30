// 独立 testbench 顶层：同时实例化 100G/200G/400G 三个物理接口，彼此使用独立时钟、复位
// 和 UVM config_db 配置。三个 interface 各由 client TX 与 MAC RX/ready active agent 自检。
`timescale 1ns/1ps
import uvm_pkg::*;
import eth_seg_pkg::*;
module tb_top;
  logic clk_tx100 = 0, clk_rx100 = 0, tx_rst100_n = 0, rx_rst100_n = 0;
  logic clk_tx200 = 0, clk_rx200 = 0, tx_rst200_n = 0, rx_rst200_n = 0;
  logic clk_tx400 = 0, clk_rx400 = 0, tx_rst400_n = 0, rx_rst400_n = 0;

  always #2.0 clk_tx100 = ~clk_tx100;
  always #2.0 clk_rx100 = ~clk_rx100;
  always #2.0 clk_tx200 = ~clk_tx200;
  always #2.0 clk_rx200 = ~clk_rx200;
  always #2.0 clk_tx400 = ~clk_tx400;
  always #2.0 clk_rx400 = ~clk_rx400;

  eth_seg_if #(100) eth_if100(clk_tx100, clk_rx100, tx_rst100_n, rx_rst100_n);
  eth_seg_if #(200) eth_if200(clk_tx200, clk_rx200, tx_rst200_n, rx_rst200_n);
  eth_seg_if #(400) eth_if400(clk_tx400, clk_rx400, tx_rst400_n, rx_rst400_n);

  // 每个参数化实例都挂接独立 pin-level checker；checker 只读公共网络，
  // 直接验证 ready→valid 两拍、invalid 保持和 segment 边带约束。
  eth_seg_protocol_checker #(.RATE(100)) checker100 (
    .i_clk_tx(clk_tx100), .i_clk_rx(clk_rx100), .i_tx_rst_n(tx_rst100_n), .i_rx_rst_n(rx_rst100_n),
    .i_tx_mac_data(eth_if100.i_tx_mac_data), .i_tx_mac_valid(eth_if100.i_tx_mac_valid),
    .i_tx_mac_inframe(eth_if100.i_tx_mac_inframe), .i_tx_mac_eop_empty(eth_if100.i_tx_mac_eop_empty),
    .i_tx_mac_error(eth_if100.i_tx_mac_error), .i_tx_mac_skip_crc(eth_if100.i_tx_mac_skip_crc),
    .o_tx_mac_ready(eth_if100.o_tx_mac_ready), .o_rx_mac_data(eth_if100.o_rx_mac_data),
    .o_rx_mac_valid(eth_if100.o_rx_mac_valid), .o_rx_mac_inframe(eth_if100.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(eth_if100.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(eth_if100.o_rx_mac_fcs_error),
    .o_rx_mac_error(eth_if100.o_rx_mac_error), .o_rx_mac_status_data(eth_if100.o_rx_mac_status_data));
  eth_seg_protocol_checker #(.RATE(200)) checker200 (
    .i_clk_tx(clk_tx200), .i_clk_rx(clk_rx200), .i_tx_rst_n(tx_rst200_n), .i_rx_rst_n(rx_rst200_n),
    .i_tx_mac_data(eth_if200.i_tx_mac_data), .i_tx_mac_valid(eth_if200.i_tx_mac_valid),
    .i_tx_mac_inframe(eth_if200.i_tx_mac_inframe), .i_tx_mac_eop_empty(eth_if200.i_tx_mac_eop_empty),
    .i_tx_mac_error(eth_if200.i_tx_mac_error), .i_tx_mac_skip_crc(eth_if200.i_tx_mac_skip_crc),
    .o_tx_mac_ready(eth_if200.o_tx_mac_ready), .o_rx_mac_data(eth_if200.o_rx_mac_data),
    .o_rx_mac_valid(eth_if200.o_rx_mac_valid), .o_rx_mac_inframe(eth_if200.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(eth_if200.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(eth_if200.o_rx_mac_fcs_error),
    .o_rx_mac_error(eth_if200.o_rx_mac_error), .o_rx_mac_status_data(eth_if200.o_rx_mac_status_data));
  eth_seg_protocol_checker #(.RATE(400)) checker400 (
    .i_clk_tx(clk_tx400), .i_clk_rx(clk_rx400), .i_tx_rst_n(tx_rst400_n), .i_rx_rst_n(rx_rst400_n),
    .i_tx_mac_data(eth_if400.i_tx_mac_data), .i_tx_mac_valid(eth_if400.i_tx_mac_valid),
    .i_tx_mac_inframe(eth_if400.i_tx_mac_inframe), .i_tx_mac_eop_empty(eth_if400.i_tx_mac_eop_empty),
    .i_tx_mac_error(eth_if400.i_tx_mac_error), .i_tx_mac_skip_crc(eth_if400.i_tx_mac_skip_crc),
    .o_tx_mac_ready(eth_if400.o_tx_mac_ready), .o_rx_mac_data(eth_if400.o_rx_mac_data),
    .o_rx_mac_valid(eth_if400.o_rx_mac_valid), .o_rx_mac_inframe(eth_if400.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(eth_if400.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(eth_if400.o_rx_mac_fcs_error),
    .o_rx_mac_error(eth_if400.o_rx_mac_error), .o_rx_mac_status_data(eth_if400.o_rx_mac_status_data));

  initial begin
    repeat (5) @(posedge clk_tx100);
    tx_rst100_n = 1; rx_rst100_n = 1;
    tx_rst200_n = 1; rx_rst200_n = 1;
    tx_rst400_n = 1; rx_rst400_n = 1;
  end

  // 通过类型精确的 config_db 键传递三种 virtual interface，避免不同 RATE 句柄混接。
  initial begin
    uvm_config_db#(virtual eth_seg_if#(100))::set(null, "uvm_test_top", "vif100", eth_if100);
    uvm_config_db#(virtual eth_seg_if#(200))::set(null, "uvm_test_top", "vif200", eth_if200);
    uvm_config_db#(virtual eth_seg_if#(400))::set(null, "uvm_test_top", "vif400", eth_if400);
    run_test();
  end
endmodule
