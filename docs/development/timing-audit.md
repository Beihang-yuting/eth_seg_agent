# Segmented agent 时序审查

本轮基于 `4fa3e62`（已包含 RX 尾部空段 inframe 修复）继续检查，关注真实 DUT 的
ready 更新相位、同拍连续包、有效气泡、包间隔、独立时钟和复位恢复。验证在
`10.11.10.53` 的 VCS W-2024.09-SP1 执行，使用协议手册第 7.4/7.5 节定义的字段有效范围。

## 复现的缺陷与修复

| 问题 | 触发条件与影响 | 修复 |
| --- | --- | --- |
| TX ready 相位依赖 | DUT 在正沿寄存 ready 时，原 driver 在负沿直接采样并移位，valid 相对统一正沿采样偏一拍；旧自检使用负沿 ready，掩盖了问题 | 新增正沿 clocking 采样线程，负沿只使用已经形成的两拍历史 |
| 显式包间隔无效 | `inter_frame_gap` 已写入 `gap_segments`，TX/RX 却都未读取；后续 SOP 可以紧跟 EOP | 两方向按有效 segment 消费 `gap_segments`，无效拍不扣减 |
| 负载设置与实际间隔不一致 | RX 同拍 EOP 后未检查 idle_left；默认固定负载 100 时 random_load 被绕过；原等待值按任意周期数产生，无法对应帧长与百分比 | 统一按本帧编码后的 segment 数计算负载间隔；随机模式独立选百分比；EOP 后逐段执行间隔 |
| checker 误报合法无效字段 | valid=1 时对整个总线查 X，误查 idle 段、EOP 后未使用字节，以及 RX non-EOP 边带 | 按包边界、empty 和字段有效范围逐段检查 |
| checker 漏检 RX valid=Z | 原判断仅匹配 `1'bx`，没有识别 `1'bz` | 使用 `$isunknown` 检查 valid，非法输入必须产生指定诊断 |

初始缺陷基线的独立场景结果：ready 场景产生 33 次 `ETH_SEG_TX_VALID_DELAY`；gap
场景 TX/RX 各有 46 次间隔错误；固定 load 场景 TX 9 次、RX 46 次；random_load 场景
TX/RX 各有 56 次。复位场景的报文恢复检查通过，但正沿 ready 仍产生 6 次延迟错误。
这些数量用于记录最初复现，不作为后续回归的预期错误数。

独立 checker 基线证明：RX valid=0 的未知字段本来就被正确忽略；误报发生在 **valid=1**
的无效字段。`rx_z` 漏报，`rx_dontcare`、`tx_dontcare` 各误报一次；有未知 EOP 状态的
`rx_eop_x` 应当报错。修复后还增加有效 TX/RX 数据字节为 X 的负向用例，防止扩大
don't-care 范围后漏掉真正非法数据。

## 定向回归

```bash
make timing-test SEED=7
make timing-test SEED=19
make timing-checker-test
```

可用 `SCENARIO=ready|gap|load|random_load|reset` 单独运行；默认 `all`。

主测试包含 100G/200G/400G × 正沿/负沿 ready 共六条 link，TX/RX 周期分别为 4ns/6ns。
检查内容包括：

- ready 单拍脉冲、长低电平与包内停顿，valid 固定两拍延迟及 valid=0 输出保持。
- 长短帧、EOP empty=0..7、同拍 EOP/SOP、非零 EOP 错误/状态和最后一拍空闲段。
- 显式 3 段间隔遇到 TX ready 和 RX valid 气泡仍保持正确；50% 固定负载与随机模式
  固定选择 25% 时，按帧长得到对应有效段间隔。
- 小队列反压、长包中复位、丢弃排队旧包、TX/RX 分别解除复位后新包正常发送。
- 输入事务与 monitor 逐字节相符，sent_ap 数量及 end_time 与真实 EOP 采样一致。

checker 七个独立用例中，三个合法用例要求零错误；`rx_z`、`rx_eop_x`、`rx_data_x`、
`tx_data_x` 四个非法输入各要求恰好一个指定诊断，由 `scripts/check_timing_checker.py`
判断。不能用普通零错误日志规则处理这四个负向用例。

## 修复后验证结果

2026-10-30 在 `10.11.10.53` 完成以下回归。基线目录保持原产品源码，修复版本在独立
`timing-audit-4fa3e62/fixed` 目录构建；本地日志汇总记录命令、依赖路径和关键源码 SHA-256。

| 回归 | 结果 |
| --- | --- |
| timing `all`，seed 7 / 19 | 每轮六条 link 完成；UVM WARNING/ERROR/FATAL 均为 0，无原生 Error |
| checker 七个用例 | 全部通过；三个合法用例零错误，四个非法用例各产生恰好一个预期诊断 |
| smoke，seed 7 | 100G/200G/400G 完成；含前导/FCS 及连续、周期、随机节奏组合 |
| bind，seed 7 | 四条 `BIND_RATE_PASS`，多实例绑定检查通过 |
| net_packet，seed 7 | 12 个组合、192 帧通过；六个参数边界 fatal 由测试 catcher 按预期捕获 |
| 普通 AIP / net_packet AIP，seed 7 | 两项均通过 Tcl 和 SV 完成检查；各自四端口完成 3/3/1/4 帧 |

五项集成回归最终 UVM WARNING/ERROR/FATAL 均为 0。包内停顿、独立 TX/RX 复位恢复、
队列反压和 `sent_ap` 完成通知比较未发现额外缺陷；结论限于本轮列出的测试范围。

## 负载和覆盖边界

设编码后帧占 `S` 个 64-bit segment，选定负载为 `P`%，则负载要求的 idle 段数为：

```text
load_gap = ceil(S * (100 - P) / P)
actual_gap = max(item.gap_segments, load_gap)
```

例如 9B 帧占两段，50% 对应至少两段 idle，25% 对应至少六段 idle。前导与 Ethernet FCS
开启时它们也计入编码长度。由于取整及外部气泡，这表示可用有效段上的注入上限，不能
把它直接解释为精确物理线路速率。`random_load=1` 每帧独立选择百分比。

复位用例保证复位覆盖两种时钟的多个采样沿，并在时钟沿之外独立释放；不据此声称支持
不满足 DUT 复位时序要求的任意窄脉冲。本轮是 VIP 与定向 DUT 行为模型的验证，不含
厂商 MAC RTL，也不是所有可能时序组合的形式化证明。

运行日志与最终统计保存于本地 `results/timing_audit/`，仿真产物不提交到仓库。
