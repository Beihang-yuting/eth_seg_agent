// src ready 驱动层：MAC 端独立产生 TX ready，不读取 RX valid 或改变 TX valid。
// ready 在负沿更新，连续/周期/随机图样仅决定 ready 引脚电平，驱动权由 interface 管理。
class eth_seg_ready_driver #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_ready_driver#(RATE))
  eth_seg_config#(RATE) cfg;
  int cycle_count = 0;

  // 构造 ready 组件；cfg 由 agent 设置并与 RX/TX 使用同一个虚接口。
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // 依据配置返回当前周期 ready；随机模式每周期独立抽样，占空比只影响概率。
  function bit next_ready();
    int period;
    case (cfg.ready_pattern)
      ETH_SEG_CONTINUOUS: return 1;
      ETH_SEG_PERIODIC: begin period = cfg.ready_high_cycles + cfg.ready_low_cycles; return ((cycle_count % period) < cfg.ready_high_cycles); end
      default: return ($urandom_range(0,99) < cfg.ready_high_pct);
    endcase
  endfunction

  // 负沿更新 drv_ready；复位保持 0，并在每周期递增图样计数。
  task run_phase(uvm_phase phase);
    string reason; if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_READY_CFG", reason)
    cfg.vif.claim_ready(get_full_name());
    forever begin
      @(negedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin cfg.vif.drv_ready <= 0; cycle_count = 0; end
      else begin cfg.vif.drv_ready <= next_ready(); cycle_count++; end
    end
  endtask

  // 释放 ready 代理并将值置零，保证 passive/下一个 test 不看到旧 ready。
  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) begin cfg.vif.drv_ready = 0; cfg.vif.release_ready(); end
  endfunction
endclass
