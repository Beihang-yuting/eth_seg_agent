// VIP 顶层 package：固定 include 顺序，确保类型、事务、驱动/监视器和 env 在同一编译单元可见。
// Makefile 仍显式先编译 interface，再编译本 package；不可将本文件拆成多个 RATE package。
package eth_seg_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  `include "uvm_macros.svh"

  `include "eth_seg_seq_item.sv"
  `include "eth_seg_codec.sv"
  `include "eth_seg_config.sv"
  `include "eth_seg_sequencer.sv"
  `include "eth_seg_tx_driver.sv"
  `include "eth_seg_rx_driver.sv"
  `include "eth_seg_ready_driver.sv"
  `include "eth_seg_tx_monitor.sv"
  `include "eth_seg_rx_monitor.sv"
  `include "eth_seg_scoreboard.sv"
  `include "eth_seg_coverage.sv"
  `include "eth_seg_agent.sv"
  `include "eth_seg_env.sv"
  `include "../seq_lib/eth_seg_base_seq.sv"
  `include "../seq_lib/eth_seg_frame_seq.sv"
endpackage
