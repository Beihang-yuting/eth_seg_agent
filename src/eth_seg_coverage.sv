// src 覆盖层：事务内容与引脚节奏的可审计 coverage collector。
// write() 订阅一组权威 monitor，复制事务字段到 covergroup 采样变量；独立 TX 时钟线程
// 统计 ready/valid 连续、间歇转换和 ready 低电平突发长度，公开计数供 test 断言覆盖闭合。
class eth_seg_coverage #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_coverage#(RATE))

  eth_seg_config#(RATE) cfg;
  virtual eth_seg_if#(RATE) vif;
  int unsigned transactions_seen;
  int unsigned valid_cycles, invalid_cycles, ready_high_cycles, ready_low_cycles;
  int unsigned ready_low_runs, max_ready_low_run;
  int unsigned valid_rise, valid_fall, ready_rise, ready_fall;
  int unsigned continuous_cycles, intermittent_cycles;

  int sample_dir, sample_len, sample_empty, sample_sop, sample_eop;
  int sample_fcs, sample_error, sample_rate, sample_ready, sample_valid;
  int sample_ready_low_length, sample_transition;
  bit prev_ready, prev_valid;
  int current_ready_low_run;

  // 事务 covergroup 覆盖方向、格式、边界位置、EOP empty、长度和错误组合。
  covergroup transaction_cg;
    cp_rate: coverpoint sample_rate { bins g100={100}; bins g200={200}; bins g400={400}; }
    cp_dir: coverpoint sample_dir { bins tx={0}; bins rx={1}; }
    cp_len: coverpoint sample_len { bins short_len={[1:15]}; bins medium_len={[16:63]}; bins long_len={[64:1518]}; bins jumbo_len={[1519:$]}; }
    cp_sop: coverpoint sample_sop { bins first={0}; bins later={[1:$]}; }
    cp_eop: coverpoint sample_eop { bins first={0}; bins later={[1:$]}; }
    cp_empty: coverpoint sample_empty { bins empty0={0}; bins empty1_7={[1:7]}; }
    cp_fcs: coverpoint sample_fcs { bins absent={0}; bins present={1}; }
    cp_error: coverpoint sample_error { bins clean={0}; bins error={1}; }
    cross_format_error: cross cp_fcs, cp_error;
  endgroup

  // 节奏 covergroup 记录 ready/valid 电平及连续、转换、低突发长度。
  covergroup timing_cg;
    cp_ready: coverpoint sample_ready { bins low={0}; bins high={1}; }
    cp_valid: coverpoint sample_valid { bins low={0}; bins high={1}; }
    cp_transition: coverpoint sample_transition { bins stable_low={0}; bins stable_high={1}; bins rise={2}; bins fall={3}; }
    cp_low_len: coverpoint sample_ready_low_length { bins one={1}; bins two={2}; bins three_plus={[3:$]}; }
    ready_valid: cross cp_ready, cp_valid;
  endgroup

  // 创建 covergroup 并保存组件配置句柄。
  function new(string name = "eth_seg_coverage", uvm_component parent = null);
    super.new(name, parent);
    transaction_cg = new();
    timing_cg = new();
  endfunction

  // 由 env 提供配置和接口；没有 vif 时仍可使用事务 coverage。
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg != null) vif = cfg.vif;
  endfunction

  // 复制一条 monitor 事务并采样；元数据错误统一折叠为 error 维度。
  function void write(eth_seg_seq_item item);
    sample_dir = (item.direction == ETH_SEG_RX) ? 1 : 0;
    sample_len = item.frame_bytes.size();
    sample_empty = item.empty_bytes;
    sample_sop = item.start_segment;
    sample_eop = item.eop_segment;
    sample_fcs = item.fcs_present;
    sample_error = item.inject_error || item.rx_fcs_error || (item.rx_error != 0) || (item.rx_status != 1);
    sample_rate = RATE;
    transaction_cg.sample();
    transactions_seen++;
  endfunction

  // 统计并采样一拍 ready/valid；复位清除历史，避免把复位边界误算成转换。
  task run_phase(uvm_phase phase);
    forever begin
      if (vif == null) begin #1ns; continue; end
      @(vif.tx_cb);
      if (!vif.i_tx_rst_n) begin
        prev_ready = 0; prev_valid = 0; current_ready_low_run = 0;
        continue;
      end
      sample_ready = (vif.o_tx_mac_ready === 1'b1);
      sample_valid = (vif.i_tx_mac_valid === 1'b1);
      if (sample_ready) begin
        ready_high_cycles++;
        if (!prev_ready) ready_rise++;
        current_ready_low_run = 0;
      end
      else begin
        ready_low_cycles++;
        if (prev_ready) begin
          ready_fall++;
          ready_low_runs++;
        end
        current_ready_low_run++;
        if (current_ready_low_run > max_ready_low_run) max_ready_low_run = current_ready_low_run;
        sample_ready_low_length = current_ready_low_run;
      end
      if (sample_valid) begin
        valid_cycles++;
        if (!prev_valid) valid_rise++;
      end
      else begin
        invalid_cycles++;
        if (prev_valid) valid_fall++;
      end
      if (sample_ready && sample_valid) continuous_cycles++;
      else intermittent_cycles++;
      if (!prev_ready && sample_ready) sample_transition = 2;
      else if (prev_ready && !sample_ready) sample_transition = 3;
      else sample_transition = sample_ready ? 1 : 0;
      timing_cg.sample();
      prev_ready = sample_ready;
      prev_valid = sample_valid;
    end
  endtask
endclass
