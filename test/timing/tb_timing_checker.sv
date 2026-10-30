// test/timing checker 独立探针：区分 invalid、idle、non-EOP 和 EOP 的字段有效范围。
// 本模块直接拥有全部引脚刺激，无 UVM；故意非法用例由外部日志检查匹配指定诊断。
`timescale 1ns/1ps
module tb_timing_checker;
  logic clk = 0, rst_n = 0;
  logic [255:0] tx_data = 0, rx_data = 0;
  logic tx_valid = 0, rx_valid = 0, ready = 0;
  logic [1:0] ready_history = 0;
  logic [3:0] tx_inframe = 0, tx_error = 0, tx_skip = 0, rx_inframe = 0, rx_fcs = 0;
  logic [11:0] tx_empty = 0, rx_empty = 0, rx_status = 0;
  logic [7:0] rx_error = 0;
  string scenario;
  always #2ns clk = ~clk;

  // 独立两拍参考，只用于给 checker 提供合法 TX valid；不复用待测 driver 实现。
  always @(posedge clk) begin
    if (!rst_n) begin ready_history <= 0; tx_valid <= 0; end
    else begin ready_history <= {ready_history[0],ready}; tx_valid <= ready_history[0]; end
  end

  eth_seg_protocol_checker#(100) checker_dut (
    .i_clk_tx(clk), .i_clk_rx(clk), .i_tx_rst_n(rst_n), .i_rx_rst_n(rst_n),
    .i_tx_mac_data(tx_data), .i_tx_mac_valid(tx_valid), .i_tx_mac_inframe(tx_inframe),
    .i_tx_mac_eop_empty(tx_empty), .i_tx_mac_error(tx_error), .i_tx_mac_skip_crc(tx_skip),
    .o_tx_mac_ready(ready), .o_rx_mac_data(rx_data), .o_rx_mac_valid(rx_valid),
    .o_rx_mac_inframe(rx_inframe), .o_rx_mac_eop_empty(rx_empty),
    .o_rx_mac_fcs_error(rx_fcs), .o_rx_mac_error(rx_error), .o_rx_mac_status_data(rx_status)
  );

  initial begin
    if (!$value$plusargs("CASE=%s",scenario)) scenario = "rx_invalid";
    #9ns; rst_n = 1;
    $display("TIMING_CHECKER_CASE=%s",scenario);
    if (scenario == "rx_z") begin
      rx_valid = 1'bz;
    end
    else if (scenario inside {"rx_invalid","rx_dontcare","rx_eop_x","rx_data_x"}) begin
      rx_data = 'x; rx_empty = 'x; rx_error = 'x; rx_status = 'x; rx_fcs = 'x; rx_inframe = 'x;
      if (scenario != "rx_invalid") begin
        // 9B 帧占两个 segment；非 EOP 边带、EOP 未使用字节和尾部 idle 数据均无效。
        rx_valid = 1; rx_inframe = 4'b0001;
        rx_data[71:0] = 72'h123456789abcdef012;
        rx_empty[5:3] = 7; rx_error[3:2] = 0; rx_fcs[1] = 0;
        rx_status[5:3] = (scenario == "rx_eop_x") ? 3'bxxx : 3'd1;
        if (scenario == "rx_data_x") rx_data[7:0] = 'x;
      end
    end
    else if (scenario inside {"tx_dontcare","tx_data_x"}) begin
      ready = 1;
      repeat (4) @(negedge clk);
      #1ns;
      tx_data = 'x; tx_data[71:0] = 72'h123456789abcdef012;
      tx_inframe = 4'b0001; tx_empty = 'x; tx_empty[5:3] = 7;
      if (scenario == "tx_data_x") tx_data[7:0] = 'x;
    end
    else $fatal(1,"unknown checker CASE");
    @(posedge clk); #1ns;
    $display("TIMING_CHECKER_COMPLETE=%s",scenario);
    $finish;
  end
endmodule
