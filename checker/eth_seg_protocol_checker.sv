// checker 独立 pin-level 协议检查器：不依赖 UVM、virtual interface 或 bind。
// 所有 TX/RX 引脚显式列出，便于负向 testbench 单独实例化。RATE 在 elaboration 决定总线宽度。
// 每条诊断使用稳定 ETH_SEG_* 编号；复位清除历史，RX invalid 拍完全忽略字段。
// checker 只拥有解析历史；字段有效范围由 valid、包边界及 EOP empty 共同决定，
// idle 段、EOP 未用字节和 RX non-EOP 状态允许 X，不能对整个总线统一查未知值。
module eth_seg_protocol_checker #(parameter int RATE = 100) (
  input logic i_clk_tx, input logic i_clk_rx,
  input logic i_tx_rst_n, input logic i_rx_rst_n,
  input logic [RATE/25*64-1:0] i_tx_mac_data,
  input logic i_tx_mac_valid,
  input logic [RATE/25-1:0] i_tx_mac_inframe,
  input logic [RATE/25*3-1:0] i_tx_mac_eop_empty,
  input logic [RATE/25-1:0] i_tx_mac_error,
  input logic [RATE/25-1:0] i_tx_mac_skip_crc,
  input logic o_tx_mac_ready,
  input logic [RATE/25*64-1:0] o_rx_mac_data,
  input logic o_rx_mac_valid,
  input logic [RATE/25-1:0] o_rx_mac_inframe,
  input logic [RATE/25*3-1:0] o_rx_mac_eop_empty,
  input logic [RATE/25-1:0] o_rx_mac_fcs_error,
  input logic [RATE/25*2-1:0] o_rx_mac_error,
  input logic [RATE/25*3-1:0] o_rx_mac_status_data,
  input logic enable_tx = 1'b1,
  input logic enable_rx = 1'b1
);
  localparam int NUM_SEGMENTS = RATE/25;
  bit [1:0] ready_history;
  logic [NUM_SEGMENTS*64-1:0] tx_prev_data;
  logic [NUM_SEGMENTS-1:0] tx_prev_inframe, tx_prev_error, tx_prev_skip;
  logic [NUM_SEGMENTS*3-1:0] tx_prev_empty;
  bit tx_packet;
  bit tx_packet_skip;
  bit rx_packet;

  // checker 与接口共享编译期速率约束，非法宽度在 elaboration 即给出稳定诊断。
  initial begin
    if (!(RATE inside {100, 200, 400}))
      $error("ETH_SEG_RATE_INVALID: RATE must be 100, 200 or 400");
  end

  // TX 正沿检查 ready 两拍历史、valid0 保持、X 值和每段边带约束。
  always @(posedge i_clk_tx) begin
    if (!i_tx_rst_n) begin
      ready_history <= '0;
      tx_prev_data <= '0; tx_prev_inframe <= '0; tx_prev_error <= '0;
      tx_prev_skip <= '0; tx_prev_empty <= '0;
      tx_packet <= 0; tx_packet_skip <= 0;
    end
    else if (enable_tx) begin
      if (i_tx_mac_valid !== ready_history[1])
        $error("ETH_SEG_TX_VALID_DELAY: valid must equal ready delayed by 2 cycles");
      ready_history <= {ready_history[0], o_tx_mac_ready};
      if ($isunknown(i_tx_mac_valid))
        $error("ETH_SEG_TX_VALID_X: TX valid is unknown");
      else if (!i_tx_mac_valid) begin
        if (i_tx_mac_data !== tx_prev_data || i_tx_mac_inframe !== tx_prev_inframe ||
            i_tx_mac_eop_empty !== tx_prev_empty || i_tx_mac_error !== tx_prev_error ||
            i_tx_mac_skip_crc !== tx_prev_skip)
          $error("ETH_SEG_TX_INVALID_HOLD: TX fields changed while valid=0");
      end
      else begin
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          bit seg_inframe;
          int nbytes;
          if ($isunknown(i_tx_mac_inframe[s])) begin
            $error("ETH_SEG_TX_QUALIFIED_X: TX inframe is unknown");
            continue;
          end
          seg_inframe = i_tx_mac_inframe[s];
          if (!tx_packet && !seg_inframe) begin
            if (i_tx_mac_error[s]) $error("ETH_SEG_TX_IDLE_ERROR: idle segment has error");
          end
          else begin
            if ($isunknown({i_tx_mac_error[s], i_tx_mac_skip_crc[s]}))
              $error("ETH_SEG_TX_QUALIFIED_X: active TX error/skip_crc is unknown");
            if (!tx_packet) begin tx_packet = 1; tx_packet_skip = i_tx_mac_skip_crc[s]; end
            else if (i_tx_mac_skip_crc[s] !== tx_packet_skip)
              $error("ETH_SEG_TX_SKIP_CRC_CHANGED: skip_crc changed within packet");
            nbytes = 8;
            if (!seg_inframe) begin
              if ($isunknown(i_tx_mac_eop_empty[s*3 +: 3])) begin
                $error("ETH_SEG_TX_QUALIFIED_X: TX EOP empty is unknown");
                nbytes = 0;
              end else nbytes = 8 - i_tx_mac_eop_empty[s*3 +: 3];
            end
            for (int b = 0; b < nbytes; b++)
              if ($isunknown(i_tx_mac_data[s*64+b*8 +: 8]))
                $error("ETH_SEG_TX_QUALIFIED_X: active TX data byte is unknown");
            if (seg_inframe && i_tx_mac_error[s])
              $error("ETH_SEG_TX_ERROR_EARLY: error is only legal on EOP segment");
            if (!seg_inframe) tx_packet = 0;
          end
        end
      end
      tx_prev_data <= i_tx_mac_data; tx_prev_inframe <= i_tx_mac_inframe;
      tx_prev_empty <= i_tx_mac_eop_empty; tx_prev_error <= i_tx_mac_error;
      tx_prev_skip <= i_tx_mac_skip_crc;
    end
  end

  // RX 正沿只验证 valid 区间；invalid 时不读任何字段、不生成伪造边界。
  always @(posedge i_clk_rx) begin
    if (!i_rx_rst_n) begin
      rx_packet <= 0;
    end
    else if (enable_rx) begin
      if ($isunknown(o_rx_mac_valid))
        $error("ETH_SEG_RX_VALID_X: RX valid is unknown");
      else if (!o_rx_mac_valid) begin
        // invalid 周期的数据与边带不参与协议判断。
      end
      else begin
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          bit seg_inframe;
          int nbytes;
          if ($isunknown(o_rx_mac_inframe[s])) begin
            $error("ETH_SEG_RX_QUALIFIED_X: RX inframe is unknown");
            continue;
          end
          seg_inframe = o_rx_mac_inframe[s];
          if (!rx_packet && !seg_inframe) continue;
          nbytes = 8;
          if (seg_inframe) rx_packet = 1;
          else begin
            // 只有 EOP 的 empty 和三类状态有语义；非 EOP 的这些位不参与检查。
            if ($isunknown({o_rx_mac_eop_empty[s*3 +: 3], o_rx_mac_fcs_error[s],
                            o_rx_mac_error[s*2 +: 2], o_rx_mac_status_data[s*3 +: 3]}))
              $error("ETH_SEG_RX_QUALIFIED_X: RX EOP fields are unknown");
            if ($isunknown(o_rx_mac_eop_empty[s*3 +: 3])) nbytes = 0;
            else nbytes = 8 - o_rx_mac_eop_empty[s*3 +: 3];
            rx_packet = 0;
          end
          for (int b = 0; b < nbytes; b++)
            if ($isunknown(o_rx_mac_data[s*64+b*8 +: 8]))
              $error("ETH_SEG_RX_QUALIFIED_X: active RX data byte is unknown");
        end
      end
    end
  end
endmodule
