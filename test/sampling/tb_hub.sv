// test/sampling 无引脚单元测试入口：UVM 拥有 hub/SCB；本模块只负责启动及总超时。
// 不依赖 net_packet/AIP，验证订阅缓存的并发和对象所有权契约。
`timescale 1ns/1ps
module tb_hub;
  import uvm_pkg::*;
  import eth_seg_hub_test_pkg::*;
  initial run_test("eth_seg_hub_test");
  initial begin
    #100us;
    $fatal(1, "ETH_HUB_GLOBAL_TIMEOUT");
  end
endmodule
