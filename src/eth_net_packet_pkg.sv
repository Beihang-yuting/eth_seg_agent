// src 可选报文适配层：把 net_packet 的网络报文接到 segmented agent 的字节事务。
// 编译顺序为 net_packet_pkg、eth_seg_pkg、本 package；基础 VIP 不反向依赖此层。
// 本层只声明 sequence 类型，报文归调用方，转换生成的事务归 sequence/driver 管理。
package eth_net_packet_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  `include "../seq_lib/eth_base_seq.sv"
endpackage
