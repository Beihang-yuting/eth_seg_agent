# MAC Segmented Ethernet VIP Implementation Plan

> **For agentic workers:** 按本计划逐任务执行；用户已确认 spec 并要求开始。遵循上级 AGENTS.md 的模型分工，Astra 实现和审查，5.6 执行远程验证。

**Goal:** 交付可配置 100G/200G/400G、两端角色、前导码/FCS、流量负载和连续/间歇节奏的 UVM VIP，并在 53 上完成 VCS 回归。

**Architecture:** 编译期 RATE 参数贯穿 interface、config、driver、monitor、agent 和 env。字节 transaction 与接口宽度解耦；客户端 TX 和 MAC RX 分别拥有独立 sequencer，MAC ready 单独产生。驱动采用负沿更新、监测采用正沿采样，公共网络通过角色私有代理驱动，被动角色不驱动。

**Tech Stack:** SystemVerilog、UVM 1.2、VCS W-2024.09-SP1、GNU Make、Python 3、Bash。

**Spec:** `docs/superpowers/specs/2026-10-29-eth-segmented-vip-design.md`

## Global Constraints

- `ETH_RATE_G` 只允许 100、200、400；`NUM_SEGMENTS=ETH_RATE_G/25`，每段 64 bit。
- TX ready→valid 固定 2 拍；TX 无效拍保持五组数据/边带，RX 无效拍忽略信号并保持解析状态。
- 前导码与 FCS 默认关闭；默认 frame_bytes 是 DA 到 payload。开启 FCS 时支持自动追加或显式提供，monitor 保留 FCS 并记录校验结果。
- 同包至少占两个 segment；EOP 当前段 inframe=0，末段有效字节为 1～8。
- 速率档位是 elaboration 参数；运行时流量负载是 1～100% 配置，随机负载只改变空闲分布，不改变总线宽度。
- 普通源文件全部使用 .sv；每个文件、类、函数/task 有职责、所有权、时序/边界的中文说明。
- 所有编译与仿真在 10.11.10.53 执行；不得以退出码 0 单独判定 PASS。
- 参考仓库为 https://github.com/Beihang-yuting/axi4-vip ，参考提交 2a9deeecf4aa6462ba1e331027b3d0270c710452；借鉴结构，协议实现独立编写。

## 文件职责与接口契约

- `rtl/eth_seg_if.sv`：参数化物理信号、私有 TX/RX/ready 代理和三组占用标记；时钟输入 tx_clk、rx_clk，低有效复位 tx_reset_n、rx_reset_n。
- `src/eth_seg_types.sv`：`eth_seg_types_pkg`，角色 CLIENT/MAC、节奏 CONTINUOUS/PERIODIC/RANDOM、方向 TX/RX，以及字节队列类型。
- `src/eth_seg_seq_item.sv`：`frame_bytes[]`、`fcs_present`、`inject_fcs_error`、`inject_error`、RX 三类边带、`start_segment=-1`、`gap_segments=0`；monitor 填入方向、SOP/EOP 位置、实际 empty 和 CRC 结果。
- `src/eth_seg_config.sv`：`eth_seg_config#(RATE)` 保存 vif、role/is_active、前导/FCS 开关、ready/rx_valid 节奏与占空比、traffic_load_pct/random_load/min/max、队列上限、协议检查开关；`validate(output string reason)` 拒绝不合法配置。
- `src/eth_seg_codec.sv`：只负责字节格式和 CRC，不共享 driver/monitor 的 segment 状态机；`crc32(input byte unsigned bytes[])`、`encode(item,cfg,output queue)`、`decode(queue,cfg,item)`。
- `src/eth_seg_tx_driver.sv`、`eth_seg_rx_driver.sv`：prefetch 线程复制 transaction 后 item_done，发送线程拥有副本；`sent_ap` 在包含 EOP 的拍真正采样后发布，复位丢弃未完成副本。
- `src/eth_seg_ready_driver.sv`：MAC 角色产生 TX ready，与 RX valid 的节奏独立。
- `src/eth_seg_tx_monitor.sv`、`eth_seg_rx_monitor.sv`：独立解析状态机，`item_collected_port` 发布已重建的深拷贝报文。
- `src/eth_seg_agent.sv`：两角色均具备 TX/RX monitor，active CLIENT 建 TX driver，active MAC 建 RX driver 和 ready generator；`sequencer` 指向本角色发送方向。
- `src/eth_seg_env.sv`：可独立启停的 client/mac agent，scoreboard 仅连接一组权威 monitor，避免双计数。
- `src/eth_seg_scoreboard.sv`：对本地发送期望与实际引脚重建报文按方向比对；检查内容、EOP 错误和 CRC，不根据 sequence 完成就判通过。
- `src/eth_seg_coverage.sv`：速率/方向/前导/FCS、SOP/EOP 位置、empty、错误和节奏覆盖；同时输出可审计计数。
- `checker/eth_seg_protocol_checker.sv`：独立模块，对原始引脚逐拍验证 delay、hold、边界和边带，支持独立负向 checker 测试。
- `seq_lib/`：可配置报文长度、段偏移、间隙和错误的基础 sequence。
- `test/`：UVM 回归、独立 pin-level monitor 测试、checker 负向测试、多参数实例/真实 DUT 方向连接探针。
- `scripts/`、`config/`、`Makefile`：按速率隔离构建、超时、日志判定、随机种子和机器可读回归汇总。

## Task 1：基础协议类型和格式

- [ ] 建立类型、transaction、config、interface；非法 RATE 在 elaboration 报错，config 不匹配在 build_phase 报错。
- [ ] CRC 使用 Ethernet 反射多项式 32'hEDB88320、初值全 1、最终取反；低字节先发送。
- [ ] 编写已知向量检查：

```systemverilog
assert(eth_seg_codec::crc32('{8'h31,8'h32,8'h33,8'h34,8'h35,8'h36,8'h37,8'h38,8'h39}) == 32'hCBF43926);
```

- [ ] FCS 显式提供由 `fcs_present` 判定，不能用 fcs==0 作为未提供的标志；前导不参与 CRC。
- [ ] 53 上编译三个 RATE，记录基础检查结果后进入数据通路。

## Task 2：发送数据通路和节奏

- [ ] driver 预取完整包并 clone，再 item_done；队列有界，调用方应等待 monitor/sent 计数完成。
- [ ] TX 用正沿历史准备下一负沿驱动值，使正沿采样严格满足两拍关系：

```text
监测正沿 t：expected_valid = ready_history[1]
更新 history = {ready_history[0], ready[t]}
发送端准备正沿 t+1：valid = ready[t-1]
```

- [ ] segment 打包按剩余字节数判断：remaining>8 为 SOP/续包(inframe=1)，remaining<=8 为 EOP(inframe=0)。起包长度必须至少 9。
- [ ] 同拍连续消费多个已预取报文；无效拍不消费队列，不改变 data 和五组边带。
- [ ] RX valid 独立支持连续、固定高低周期和随机百分比；随机负载只在包间安排空闲段。
- [ ] 复位清除未完成状态和历史，释放/占用驱动所有权遵循 active 生命周期。

## Task 3：观察、检查与比对

- [ ] monitor 用 previous_inframe 跨有效段解析，RX invalid 时不改状态，EOP 提取低端 8-empty 字节。
- [ ] 以独立 pin 源送入人工已知字节序列，验证 monitor，避免只依赖同算法回环。
- [ ] checker 独立检测 ready delay/invalid hold/skip_crc 包内一致/EOP error 位置/有效字段 X。
- [ ] scoreboard 比对两方向字节、控制、完成计数；缺失包、重复包、未完成包都导致失败。
- [ ] 负向 checker 测试逐项注入已知违规，要求指定诊断精确命中且测试完成。

## Task 4：UVM 回归和覆盖闭合

- [ ] 构建双 active 自检拓扑及 CLIENT-only/MAC-only/passive 的 DUT 连接探针。
- [ ] 对每个速率运行 preamble/FCS 四组合、连续流、周期气泡、随机气泡、随机负载。
- [ ] 定向遍历每个 SOP 段、每个 EOP 段和 empty 0～7，并要求观测到同拍旧 EOP/新 SOP。
- [ ] 覆盖 ready 低段长度 1、2、3+，覆盖 RX 包中 valid 气泡，400G 高负载短包与长包。
- [ ] 运行 reset-in-packet，再发送正常包确认恢复；非法 config 和无所有权角色不驱动的场景单独验证。
- [ ] 每次回归至少满足完整 UVM summary、零非预期 ERROR/FATAL、scoreboard 无积压、明确完成标志。

## Task 5：远程执行、文档和最终审查

- [ ] Makefile 提供 `make compile RATE=100`、`make run RATE=100 TEST=eth_seg_smoke_test`、`make regress`。
- [ ] 5.6 在 53 的隔离目录执行构建和回归；Astra 按失败证据修改后，5.6 重跑受影响检查。
- [ ] 保存版本、命令、种子、测试数量、覆盖计数及日志位置；明确这是 VIP 自检，没有 F-Tile 加密 RTL 模型。
- [ ] README 说明参数化 config_db 类型、两端角色、默认格式、FCS、负载节奏、接线和 sequence 完成语义。
- [ ] 全量复审代码的中文说明、复位、对象所有权和 drive 生命周期；通过后提交实现。
