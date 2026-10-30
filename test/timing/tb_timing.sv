// test/timing HDL 夹具：拥有异步 TX/RX 时钟、复位控制接口及真实寄存 ready 源。
// 依赖 eth_timing_test_pkg、产品 interface/checker；六个 link 互不共享可变状态。
`timescale 1ns/1ps
module timing_link #(parameter int RATE = 100, READY_POSEDGE = 0)(input logic tx_clk,rx_clk);
  import uvm_pkg::*;
  eth_timing_control control(tx_clk,rx_clk);
  eth_seg_if#(RATE) vif(tx_clk,rx_clk,control.tx_rst_n,control.rx_rst_n);
  logic ready = 0;
  assign vif.o_tx_mac_ready = ready;

  // 正沿寄存路径模拟常见 DUT；负沿路径模拟此前 VIP ready driver 的调度相位。
  if (READY_POSEDGE) begin
    always @(posedge tx_clk) ready <= control.tx_rst_n && control.ready_request;
  end else begin
    always @(negedge tx_clk) ready <= control.tx_rst_n && control.ready_request;
  end

  eth_seg_protocol_checker#(.RATE(RATE)) pin_check (
    .i_clk_tx(tx_clk), .i_clk_rx(rx_clk), .i_tx_rst_n(control.tx_rst_n), .i_rx_rst_n(control.rx_rst_n),
    .i_tx_mac_data(vif.i_tx_mac_data), .i_tx_mac_valid(vif.i_tx_mac_valid),
    .i_tx_mac_inframe(vif.i_tx_mac_inframe), .i_tx_mac_eop_empty(vif.i_tx_mac_eop_empty),
    .i_tx_mac_error(vif.i_tx_mac_error), .i_tx_mac_skip_crc(vif.i_tx_mac_skip_crc),
    .o_tx_mac_ready(vif.o_tx_mac_ready), .o_rx_mac_data(vif.o_rx_mac_data),
    .o_rx_mac_valid(vif.o_rx_mac_valid), .o_rx_mac_inframe(vif.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(vif.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(vif.o_rx_mac_fcs_error),
    .o_rx_mac_error(vif.o_rx_mac_error), .o_rx_mac_status_data(vif.o_rx_mac_status_data)
  );

  // 所有句柄同步发布；顶层 #0 进入 run_test 后再由 UVM build 读取。
  initial begin
    uvm_config_db#(virtual eth_seg_if#(RATE))::set(null,
      $sformatf("uvm_test_top.r%0d_p%0d",RATE,READY_POSEDGE),"vif",vif);
    uvm_config_db#(virtual eth_timing_control)::set(null,
      $sformatf("uvm_test_top.r%0d_p%0d",RATE,READY_POSEDGE),"control",control);
  end
endmodule

module tb_timing;
  import uvm_pkg::*;
  import eth_timing_test_pkg::*;
  logic tx_clk = 0, rx_clk = 0;
  always #2ns tx_clk = ~tx_clk;
  always #3ns rx_clk = ~rx_clk;

  for (genvar p = 0; p < 2; p++) begin : ready_phases
    timing_link#(100,p) l100(tx_clk,rx_clk);
    timing_link#(200,p) l200(tx_clk,rx_clk);
    timing_link#(400,p) l400(tx_clk,rx_clk);
  end

  initial begin #0; run_test("eth_timing_test"); end
  initial begin #500us; $fatal(1,"TIMING_GLOBAL_TIMEOUT"); end
endmodule
