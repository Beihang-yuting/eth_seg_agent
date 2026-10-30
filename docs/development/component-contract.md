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
- `eth_seg_sequencer extends uvm_sequencer#(eth_seg_seq_item)` 非参数化；active/passive 都创建并按完整 agent 名称登记。`monitor_hub` 在 build 关联，`can_send` 在 connect 发布；passive 只提供采样。
- `eth_seg_monitor_hub` 接收 Monitor 的 EOP 整包，为每个 `(direction, portid)` 保存独立深拷贝；提供 `subscribe/mon_xaction/unsubscribe`，默认容量 1024 包，溢出 fatal，不回放订阅前数据。
- `eth_seg_tx_driver#(RATE)` / `eth_seg_rx_driver#(RATE)` extends uvm_driver#(eth_seg_seq_item)，`cfg` 由agent预设，`sent_ap` 在EOP拍真正采样后发布；`packets_sent` 计数；`is_idle()`。
- `eth_seg_ready_driver#(RATE)` extends uvm_component，只驱动 ready，cfg由agent设置。
- `eth_seg_tx_monitor#(RATE)` / RX：cfg预设，`item_collected_port`，`packets_seen`、`aborted_packets`、`valid_cycles`、`invalid_cycles`、`idle_segments`、`data_segments`、`bytes_seen`、`same_cycle_boundaries` 计数，`is_idle()`；错误通过uvm_error，预期CRC错误只记录fcs_ok。
- `eth_seg_agent#(RATE)` cfg由父设置或config_db取得；tx_monitor/rx_monitor始终创建；active按role建立tx_driver或rx_driver+ready_driver；成员 `sequencer` 非参数化。
- `eth_seg_env#(RATE)` 的 `client_cfg,mac_cfg` 在父build前赋值；创建client_agent/mac_agent；scoreboard关联 active driver.sent_ap 与一组monitor，coverage只订阅一组monitor。支持 `enable_scoreboard=1`、`enable_coverage=1`。
- `eth_seg_scoreboard` 非参数化，两方向独立 FIFO：`expect_tx/expect_rx/actual_tx/actual_rx` 为 analysis_imp；`matched_tx/matched_rx`；`is_idle()`；对比frame_bytes、inject_error(TX)、RX三类边带、FCS存在性。`write_before/write_after` 分别写 TX expected/actual，`flush_direction` 只清指定方向队列，保留累计计数。
- `eth_seg_coverage#(RATE)` 接收 `write(eth_seg_seq_item item)`；按事务字段覆盖位置/empty/方向/格式/错误；时序coverage可直接采样vif，配置 `cfg`。
- checker独立module参数RATE，端口显式信号（不用bind-to-interface），输入tx/rx clock/reset及完整TX/RX引脚；`enable_tx=1,enable_rx=1`。reset后历史清0，expected valid=ready_history[1]；上一拍值用于当前valid0保持检查。

## 设计边界修正

- 取消“单segment包”覆盖：该编码要求SOP和EOP位于不同segment，最短可编码包9B。
- 编译档位100/200/400与运行时负载分别配置。固定/随机负载通过包间idle segment实现；TX valid只由ready决定，RX valid可独立配置。
- 默认数据不包含FCS；include_fcs启用后monitor保留尾4B。`fcs_present`显式区分自动生成与已提供，不以CRC是否0判断。
- 原始接口中的PAD不能从任意EtherType payload无损猜测删除；默认合法sequence生成至少60B的DA到payload数据，不引入隐式PAD；接真实MAC时应用层保留收到的padding或自行按协议长度解释。
- 验证为VIP自检和独立pin级检查，未提供厂商F-Tile RTL，不能声称已验证真实IP。

## 时序边界约定

- TX ready 必须使用 `tx_cb` 的正沿采样值形成历史，再在负沿驱动 valid；在正沿观察到的
  `valid[t] = ready[t-2]`，不依赖 DUT 在正沿还是负沿更新 ready。
- `gap_segments` 表示本帧后最小有效 idle segment 数；TX/RX 都逐段消费，同拍 EOP 后也要
  先完成间隔才能发送下一个 SOP。ready/valid 气泡既不消费报文字节，也不消费间隔。
- 配置统一通过 `gap_after_frame(frame_segments, minimum_gap)` 计算间隔。固定负载使用
  `traffic_load_pct`；`random_load=1` 时每帧独立从 `load_min_pct..load_max_pct` 选择百分比，
  不受固定负载默认 100 限制。间隔为 `max(minimum_gap, ceil(frame_segments*(100-pct)/pct))`。
- 负载定义是客户端接口可用有效 segment 中的数据段占比上限，按段取整；外部 ready/RX
  valid 气泡、报文来源饥饿、显式最小间隔还会降低实际吞吐，不等同于物理链路 Gbit/s 保证。
- checker 对 valid 为 X/Z 报错；valid=0 时 RX 全部字段不参与检查。valid=1 时仅检查
  包内有效数据字节，RX 状态/empty 只在 EOP 检查，idle 段和 EOP 未使用字节允许未知。
  TX valid=0 时全部输出保持的原规则不变。

定向覆盖与审查记录见 [时序审查](timing-audit.md)。

## 整包采样与批量发送约定

- `eth_base_seq` 位于可选 `eth_net_packet_pkg`，直接提供三种采样方法，不另加父类。
  `count=1` 是唯一默认批量循环；显式 pkt 重放原字节，空 pkt 每轮调用 create_packet。
- `mon_xaction` 成功返回一个完整 EOP 事务；默认从目的 MAC 到 payload，保留线上
  padding。前导移除，启用 FCS 时尾四字节保留，RM 不需要重新拼接 segment。
- hub 复位清理仅限该方向缓存，保留订阅和等待者，原 timeout 截止时间不变。
  `reset_ap` 按值发布 direction/asserted/epoch；已交给 RM 的包由用户协调终止预测。
- RM/SCB 示例采用任一方向复位就丢弃整条链路在途包的策略，独立于 hub 的方向清理。
  测试结束同时核对数量和各层排空，sequence 返回不代表物理传输结束。

完整接口见 [采样集成说明](../integration/sampling.md)，验证证据见
[采样验证记录](sampling-validation.md)。
