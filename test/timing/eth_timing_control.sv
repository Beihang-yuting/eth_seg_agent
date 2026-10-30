// test/timing 控制接口：仅供定向测试改变独立 TX/RX 复位和 DUT ready 请求。
// HDL 顶层拥有接口，UVM case 借用；不向产品 eth_seg_if 添加测试专用信号。
interface eth_timing_control(input logic tx_clk, rx_clk);
  logic tx_rst_n = 0, rx_rst_n = 0;
  logic ready_request = 0;
endinterface
