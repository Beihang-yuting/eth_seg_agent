# 用参数化 module bind 接入 DUT

`bind/eth_seg_bind_wrapper.sv` 按图片中的结构实现：module 内实例化
`eth_seg_if#(RATE)`，创建 `eth_seg_agent#(RATE)`，再用连续赋值接入 DUT 的 net。
agent 用 `type_id::create(name, null)` 创建，是 UVM root 的子组件，会正常参加 UVM phase。
wrapper 内不调用 `run_test()`。

## 1. 选择替代哪一端

所有 TX/RX 名称均从 **MAC IP 视角**定义，与文档一致。

| 模式 | wrapper 驱动 | wrapper 观察 | 典型用途 |
|---|---|---|---|
| `ETH_SEG_CLIENT` + `UVM_ACTIVE` | `i_tx_mac_*` | TX、RX 和 `o_tx_mac_ready` | 给真实 MAC DUT 发包 |
| `ETH_SEG_MAC` + `UVM_ACTIVE` | `o_rx_mac_*`、`o_tx_mac_ready` | TX、RX 和 ready | 替代 MAC，验证用户逻辑 |
| `UVM_PASSIVE` | 全部输出为 Z | 双向全部引脚 | 在现有链路旁挂监视器 |

同一组引脚通常只需要一个 wrapper。测试示例同时绑定 CLIENT、MAC 和 passive，是为了
闭环自检：CLIENT 和 MAC 各自驱动不同方向。每个方向只能有一个 active 驱动者；不同
wrapper 的 interface 独立，其内部所有权检查不能代替系统级的重复绑定检查。

## 2. 绑定一个实例

下面替代 MAC 一侧；将右侧信号名改为 `tb_top.u_dut` 内实际存在的 **wire/tri net**。
如果是要驱动真实 MAC 的 TX 输入，将 `ROLE` 改为 `ETH_SEG_CLIENT`。

```systemverilog
bind tb_top.u_dut eth_seg_bind_wrapper #(
  .RATE                 (400),
  .AGENT_NAME           ("eth0"),
  .ROLE                 (eth_seg_types_pkg::ETH_SEG_MAC),
  .ACTIVE_MODE          (uvm_pkg::UVM_ACTIVE),
  .PREAMBLE_PASSTHROUGH  (0),
  .INCLUDE_FCS          (0),
  .OVERRIDE_DUT         (1),
  .READY_PATTERN        (eth_seg_types_pkg::ETH_SEG_PERIODIC),
  .READY_HIGH_CYCLES    (8),
  .READY_LOW_CYCLES     (2)
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

如果目标 module 的引脚名称与 wrapper 完全一致，可把端口连接写成 `u_eth_bind (.*)`。
需要按 module 类型绑定所有实例时，参数表达式可以引用目标 module 的参数：

```systemverilog
// my_eth_port 内须有参数 ETH_RATE_G；每个实例可以分别设置为 100/200/400。
// 名称留空，由每个绑定实例的完整 HDL 层次生成不同的 root agent 名称。
bind my_eth_port eth_seg_bind_wrapper #(
  .RATE(ETH_RATE_G),
  .AGENT_NAME(""),
  .ROLE(eth_seg_types_pkg::ETH_SEG_CLIENT)
) u_eth_bind (.*);
```

显式 `AGENT_NAME` 只能包含字母、数字、下划线，且必须全仿真唯一。
重复名字在 time-0 报 `ETH_BIND_NAME` 并终止；自动生成的名字可从
`u_eth_bind.resolved_name` 取得。

## 3. 参数与驱动行为

| 参数 | 默认值 | 含义 |
|---|---|---|
| `RATE` | `100` | 编译期速率类型，只支持 100/200/400 |
| `AGENT_NAME` | `""` | 空字符串按绑定层次生成名字，否则用指定 root 名字 |
| `ROLE` / `ACTIVE_MODE` | CLIENT / ACTIVE | 选择驱动方向或纯监视 |
| `PREAMBLE_PASSTHROUGH` / `INCLUDE_FCS` | `0` / `0` | 前导透传、接口保留 FCS |
| `OVERRIDE_DUT` | `1` | supply 强度接管原 strong net 驱动；0 使用普通 strong |
| `ENABLE_CHECKER` | `1` | 静态实例化双向协议检查器 |
| `READY_PATTERN` / `RX_VALID_PATTERN` | CONTINUOUS | 支持 CONTINUOUS、PERIODIC、RANDOM |
| `READY_HIGH_CYCLES` / `READY_LOW_CYCLES` | `8` / `2` | ready 周期模式高/低拍数 |
| `RX_VALID_HIGH_CYCLES` / `RX_VALID_LOW_CYCLES` | `8` / `2` | RX valid 周期模式高/低拍数 |
| `READY_HIGH_PCT` / `RX_VALID_HIGH_PCT` | `70` / `70` | 随机模式逐拍有效概率，范围 0..100 |
| `TRAFFIC_LOAD_PCT` | `100` | 包间节流设置；100 表示不主动插入负载间隙 |
| `RANDOM_LOAD` | `0` | 在启用包间节流时随机选择负载设置 |
| `LOAD_MIN_PCT` / `LOAD_MAX_PCT` | `10` / `100` | 随机负载范围，1..100 |
| `MAX_PENDING` | `64` | driver 预取事务队列上限 |

| RATE | segments | data 宽度 | inframe / TX error / skip_crc / RX fcs_error | eop_empty / status_data | RX error |
|---|---:|---:|---:|---:|---:|
| 100 | 4 | 256 | 4 | 12 | 8 |
| 200 | 8 | 512 | 8 | 24 | 16 |
| 400 | 16 | 1024 | 16 | 48 | 32 |

`RATE` 决定类型和宽度，运行中不能从 100 切换为 400。线上的实际吞吐还取决于时钟、
ready、RX valid 与报文间隙。负载百分比是现有 driver 的间隙策略输入，不保证精确的
Gbps 或占空比；启用随机包间节流需同时设置 `TRAFFIC_LOAD_PCT < 100` 和 `RANDOM_LOAD=1`。

TX 的 `valid` 固定等于 ready 延后两拍，wrapper 没有可调延时参数。
TX valid 低时仍驱动并保持数据和边带；因此驱动使能基于角色和 interface 所有权，
不能像 APB 的 `psel` 示例那样以 valid 为条件输出 Z。RX 无 ready，valid 可独立插入气泡。

默认事务和接口字节均从目的 MAC 开始、到 payload 结束。开启前导时，driver 自动添加
`55×7 + D5`，monitor 移除前导。开启 FCS 时，driver 为 `fcs_present=0` 的事务补 CRC，
为 `fcs_present=1` 的事务保留已有 CRC；monitor 的 `frame_bytes` 会保留末尾四字节 FCS。
该选项仅配置 VIP 的行为，真实 MAC IP 的透传/FCS 设置也需与之匹配。

`OVERRIDE_DUT=1` 使用图片中的 `assign (supply1, supply0)`，可以覆盖通常为 strong 的原
连续 net 驱动。使用 0 时，应先让原驱动为 Z 或确保该方向没有其他驱动者；同强度相反值
会解析为 X。此方式需要解析型 net，不能直接接到被 `always_ff` 等过程赋值的变量上。
应绑定连接生产者与消费者的 wire，或先在 testbench 暴露对应 net；它不使用 force/release。

输出直接来自 interface 的 `drv_*` 代理，实际 DUT net 再单向读回 interface 公共引脚。
这样 monitor 能观察外部解析结果，包括冲突，而不会形成连续赋值反馈环路。
checker 也直接读取 DUT net。`ENABLE_CHECKER` 决定静态生成，运行中修改 cfg 字段不会
创建或删除它；同一链路有多个 wrapper 时可只开启一个 checker。

## 4. 启动 UVM 与取得 agent

把已有顶层的 `run_test()` 初始块改为等待所有 wrapper 初始化完成，整个仿真只调用一次。
这避免 module initial 与 UVM build 在 time-0 竞争，不依赖简单的 `#0` 延时：

```systemverilog
initial begin
  wait (u_dut.u_eth_bind.initialized);
  // 多个绑定实例时，等待所有实例的 initialized。
  run_test();
end
```

wrapper 发布三个类型化键：`eth0_agent`、`eth0_cfg`、`eth0_vif`，作用域覆盖
`uvm_test_top` 及其子组件。原 env 无需再次创建 agent，在 build 中取得句柄，
connect 中连接 monitor，run 中启动 sequence 即可：

```systemverilog
// 放在自己的 env/test class 中；RATE 必须与绑定实例完全相同。
eth_seg_agent#(400) eth0;

// build_phase 内：只获取句柄；其他 root agent 的 build 此时可能尚未执行。
if (!uvm_config_db#(eth_seg_agent#(400))::get(this, "", "eth0_agent", eth0))
  `uvm_fatal("ETH_BIND", "missing eth0_agent")

// connect_phase 内：此时 monitor、sequencer、driver 已构建完成。
// eth0.tx_monitor.item_collected_port.connect(sb.tx_export);
// eth0.rx_monitor.item_collected_port.connect(sb.rx_export);
```

本例层次是 `uvm_top.eth0` 与 `uvm_top.uvm_test_top.env` 并列。组件的
`get_full_name()` 返回 `eth0`，不是 `uvm_test_top.env.eth0`。
如果使用 virtual sequencer，可在 connect 中把 `eth0.sequencer` 交给现有 vseq。
角色、active/passive 和报文格式由绑定参数确定，避免在 build 后更改这些字段。

下面是 MAC 模式发送 RX 的 run task 示例；CLIENT 模式发送 TX 时，把计数改用
`tx_monitor.packets_seen`，并等待 TX reset：

```systemverilog
// 等待 reset 后送入 4 帧，再等待 monitor 的真实 EOP 完成；不能只等待 seq.start 返回。
task run_phase(uvm_phase phase);
  eth_seg_frame_seq seq;
  int unsigned target;
  phase.raise_objection(this);
  wait (eth0.cfg.vif.i_rx_rst_n);
  seq = eth_seg_frame_seq::type_id::create("seq");
  seq.frame_count = 4;
  seq.frame_length = 256;
  target = eth0.rx_monitor.packets_seen + seq.frame_count;
  fork : send_and_timeout
    begin
      seq.start(eth0.sequencer);
      wait (eth0.rx_monitor.packets_seen >= target);
    end
    begin
      #100us;
      `uvm_fatal("ETH_TIMEOUT", "RX packets did not complete")
    end
  join_any
  disable send_and_timeout;
  phase.drop_objection(this);
endtask
```

## 5. 编译与可运行示例

UVM 1.2 之外的源码顺序如下，include 路径至少包含 `src`、`rtl` 和 `seq_lib`：

```text
rtl/eth_seg_if.sv
src/eth_seg_types.sv
src/eth_seg_pkg.sv
checker/eth_seg_protocol_checker.sv
bind/eth_seg_bind_wrapper.sv
<自己的 test package、DUT、tb_top 和 bind 声明文件>
```

仓库中 `test/bind/tb_bind.sv` 是完整 HDL 示例，按 module 类型绑定 100/200/400 三个实例。
`test/bind/eth_seg_bind_test_pkg.sv` 展示取得 root agent、连接 monitor 和有界等待。
在 **10.11.10.53** 载入 VCS 环境后运行：

```bash
make bind-test SEED=7
```

日志为 `build/bind/logs/compile.log` 和 `build/bind/logs/bind_test.log`。
每个 RATE 分别发送 8 帧 TX 和 8 帧 RX，三个 agent 的六路 monitor 独立比较字节、FCS
格式及 EOP 边带，并逐拍比较全部 bound net 的读回值。100G 使用连续节奏、200G 周期
间歇、400G 随机节奏和包间节流；覆盖默认无前导/FCS、前导开启以及前导和 FCS 同时开启。
帧结束段固定在总线末段，empty 覆盖 0..7；这是 bind 集成验证，不代表所有驱动器边界的完整回归。

通过条件包括三个 `BIND_RATE_PASS`、`ETH_BIND_TEST_COMPLETE`、完整 UVM summary
及零 ERROR/FATAL，且没有 VCS 原生错误。测试壳不含真实厂商 MAC RTL，实际 DUT 的信号
名称、端口宽度和 IP 格式配置仍需按以上映射接好。

2026-10-30 已在 `10.11.10.53` 使用 VCS `W-2024.09-SP1` / UVM 1.2 验证：
bind 的 seed 7、19、41 均通过，每次同时测试 100/200/400G，UVM WARNING/ERROR/FATAL
均为 0；现有 smoke 的 seed 7 也通过。日志保存在本地 `results/bind/`（不纳入 Git）。
