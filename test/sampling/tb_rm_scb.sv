// test/sampling HDL 层：三条独立链路；测试控制复位，checker 检查实际引脚时序。
// 本层拥有 interface/control，UVM 只借用；出口由测试刺激源模拟，不包含用户 DUT。
`timescale 1ns/1ps
module eth_sampling_link #(parameter int RATE = 100)(input logic clk);
  import uvm_pkg::*;
  eth_sampling_control control(clk);
  eth_seg_if#(RATE) vif(clk, clk, control.tx_rst_n, control.rx_rst_n);

  eth_seg_protocol_checker#(.RATE(RATE)) pin_check (
    .i_clk_tx(clk), .i_clk_rx(clk), .i_tx_rst_n(control.tx_rst_n), .i_rx_rst_n(control.rx_rst_n),
    .i_tx_mac_data(vif.i_tx_mac_data), .i_tx_mac_valid(vif.i_tx_mac_valid),
    .i_tx_mac_inframe(vif.i_tx_mac_inframe), .i_tx_mac_eop_empty(vif.i_tx_mac_eop_empty),
    .i_tx_mac_error(vif.i_tx_mac_error), .i_tx_mac_skip_crc(vif.i_tx_mac_skip_crc),
    .o_tx_mac_ready(vif.o_tx_mac_ready), .o_rx_mac_data(vif.o_rx_mac_data),
    .o_rx_mac_valid(vif.o_rx_mac_valid), .o_rx_mac_inframe(vif.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(vif.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(vif.o_rx_mac_fcs_error),
    .o_rx_mac_error(vif.o_rx_mac_error), .o_rx_mac_status_data(vif.o_rx_mac_status_data)
  );

  // time-zero 发布控制和 typed vif；顶层 #0 后启动 UVM。
  initial begin
    uvm_config_db#(virtual eth_seg_if#(RATE))::set(
      null, $sformatf("uvm_test_top.r%0d", RATE), "vif", vif);
    uvm_config_db#(virtual eth_sampling_control)::set(
      null, $sformatf("uvm_test_top.r%0d", RATE), "control", control);
  end
endmodule

module tb_rm_scb;
  import uvm_pkg::*;
  import eth_rm_scb_test_pkg::*;
  logic clk = 0;
  always #2ns clk = ~clk;
  eth_sampling_link#(100) link100(clk);
  eth_sampling_link#(200) link200(clk);
  eth_sampling_link#(400) link400(clk);
  initial begin
    #0;
    run_test("eth_rm_scb_test");
  end
  initial begin
    #100us;
    $fatal(1, "ETH_SAMPLING_GLOBAL_TIMEOUT");
  end
endmodule
