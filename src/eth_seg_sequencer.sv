// src sequence 仲裁层：非参数化 sequencer 只处理字节事务，与接口带宽完全解耦。
// agent 创建并拥有本组件；driver 的 item_done 仅表示副本入队，物理完成以 sent_ap 为准。
class eth_seg_sequencer extends uvm_sequencer #(eth_seg_seq_item);
  `uvm_component_utils(eth_seg_sequencer)

  // 建立标准 UVM sequencer，仲裁和 sequence 生命周期由 UVM 基类维护。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
