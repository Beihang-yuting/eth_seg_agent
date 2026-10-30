// test/net_packet HDL 层：十二条独立 link 对应三速率和四种帧格式。
// 依赖 eth_net_packet_test_pkg/interface/checker；本层拥有时钟复位和 interface，
// UVM case 只借用 vif，pin checker 独立验证 ready 延迟与帧边带。
`timescale 1ns/1ps
module eth_net_test_link #(parameter int RATE = 100, MODE = 0)(input logic clk, rst_n);
  import uvm_pkg::*;
  eth_seg_if#(RATE) vif(clk, clk, rst_n, rst_n);

  eth_seg_protocol_checker#(.RATE(RATE)) pin_check (
    .i_clk_tx(clk), .i_clk_rx(clk), .i_tx_rst_n(rst_n), .i_rx_rst_n(rst_n),
    .i_tx_mac_data(vif.i_tx_mac_data), .i_tx_mac_valid(vif.i_tx_mac_valid),
    .i_tx_mac_inframe(vif.i_tx_mac_inframe), .i_tx_mac_eop_empty(vif.i_tx_mac_eop_empty),
    .i_tx_mac_error(vif.i_tx_mac_error), .i_tx_mac_skip_crc(vif.i_tx_mac_skip_crc),
    .o_tx_mac_ready(vif.o_tx_mac_ready), .o_rx_mac_data(vif.o_rx_mac_data),
    .o_rx_mac_valid(vif.o_rx_mac_valid), .o_rx_mac_inframe(vif.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(vif.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(vif.o_rx_mac_fcs_error),
    .o_rx_mac_error(vif.o_rx_mac_error), .o_rx_mac_status_data(vif.o_rx_mac_status_data)
  );

  // time-0 同步发布，顶层 #0 后的 UVM build 才读取这些句柄。
  initial uvm_config_db#(virtual eth_seg_if#(RATE))::set(
    null, $sformatf("uvm_test_top.r%0d_m%0d", RATE, MODE), "vif", vif);
endmodule

module tb_net_packet;
  import uvm_pkg::*;
  import eth_net_packet_test_pkg::*;
  logic clk = 0, rst_n = 0;
  always #2ns clk = ~clk;
  initial #41ns rst_n = 1;

  for (genvar m = 0; m < 4; m++) begin : formats
    eth_net_test_link#(100, m) link100(clk, rst_n);
    eth_net_test_link#(200, m) link200(clk, rst_n);
    eth_net_test_link#(400, m) link400(clk, rst_n);
  end

  initial begin
    #0;
    run_test("eth_net_packet_test");
  end

  // 同时保护 sequence 阻塞和 UVM phase 卡住的路径。
  initial begin
    #100us;
    $fatal(1, "ETH_NET_GLOBAL_TIMEOUT: network test did not complete");
  end
endmodule
