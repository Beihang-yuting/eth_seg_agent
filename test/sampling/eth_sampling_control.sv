// test/sampling 测试专用复位控制：HDL 拥有，UVM 借用；不扩展产品 interface 信号。
interface eth_sampling_control(input logic clk);
  logic tx_rst_n = 0;
  logic rx_rst_n = 0;
endinterface
