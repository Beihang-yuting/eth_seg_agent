// checker 独立 pin-level 协议检查器：不依赖 UVM、virtual interface 或 bind。
// 所有 TX/RX 引脚显式列出，便于负向 testbench 单独实例化。RATE 在 elaboration 决定总线宽度。
// 每条诊断使用稳定 ETH_SEG_* 编号；复位清除历史，RX invalid 拍完全忽略字段。
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
      if (!i_tx_mac_valid) begin
        if (i_tx_mac_data !== tx_prev_data || i_tx_mac_inframe !== tx_prev_inframe ||
            i_tx_mac_eop_empty !== tx_prev_empty || i_tx_mac_error !== tx_prev_error ||
            i_tx_mac_skip_crc !== tx_prev_skip)
          $error("ETH_SEG_TX_INVALID_HOLD: TX fields changed while valid=0");
      end
      else begin
        if ($isunknown({i_tx_mac_data, i_tx_mac_inframe, i_tx_mac_eop_empty,
                        i_tx_mac_error, i_tx_mac_skip_crc}))
          $error("ETH_SEG_TX_QUALIFIED_X: qualified TX field is unknown");
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          bit seg_inframe;
          seg_inframe = i_tx_mac_inframe[s];
          if (!tx_packet && !seg_inframe) begin
            if (i_tx_mac_error[s]) $error("ETH_SEG_TX_IDLE_ERROR: idle segment has error");
          end
          else begin
            if (!tx_packet) begin tx_packet = 1; tx_packet_skip = i_tx_mac_skip_crc[s]; end
            else if (i_tx_mac_skip_crc[s] !== tx_packet_skip)
              $error("ETH_SEG_TX_SKIP_CRC_CHANGED: skip_crc changed within packet");
            if (i_tx_mac_eop_empty[s*3 +: 3] > 7)
              $error("ETH_SEG_TX_EMPTY_RANGE: eop_empty exceeds 7");
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
      if (o_rx_mac_valid === 1'bx)
        $error("ETH_SEG_RX_VALID_X: RX valid is unknown");
      else if (!o_rx_mac_valid) begin
        // invalid 周期的数据与边带不参与协议判断。
      end
      else begin
        if ($isunknown({o_rx_mac_data, o_rx_mac_inframe, o_rx_mac_eop_empty,
                        o_rx_mac_fcs_error, o_rx_mac_error, o_rx_mac_status_data}))
          $error("ETH_SEG_RX_QUALIFIED_X: qualified RX field is unknown");
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          bit seg_inframe;
          seg_inframe = o_rx_mac_inframe[s];
          if (!rx_packet && !seg_inframe) begin end
          else if (seg_inframe) begin
              if (!rx_packet) rx_packet = 1;
              // non-EOP 的边带由 MAC 保持或置任意值；合同只要求 EOP 处采样，
              // 因而这里不对它们施加零值假设，避免误伤合法实现。
            end
          else begin
              if (o_rx_mac_eop_empty[s*3 +: 3] > 7)
                $error("ETH_SEG_RX_EMPTY_RANGE: eop_empty exceeds 7");
              rx_packet = 0;
          end
        end
      end
    end
  end
endmodule
