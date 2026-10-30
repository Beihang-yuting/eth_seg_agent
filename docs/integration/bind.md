# 简化 bind 与静态 sequencer

`eth_seg_bind_wrapper` 只保留两个可覆盖参数：`AGENT_NAME` 和 `RATE`。
wrapper 内同步创建 interface、默认 cfg 和 root agent；顶层 env 无需创建 agent，
也无需创建 virtual sequencer 来转接句柄。

## 1. 绑定与信号映射

```systemverilog
bind tb_top.u_dut.u_ip0 eth_seg_bind_wrapper #(
  .AGENT_NAME("eth0"), .RATE(400)
) u_eth_bind (
  .i_clk_tx             (tx_clk),
  .i_clk_rx             (rx_clk),
  .i_tx_rst_n           (tx_rst_n),
  .i_rx_rst_n           (rx_rst_n),
  .i_tx_mac_data        (tx_data),
  .i_tx_mac_valid       (tx_valid),
  .i_tx_mac_inframe     (tx_inframe),
  .i_tx_mac_eop_empty   (tx_eop_empty),
  .i_tx_mac_error       (tx_error),
  .i_tx_mac_skip_crc    (tx_skip_crc),
  .o_tx_mac_ready       (tx_ready),
  .o_rx_mac_data        (rx_data),
  .o_rx_mac_valid       (rx_valid),
  .o_rx_mac_inframe     (rx_inframe),
  .o_rx_mac_eop_empty   (rx_eop_empty),
  .o_rx_mac_fcs_error   (rx_fcs_error),
  .o_rx_mac_error       (rx_error),
  .o_rx_mac_status_data (rx_status_data)
);
```

左侧是 wrapper 端口，右侧是绑定目标内部的真实信号。名称相同时可用 `(.*)`。
四个 IP 分别绑定，并使用不同名字；速率必须匹配实际宽度：

```systemverilog
// 以下假设各 IP 内信号名称与 wrapper 一致。
bind tb_top.u_dut.u_ip0 eth_seg_bind_wrapper #(.AGENT_NAME("eth0"), .RATE(100)) u_eth_bind (.*);
bind tb_top.u_dut.u_ip1 eth_seg_bind_wrapper #(.AGENT_NAME("eth1"), .RATE(200)) u_eth_bind (.*);
bind tb_top.u_dut.u_ip2 eth_seg_bind_wrapper #(.AGENT_NAME("eth2"), .RATE(400)) u_eth_bind (.*);
bind tb_top.u_dut.u_ip3 eth_seg_bind_wrapper #(.AGENT_NAME("eth3"), .RATE(100)) u_eth_bind (.*);
```

若这些 IP 来自同一 module 类型，也可按类型绑定一次。将 `RATE` 连接目标的速率参数，
`AGENT_NAME` 连接目标的唯一名字参数，或留空自动从 HDL 层次生成。显式名字只允许
字母、数字和下划线，必须全仿真唯一；自动名字从 wrapper 的 `resolved_name` 读取。

| RATE | segments | data 宽度 |
|---|---:|---:|
| 100 | 4 | 256 |
| 200 | 8 | 512 |
| 400 | 16 | 1024 |

输出固定采用图片中的 `assign (supply1, supply0)`，按 interface 驱动所有权决定是否驱动。
绑定点必须是 `wire/tri` 网络；对于 IP 内过程赋值的变量，选择父层连接 IP 的 net。
TX invalid 拍仍保持驱动，不能用 valid 为条件释放引脚。不同 wrapper 的同一方向只能
有一个 active 驱动者。TX valid 固定等于 ready 延后两拍。

## 2. 默认 cfg 与 #0 启动

`eth_seg_config#(RATE)` 保留类型参数，因为 virtual interface 的宽度需要类型匹配。
bind 不再覆盖行为字段：默认 CLIENT active、无前导、无 FCS、连续 ready/RX valid、
100% 负载设置。默认事务从目的 MAC 开始，到 payload 结束。

顶层只需一个启动块：

```systemverilog
initial begin
  #0;
  run_test();
end
```

这是基于当前实现的明确约定：所有 wrapper 的 `initial` 都在 time-0 Active 区同步完成
cfg 和 agent 创建，没有 `#delay`、事件等待或 NBA 句柄发布。顶层 `#0` 进入 Inactive
区后才调用 `run_test()`，不再需要 `initialized` 标记。若以后给 wrapper 初始化增加
异步步骤，这个约定就需要重新设计。

**#0 仅保证 cfg/agent 已创建，不代表 sequencer 已创建。** sequencer 在 UVM build
创建、connect 中自动登记；从 `start_of_simulation` 或 `run_phase` 起使用静态表。

需要调整默认配置时，用户可在 `#0` 后、`run_test` 前直接改已有 cfg。例如替代 MAC
输出，验证用户逻辑：

```systemverilog
initial begin
  #0;
  u_dut.u_ip0.u_eth_bind.cfg.role = eth_seg_types_pkg::ETH_SEG_MAC;
  // 其他行为按需调整；默认值集中在 src/eth_seg_config.sv。
  run_test();
end
```

CLIENT 驱动 `i_tx_mac_*`；MAC 驱动 `o_rx_mac_*` 和 `o_tx_mac_ready`；PASSIVE 只监视。
角色、active/passive、格式和队列深度应在构建/发包前确定，不能在包中途切换。
checker 默认打开；`cfg.enable_protocol_check` 由各时钟负沿采样，需在复位/build 前设置。

原有 `eth0_agent`、`eth0_cfg`、`eth0_vif` 三个 config_db 键继续保留，方便连接 scoreboard。
句柄作用域覆盖 `uvm_test_top` 及子组件，获取时 RATE 类型必须匹配。

## 3. 静态 sqr 与 Tcl 发包

每个 active/passive agent 在 connect 自动登记，final 时撤销。PASSIVE 提供整包采样入口，
其 can_send=0，公共发包 sequence 和 Tcl 入口会拒绝发送；driver 仍只由 active 创建。
静态表定义在非参数化 `eth_seg_sequencer` 中，三种速率共用一张按名字索引的表：

```systemverilog
eth_seg_sequencer::sqr["eth0"]
eth_seg_sequencer::sqr["eth1"]
eth_seg_sequencer::sqr["eth2"]
eth_seg_sequencer::sqr["eth3"]
```

推荐查询接口 `eth_seg_sequencer::get_sqr("eth0")`：名字不存在时返回 null，不插入表项。
表只保存借用句柄，不创建或共享实际 sequencer；四个 IP 有四个独立仲裁器。
通过同一静态句柄取得整包以及接入 RM/SCB，参见 [整包采样说明](sampling.md)。
如果 agent 由普通 env 创建，索引使用完整名字，例如 `uvm_test_top.env.client`。

基于 `aip_core/update` 的可选示例在 `examples/aip/eth_seg_aip_pkg.sv`：

```systemverilog
// 该 sequence 提供 count 字段，body 内按当前 agent 名字读取 frame_length。
`aip_cmd_seq(eth0_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth0"))
```

读参代码在 sequence 执行时运行，因此每次 Tcl 调用都能读取新值：

```systemverilog
// param_path 取实际 sequencer 的父 agent 名字，例如 "eth0"。
int unsigned frame_length;
`aip_int(param_path, int unsigned, frame_length, 256)
```

Tcl 对应使用：

```tcl
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set_param path=eth0.frame_length value=256
set_param path=eth1.frame_length value=128
eth0_send count=10
eth1_send count=5
```

`aip_int` 在调用点读取参数；`set_param` 不会自动修改已经创建的 cfg 对象。
后续配置调试可按相同方式加读参和应用逻辑，注意构建字段与包内格式的生效边界。
本次示例只用它配置发包长度，agent cfg 保持默认值。

base test 不需要 env，也不创建 agent；在 `run_phase` 持有 objection 并运行一次
`aip_tcl_bridge::run_loop()` 即可。Tcl bridge 必须等 UVM connect 和 DUT reset 完成后接收
发包命令。现有环境已经启动 bridge 时，复用该 bridge，不再启动第二份。
`seq.start()` 返回仅代表 driver 已入队，结束仿真前仍须等 monitor/scoreboard 物理完成。
`aip_cmd_seq` 的 time 模式取消 sequence 也不会撤销 driver 已接收的帧。

## 4. 编译与验证

普通 VIP 的编译顺序保持 interface → types → package → checker → wrapper → testbench。
核心 VIP 无 AIP 依赖；使用 Tcl 示例时，先编译 AIP package，再编译示例 package。

在 `10.11.10.53` 载入 VCS 环境后运行：

```bash
make bind-test SEED=7
make run BUILD=build/smoke_check SEED=7
make aip-test AIP_CORE=/path/to/aip_core SEED=7
```

AIP 示例对照的 `update` 提交为 `cd339eff8d4b0982be885a0a71f3e593a4aed239`。
不自动下载、修改或提交外部依赖。完整 Tcl 用例见 `test/aip/send.tcl`。

bind 用例覆盖四个 IP（三种速率）、同速率多实例静态 sqr 隔离、默认 cfg、用户改 cfg、
#0 启动、双向报文和所有边带。AIP 用例通过真实 UCLI/Tcl 命令发包，四个默认 CLIENT
分别接收 3/3/1/4 帧，并逐字节核对长度、数据与端口隔离。两者都是接口自检壳，不含
厂商 MAC RTL。日志分别在 `build/bind/logs`、`build/aip/logs`，实际验证记录见 `results/bind_static`。

原 bind 简化版本于 2026-10-30 在 53 的 VCS W-2024.09-SP1 / UVM 1.2 上通过：bind seed 7/19、
smoke seed 7、AIP Tcl seed 7；最终 UVM WARNING/ERROR/FATAL 和 VCS 原生诊断均为 0。

整包采样扩展增加 passive sequencer 的直接取包检查，最新验证见
[采样验证记录](../development/sampling-validation.md)。
