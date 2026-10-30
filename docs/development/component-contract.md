# 组件实现约定

此文件固定协作接口，细节修改先通知主代理。类文件由 eth_seg_pkg 按顺序 include。

- 参数名统一 `RATE=100`；interface 参数名 `ETH_RATE_G=100`，类型引用 `virtual eth_seg_if #(RATE)`。
- `eth_seg_types_pkg`：枚举 `ETH_SEG_CLIENT/ETH_SEG_MAC`，`ETH_SEG_CONTINUOUS/ETH_SEG_PERIODIC/ETH_SEG_RANDOM`，`ETH_SEG_TX/ETH_SEG_RX`；`typedef byte unsigned eth_seg_byte_queue_t[$]`。
- interface 构造输入 `i_clk_tx,i_clk_rx,i_tx_rst_n,i_rx_rst_n`；公共引脚全部采用手册完整名称。
- TX 私有驱动变量 `drv_tx_data/valid/inframe/eop_empty/error/skip_crc`；RX 对应 `drv_rx_data/valid/inframe/eop_empty/fcs_error/error/status_data`；ready 为 `drv_ready`。
- 三组占用位 `tx_drive_enabled,rx_drive_enabled,ready_drive_enabled` 初始0，assign 未占用为Z；`claim_tx/claim_rx/claim_ready` 检查重复占用；`release_tx/release_rx/release_ready`。
- `tx_cb` 在 TX 正沿采样全部公共 TX 字段及 ready、i_tx_rst_n，`rx_cb` 在 RX 正沿采样全部 RX 字段和 i_rx_rst_n；default input #1step。driver 在负沿直接更新私有变量。
- `eth_seg_config#(RATE)`：vif、eth_rate_g=RATE、role、is_active；preamble_passthrough/include_fcs默认0；enable_protocol_check=1；ready_pattern/rx_valid_pattern默认CONTINUOUS；ready_high_cycles=8/ready_low_cycles=2/ready_high_pct=70，rx_valid_high_cycles=8/rx_valid_low_cycles=2/rx_valid_high_pct=70；traffic_load_pct=100、random_load=0、load_min_pct=10、load_max_pct=100、max_pending=64；`validate(output string reason)`。
- `eth_seg_seq_item`：`rand byte unsigned frame_bytes[]`；`bit fcs_present=0,inject_fcs_error=0,inject_error=0,rx_fcs_error=0`；`bit[1:0] rx_error=0`、`bit[2:0]rx_status=1`；`int start_segment=-1,eop_segment=-1,empty_bytes=0,gap_segments=0`；`eth_seg_dir_e direction`；`bit fcs_checked=0,fcs_ok=0,aborted=0`；`bit[31:0] fcs`；`time start_time,end_time`。实现深拷贝。
- `eth_seg_codec` 非参数化静态类；`static function bit[31:0] crc32(input byte unsigned data[])`；`static function void encode(input eth_seg_seq_item item,input bit preamble,input bit include_fcs,output eth_seg_byte_queue_t bytes)`；`static function bit decode(input eth_seg_byte_queue_t bytes,input bit preamble,input bit include_fcs,ref eth_seg_seq_item item,output string reason)`。
- encode：include_fcs且fcs_present=0时自动追加CRC；fcs_present=1则frame_bytes已经含尾4B；inject_fcs_error只在include_fcs时翻转尾CRC一位；preamble为55*7+D5。decode移除前导，frame_bytes保留FCS（如果含有），填fcs_checked/ok和值。CRC不匹配是合法错误报文，只设置fcs_ok=0；格式不合法才返回0。
- `eth_seg_sequencer extends uvm_sequencer#(eth_seg_seq_item)` 非参数化。
- `eth_seg_tx_driver#(RATE)` / `eth_seg_rx_driver#(RATE)` extends uvm_driver#(eth_seg_seq_item)，`cfg` 由agent预设，`sent_ap` 在EOP拍真正采样后发布；`packets_sent` 计数；`is_idle()`。
- `eth_seg_ready_driver#(RATE)` extends uvm_component，只驱动 ready，cfg由agent设置。
- `eth_seg_tx_monitor#(RATE)` / RX：cfg预设，`item_collected_port`，`packets_seen`、`aborted_packets`、`valid_cycles`、`invalid_cycles`、`idle_segments`、`data_segments`、`bytes_seen`、`same_cycle_boundaries` 计数，`is_idle()`；错误通过uvm_error，预期CRC错误只记录fcs_ok。
- `eth_seg_agent#(RATE)` cfg由父设置或config_db取得；tx_monitor/rx_monitor始终创建；active按role建立tx_driver或rx_driver+ready_driver；成员 `sequencer` 非参数化。
- `eth_seg_env#(RATE)` 的 `client_cfg,mac_cfg` 在父build前赋值；创建client_agent/mac_agent；scoreboard关联 active driver.sent_ap 与一组monitor，coverage只订阅一组monitor。支持 `enable_scoreboard=1`、`enable_coverage=1`。
- `eth_seg_scoreboard` 非参数化，两方向独立 FIFO：`expect_tx/expect_rx/actual_tx/actual_rx` 为 analysis_imp；`matched_tx/matched_rx`；`is_idle()`；对比frame_bytes、inject_error(TX)、RX三类边带、FCS存在性。
- `eth_seg_coverage#(RATE)` 接收 `write(eth_seg_seq_item item)`；按事务字段覆盖位置/empty/方向/格式/错误；时序coverage可直接采样vif，配置 `cfg`。
- checker独立module参数RATE，端口显式信号（不用bind-to-interface），输入tx/rx clock/reset及完整TX/RX引脚；`enable_tx=1,enable_rx=1`。reset后历史清0，expected valid=ready_history[1]；上一拍值用于当前valid0保持检查。

## 设计边界修正

- 取消“单segment包”覆盖：该编码要求SOP和EOP位于不同segment，最短可编码包9B。
- 编译档位100/200/400与运行时负载分别配置。固定/随机负载通过包间idle segment实现；TX valid只由ready决定，RX valid可独立配置。
- 默认数据不包含FCS；include_fcs启用后monitor保留尾4B。`fcs_present`显式区分自动生成与已提供，不以CRC是否0判断。
- 原始接口中的PAD不能从任意EtherType payload无损猜测删除；默认合法sequence生成至少60B的DA到payload数据，不引入隐式PAD；接真实MAC时应用层保留收到的padding或自行按协议长度解释。
- 验证为VIP自检和独立pin级检查，未提供厂商F-Tile RTL，不能声称已验证真实IP。
