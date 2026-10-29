# MAC Segmented Ethernet UVM VIP 设计

## 目标

在当前工程中建立一个可复用的 F-Tile Ethernet MAC Segmented Client UVM VIP，
用于验证 MAC 客户端侧和 MAC 模型侧逻辑。VIP 按 `axi4-vip` 的目录和组件组织方式
实现 agent、sequence、monitor、checker、coverage、testbench 和 VCS 回归。

VIP 支持 100G、200G、400G 三种接口宽度，默认 transaction 从目的 MAC 地址开始，
到 payload 最后一个字节结束；preamble passthrough 与 FCS 由配置控制，默认均关闭。
TX 侧 `ready` 到 `valid` 的固定延迟为 2 个 TX 时钟周期。

## 速率参数化边界

速率决定物理接口宽度和 segment 数，因此必须在 SystemVerilog elaboration 时确定，
不能在同一次仿真中动态改变总线宽度。接口使用编译期参数：

```systemverilog
parameter int ETH_RATE_G = 100;
```

只允许 `ETH_RATE_G` 为 100、200 或 400。其余宽度由该参数推导：

| `ETH_RATE_G` | segment 数 | 数据宽度 |
|---:|---:|---:|
| 100 | 4 | 256 bit |
| 200 | 8 | 512 bit |
| 400 | 16 | 1024 bit |

公式为 `NUM_SEGMENTS = ETH_RATE_G / 25`、`DATA_WIDTH = NUM_SEGMENTS * 64`。

UVM config 同时保存 `eth_rate_g`，build/validate 阶段必须检查它与 virtual interface
的编译期速率一致。这样可以避免测试误把 100G transaction 送入 400G 接口，
也保留了 sequence 随机选择合法速率的配置入口。

“随机速率”采用多次 elaboration 的回归方式覆盖：回归脚本根据 seed 随机选择
100G、200G 或 400G，使用所选速率重新编译并运行对应测试。单个仿真不会改变总线宽度。
覆盖率报告通过三次合法速率运行合并检查，400G 作为最大速率单独包含稳定性测试。

## Agent 角色和组件

`eth_seg_config.role` 支持两种端点角色：

- `ETH_SEG_CLIENT`：驱动 TX client 输入，观察 TX ready，接收并监视 RX 输出。
- `ETH_SEG_MAC`：驱动 TX ready 和 RX MAC 输出，监视 TX client 输入。

每个角色都可配置为 active 或 passive。active 角色创建对应 driver、sequencer 和
monitor；passive 角色只创建 monitor。这样同一个 agent 可接入 MAC DUT，也可接入
客户端 DUT。

主要组件如下：

```text
rtl/eth_seg_if.sv
src/eth_seg_types.sv
src/eth_seg_config.sv
src/eth_seg_seq_item.sv
src/eth_seg_sequencer.sv
src/eth_seg_tx_driver.sv
src/eth_seg_rx_driver.sv
src/eth_seg_tx_monitor.sv
src/eth_seg_rx_monitor.sv
src/eth_seg_agent.sv
src/eth_seg_env.sv
src/eth_seg_pkg.sv
seq_lib/eth_seg_base_seq.sv
seq_lib/eth_seg_frame_seq.sv
checker/eth_seg_protocol_checker.sv
test/tb_top.sv
test/eth_seg_smoke_test.sv
```

## Transaction 和报文配置

transaction 使用动态字节数组保存客户端可见的报文：

```systemverilog
byte unsigned frame_bytes[];
bit            inject_error;
bit [31:0]     fcs;
```

默认 `frame_bytes` 的范围是：

```text
目的 MAC → 源 MAC → Length/Type → Payload
```

当 `preamble_passthrough=1` 时，TX driver 在接口数据前加入 8 字节前导，RX monitor
从物理流中去掉这 8 字节后再发布 transaction。标准前导为 7 个 `8'h55` 和一个
`8'hD5`。

当 `include_fcs=0` 时，TX driver 保持 `skip_crc=0`，不把 FCS 放进 client transaction；
MAC 负责追加 FCS。RX monitor 默认认为客户端可见数据在 payload 结束。

当 `include_fcs=1` 时，transaction 尾部含 4 字节 FCS，TX driver 置 `skip_crc=1`，
RX monitor 保留尾部 FCS。若 sequence 没有提供 FCS，VIP 使用 Ethernet CRC32 计算；
显式提供的 FCS 用于错误注入。

## TX 时序和包边界

所有 TX 信号由 `i_clk_tx` 同步。固定配置为：

```text
i_tx_mac_valid[t] = o_tx_mac_ready[t-2]
```

ready 连续有效时，valid 连续有效；ready 出现 0 的间歇时，valid 在两拍后出现相同
的间歇。`valid=0` 时，data、inframe、eop_empty、error、skip_crc 必须保持不变。

每个 64 bit segment 的边界按照相邻有效 segment 的 `inframe` 判断：

| 前一段 | 当前段 | 含义 |
|---:|---:|---|
| 0 | 0 | 空闲 |
| 0 | 1 | SOP |
| 1 | 1 | 包内数据 |
| 1 | 0 | EOP，当前段仍含最后数据 |

EOP segment 的有效字节数为 `8-eop_empty`，至少为 1。一个 TX 周期可以同时结束
旧包并开始新包。TX 包内不能主动插入任意 valid 空拍；ready 产生的固定停顿除外。

`skip_crc` 对当前 packet 的所有有效 segment 保持一致，包括 EOP segment。`error`
只在目标 packet 的 EOP segment 置位，用于通过 MII Error Control 标记错误帧。

## RX 行为

RX 没有直接 backpressure。`o_rx_mac_valid=0` 时忽略本拍所有字段，但 monitor 保留
当前 packet 状态；无效拍不能生成伪造的 SOP/EOP。

RX monitor 按有效 segment 重建 packet。`eop_empty`、`fcs_error`、2-bit `error` 和
3-bit `status_data` 只在 EOP segment 发布；这些字段按 segment 切片，不能只读总线低段。

## 覆盖率和定向测试

functional coverage 至少包括以下维度：

- 速率：100G、200G、400G；400G 单独作为最大速率场景。
- valid：连续有效、包间连续空闲、间歇有效（由 ready 停顿产生的 valid 气泡）。
- ready：连续有效、连续无效突发、随机间歇有效；覆盖 1、2、3 个及以上周期的低电平段。
- ready/valid 延迟：固定延迟 2 拍，覆盖 ready 上升、下降和恢复边界。
- packet：单 segment、跨 segment、任意 segment SOP、同拍 EOP+SOP、非 8 字节对齐 EOP、back-to-back。
- 配置：preamble passthrough 开关、FCS 开关、两者交叉组合。
- 错误：TX EOP error、显式错误 FCS、RX error/fcs_error/status_data 采样。

定向测试包含连续流、间歇流、随机 ready、随机 packet 长度、最大速率 400G，
以及随机选择合法 compile-time 速率的回归测试。checker 对 ready→valid 延迟、
valid 期间字段保持、包边界和 EOP 控制字段进行断言。

## VCS 验证

远程 10.11.10.53 已确认 VCS W-2024.09-SP1、UVM 1.2 和 GNU Make 可用。验证流程：

1. 分别编译 100G、200G、400G 三个参数化实例。
2. 运行连续/间歇 valid 和 ready 测试。
3. 运行 preamble/FCS 组合测试。
4. 运行 400G 最大速率和随机速率回归。
5. 检查每个仿真包含完整 UVM summary、无 UVM_ERROR/UVM_FATAL，并汇总 coverage。

