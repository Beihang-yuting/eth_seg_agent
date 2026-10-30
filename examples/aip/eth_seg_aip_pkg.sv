// examples/aip 可选接入层：把现有 Ethernet sequence 注册为 AIP Tcl 命令。
// 依赖 eth_seg_pkg 与 aip_core/update 的 aip_core_pkg；核心 VIP 不依赖 AIP。
// 命令对象归 AIP 注册表，实际 sqr 由 bind agent 自动发布，本层不创建 agent/env。
package eth_seg_aip_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  // 每个命令共享 sequence 类型，通过当前 sequencer 的父 agent 名字隔离参数。
  // aip_int 每次实际执行时读取 Tcl override/plusarg；不修改已构建的 agent cfg。
  class eth_seg_aip_frame_seq extends eth_seg_base_seq;
    `uvm_object_utils(eth_seg_aip_frame_seq)
    int count = 1;

    // count 由 aip_cmd_seq 填写；其余帧属性沿用基础 sequence 的默认值。
    function new(string name = "eth_seg_aip_frame_seq");
      super.new(name);
    endfunction

    // 在当前 sqr 上产生 count 帧；长度按 agent 名字读取，错误在发送当前帧前终止。
    // finish_item 仅表示 driver 入队；物理完成由用户 monitor/scoreboard 判定。
    task body();
      eth_seg_sequencer sqr_handle;
      string param_path;
      int unsigned frame_length;
      if (!$cast(sqr_handle, get_sequencer()) || sqr_handle == null) begin
        `uvm_fatal("ETH_AIP_SQR", "named active sequencer is not registered")
        return;
      end
      if (!sqr_handle.can_send) begin
        `uvm_fatal("ETH_AIP_PASSIVE", "passive sequencer cannot send frames")
        return;
      end
      if (count <= 0) begin
        `uvm_fatal("ETH_AIP_COUNT", "count must be positive")
        return;
      end
      param_path = sqr_handle.get_parent().get_full_name();
      for (int unsigned n = 0; n < count; n++) begin
        eth_seg_seq_item item;
        `aip_int(param_path, int unsigned, frame_length, 256)
        if (frame_length < 9 || frame_length > 16384) begin
          `uvm_fatal("ETH_AIP_LENGTH", "frame_length must be 9..16384 bytes")
          return;
        end
        item = eth_seg_seq_item::type_id::create($sformatf("frame_%0d", n));
        make_frame(item, frame_length, n);
        start_item(item);
        finish_item(item);
        aip_activity::tick();
      end
    endtask
  endclass

  // 注册发生在静态初始化，get_sqr 表达式在命令执行时求值；此时 connect 已完成。
  // 用户按自己的 AGENT_NAME 增减这一组映射，既支持同速率，也支持混合速率 IP。
  `aip_cmd_seq(eth0_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth0"))
  `aip_cmd_seq(eth1_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth1"))
  `aip_cmd_seq(eth2_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth2"))
  `aip_cmd_seq(eth3_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth3"))
endpackage
