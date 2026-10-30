// src 检查层：双方向异步 expected/actual FIFO scoreboard。
// driver 在真正 EOP 采样后发布 expected，monitor 可早于或晚于 driver 发布 actual；
// 每条 analysis_imp 都先复制事务入对应 FIFO，再按到达顺序尝试匹配，因此不依赖时间戳、
// sequence id 或 UVM 调度顺序。check_phase 对残留 FIFO 报错，确保丢包和重复包可见。
`uvm_analysis_imp_decl(_expect_tx)
`uvm_analysis_imp_decl(_expect_rx)
`uvm_analysis_imp_decl(_actual_tx)
`uvm_analysis_imp_decl(_actual_rx)
class eth_seg_scoreboard extends uvm_component;
  `uvm_component_utils(eth_seg_scoreboard)

  uvm_analysis_imp_expect_tx#(eth_seg_seq_item, eth_seg_scoreboard) expect_tx;
  uvm_analysis_imp_expect_rx#(eth_seg_seq_item, eth_seg_scoreboard) expect_rx;
  uvm_analysis_imp_actual_tx#(eth_seg_seq_item, eth_seg_scoreboard) actual_tx;
  uvm_analysis_imp_actual_rx#(eth_seg_seq_item, eth_seg_scoreboard) actual_rx;
  eth_seg_seq_item expect_tx_fifo[$], expect_rx_fifo[$];
  eth_seg_seq_item actual_tx_fifo[$], actual_rx_fifo[$];
  int unsigned matched_tx, matched_rx, mismatch_tx, mismatch_rx;

  // 创建四个 analysis implementation；FIFO 所有权归 scoreboard，写入对象会深拷贝。
  function new(string name = "eth_seg_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    expect_tx = new("expect_tx", this);
    expect_rx = new("expect_rx", this);
    actual_tx = new("actual_tx", this);
    actual_rx = new("actual_rx", this);
  endfunction

  // 比较方向无关的公共字节和 FCS 存在性，再比较对应方向的错误边带。
  function bit same_item(input eth_seg_seq_item exp, input eth_seg_seq_item act,
                         input bit is_rx, output string why);
    why = "";
    if (exp.frame_bytes.size() != act.frame_bytes.size()) begin
      why = $sformatf("frame length expected %0d actual %0d", exp.frame_bytes.size(), act.frame_bytes.size());
      return 0;
    end
    foreach (exp.frame_bytes[i]) if (exp.frame_bytes[i] != act.frame_bytes[i]) begin
      why = $sformatf("frame byte[%0d] expected %02x actual %02x", i, exp.frame_bytes[i], act.frame_bytes[i]);
      return 0;
    end
    if (exp.fcs_present != act.fcs_present) begin why = "fcs_present mismatch"; return 0; end
    if (is_rx) begin
      if (exp.rx_fcs_error != act.rx_fcs_error) begin why = "rx_fcs_error mismatch"; return 0; end
      if (exp.rx_error != act.rx_error) begin why = "rx_error mismatch"; return 0; end
      if (exp.rx_status != act.rx_status) begin why = "rx_status mismatch"; return 0; end
    end
    else if (exp.inject_error != act.inject_error) begin
      why = "EOP inject_error mismatch";
      return 0;
    end
    return 1;
  endfunction

  // 尝试匹配一个方向的队首；actual 先到时也可由后续 expected 触发。
  function void try_match(input bit is_rx);
    eth_seg_seq_item exp, act;
    string why;
    if (is_rx) begin
      if (expect_rx_fifo.size() == 0 || actual_rx_fifo.size() == 0) return;
      exp = expect_rx_fifo.pop_front(); act = actual_rx_fifo.pop_front();
      if (same_item(exp, act, 1, why)) matched_rx++;
      else begin mismatch_rx++; `uvm_error("ETH_SEG_SB_RX", $sformatf("ETH_SEG_RX_MISMATCH: %s", why)) end
    end
    else begin
      if (expect_tx_fifo.size() == 0 || actual_tx_fifo.size() == 0) return;
      exp = expect_tx_fifo.pop_front(); act = actual_tx_fifo.pop_front();
      if (same_item(exp, act, 0, why)) matched_tx++;
      else begin mismatch_tx++; `uvm_error("ETH_SEG_SB_TX", $sformatf("ETH_SEG_TX_MISMATCH: %s", why)) end
    end
  endfunction

  // 接收 TX expected 并复制入 FIFO；driver 原对象之后可安全复用。
  function void write_expect_tx(eth_seg_seq_item item);
    eth_seg_seq_item c = new("sb_exp_tx"); c.copy(item); expect_tx_fifo.push_back(c); try_match(0);
  endfunction
  // 接收 RX expected 并复制入 FIFO。
  function void write_expect_rx(eth_seg_seq_item item);
    eth_seg_seq_item c = new("sb_exp_rx"); c.copy(item); expect_rx_fifo.push_back(c); try_match(1);
  endfunction
  // 接收 TX actual monitor 事务。
  function void write_actual_tx(eth_seg_seq_item item);
    eth_seg_seq_item c = new("sb_act_tx"); c.copy(item); actual_tx_fifo.push_back(c); try_match(0);
  endfunction
  // 接收 RX actual monitor 事务。
  function void write_actual_rx(eth_seg_seq_item item);
    eth_seg_seq_item c = new("sb_act_rx"); c.copy(item); actual_rx_fifo.push_back(c); try_match(1);
  endfunction

  // 返回四个 FIFO 都为空且没有待比对事务。
  function bit is_idle();
    return expect_tx_fifo.size() == 0 && expect_rx_fifo.size() == 0 &&
           actual_tx_fifo.size() == 0 && actual_rx_fifo.size() == 0;
  endfunction

  // UVM analysis_imp 同名回调必须完成实际入队；该阶段检查残留包并报告丢失/重复。
  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (expect_tx_fifo.size() || actual_tx_fifo.size())
      `uvm_error("ETH_SEG_SB_TX_REMAINDER", $sformatf("ETH_SEG_TX_REMAINDER: expected=%0d actual=%0d", expect_tx_fifo.size(), actual_tx_fifo.size()))
    if (expect_rx_fifo.size() || actual_rx_fifo.size())
      `uvm_error("ETH_SEG_SB_RX_REMAINDER", $sformatf("ETH_SEG_RX_REMAINDER: expected=%0d actual=%0d", expect_rx_fifo.size(), actual_rx_fifo.size()))
  endfunction
endclass
