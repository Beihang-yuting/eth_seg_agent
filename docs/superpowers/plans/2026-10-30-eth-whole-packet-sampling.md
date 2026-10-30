# Ethernet Whole-Packet Sampling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本项目建议在主会话执行代码任务，按上级 AGENTS.md 将 VCS 执行及日志分析交给 GPT-5.6-sol；代码设计、修复和最终审查由主会话完成。

**Goal:** 让 eth_base_seq 支持 Tcl 批量发包及完整 Ethernet 帧采样，供 RM 预测和 SCB 直接比较，并在 53 完成验证。

**Architecture:** 每个 agent 拥有非参数化 monitor_hub，接收双向 Monitor 已经组好的完整包，按方向和订阅者复制、缓存。非参数化 sequencer 转发采样接口，eth_base_seq 同时提供采样方法及唯一的 count 循环；AIP 仅覆写逐包生成和活动通知。RM、SCB 使用独立持久采样对象和独立线程。

**Tech Stack:** SystemVerilog、UVM 1.2、VCS、GNU Make、Python 3、net_packet、可选 aip_core/update。

**Spec:** [已确认的设计](../specs/2026-10-30-eth-whole-packet-sampling-design.md)。产品基线 `26abff6`，设计提交 `83838af`。

**执行记录：** 用户选择主会话实现与审查、测试代理在 53 执行 VCS。功能已实现，
最终快照回归、第二个随机种子、测试告警修正复测及提交检查均已通过。
按依赖合并了部分任务的提交和验证；hub 保留实现前红测，
bind/count 未分别运行实现前红测，下面明确记录这两处执行调整。实际证据以
[验证记录](../../development/sampling-validation.md) 为准。

## Global Constraints

- 直接扩展现有 `eth_base_seq`，不增加另一层公共 sequence 父类。
- 发包数量由 `count` 控制；不添加 `load_send_config()`。
- 保留 `packet_to_item()`、`send_packet()` 和显式 `seq.pkt` 用法。
- 参数在使用处读取；AIP 宏和 Tcl 命令注册留在可选集成 package 中。
- 继续支持 100/200/400G；公共事务、sequencer 和采样接口不带 RATE 参数。
- bind 继续只暴露 AGENT_NAME、RATE，顶层 env 不重复创建 bind 所拥有的 agent。
- 默认无前导码、无 Ethernet FCS；TX ready 延时保持两拍。
- 多个 IP 按完整 agent 名称隔离；`portid` 是同一方向的订阅者编号。
- 订阅队列默认容量为 1024 包，可在订阅时设置；溢出 fatal；每个订阅一个并发读取者。
- 所有普通 SV 文件使用 `.sv`；文件、类、函数和 task 的中文注释交代职责、生命周期及边界。
- 编译和仿真仅在 10.11.10.53 进行，执行前载入该主机 `~/.bashrc` 的 VCS/license 环境。
- 上传图片、PDF 和 goldenbench.tar.gz 保留为用户文件；不提交、不复制进仿真工程。

## 文件职责与执行顺序

| 文件 | 操作及职责 |
| --- | --- |
| `src/eth_seg_types.sv` | 增加按值传递的复位通知类型 |
| `src/eth_seg_monitor_hub.sv` | 新增订阅槽、深拷贝分发、阻塞读取、取消、复位和容量控制 |
| `src/eth_seg_pkg.sv` | hub 在 sequencer 前 include |
| `src/eth_seg_sequencer.sv` | hub 借用句柄、发送能力标记、采样转发 |
| `src/eth_seg_agent.sv` | active/passive 都创建 hub/sqr，连接 Monitor 和复位通知 |
| `src/eth_seg_tx_monitor.sv`、`src/eth_seg_rx_monitor.sv` | 同采样域发布复位状态，保留组包状态机 |
| `src/eth_net_packet_pkg.sv` | 显式 import eth_seg_types_pkg，提供公共采样参数类型 |
| `seq_lib/eth_base_seq.sv` | count、逐包生成入口、采样 API 和发送能力校验 |
| `src/eth_seg_scoreboard.sv` | write_before/write_after、显式复位清理和空输入保护 |
| `examples/aip/eth_net_packet_aip_pkg.sv` | 移除重复 count/body，覆写生成和活动通知 |
| `examples/aip/eth_seg_aip_pkg.sv` | 原始帧命令也明确拒绝 passive 发包 |
| `examples/sampling/eth_rm_scb_example_pkg.sv` | 新增 RM/SCB 采样、复位协调和结束控制示例 |
| `test/sampling/eth_seg_hub_test_pkg.sv`、`tb_hub.sv` | 新增不依赖 net_packet 的 hub/SCB 契约测试 |
| `test/sampling/eth_rm_scb_test_pkg.sv`、`tb_rm_scb.sv` | 新增整包预测链路、异步到达、复位恢复测试 |
| `test/bind/eth_seg_bind_test_pkg.sv` | 更新 passive 断言，验证真实绑定上的 sequencer 采样 |
| `test/net_packet/eth_net_packet_test_pkg.sv` | 验证 eth_base_seq 批量生成、重放、采样以及三速率四格式 |
| `test/net_packet/eth_net_packet_aip_test_pkg.sv`、`send.tcl` | 重复命令、多 IP 与持久订阅联测 |
| `Makefile` | 新增隔离构建目标，继续使用现有 check_log.py |
| `docs/integration/sampling.md` | 新增用户采样/RM/SCB 集成说明 |
| `docs/integration/net_packet.md`、`bind.md`、`README.md` | 更新批量发包、passive 查询和示例入口 |
| `docs/development/sampling-validation.md` | 实现验证后填写版本、命令、统计及证据 |

任务依赖：1 → 2 → 3；4 依赖 1；5 依赖 3；6 依赖 2、3、4；7 汇总全部验证。
每项先加入能区分正确/错误行为的检查，再实现，再在 53 验证。新 API 尚未存在时，
首次定向编译因缺少该 API 失败即可证明测试入口生效，不重复无意义的全量失败构建。

## Task 1：建立可取消的整包订阅缓存

**Files:** 新建 `src/eth_seg_monitor_hub.sv`、`test/sampling/eth_seg_hub_test_pkg.sv`、
`test/sampling/tb_hub.sv`；修改 `src/eth_seg_types.sv`、`src/eth_seg_pkg.sv`、`Makefile`。

**Interfaces:** 消费现有 eth_seg_seq_item/do_copy 和 eth_seg_dir_e；新增以下契约：

```systemverilog
// eth_seg_types_pkg：复位消息按值传递，没有借用对象的生命周期问题。
typedef struct {
  eth_seg_dir_e direction;
  bit asserted;
  int unsigned epoch;
} eth_seg_reset_notice_t;

// eth_seg_monitor_hub 的公开方法；声明体在相应 class 中实现。
function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0,
                        int unsigned depth = 1024);
task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                 input int unsigned portid = 0, input time timeout = 0);
function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
function int unsigned pending(eth_seg_dir_e dir, int unsigned portid = 0);
function bit is_idle();
function void write_sample_tx(eth_seg_seq_item item);
function void write_sample_rx(eth_seg_seq_item item);
function void write_sample_reset_tx(bit asserted);
function void write_sample_reset_rx(bit asserted);
```

四个 analysis_imp 后缀分别为 `_sample_tx`、`_sample_rx`、`_sample_reset_tx`、
`_sample_reset_rx`，端口名分别为 `sample_tx/sample_rx/reset_tx/reset_rx`。
输出 `uvm_analysis_port#(eth_seg_reset_notice_t) reset_ap`；`pending` 对不存在的订阅
报告配置错误，`is_idle` 汇总所有订阅槽。取消不存在的订阅是无副作用操作。

- [x] **Step 1：加入独立字节和对象隔离检查。** 在测试 build 创建 hub，run 使用
  以下输入，不通过 codec、driver 或被测 sequence 生成期望：

```systemverilog
eth_seg_seq_item source = new("source");
eth_seg_seq_item a, b;
source.direction = ETH_SEG_RX;
source.frame_bytes = new[60];
foreach (source.frame_bytes[i]) source.frame_bytes[i] = byte'(i + 17);
hub.subscribe(ETH_SEG_RX, 0, 2);
hub.subscribe(ETH_SEG_RX, 1, 2);
hub.write_sample_rx(source);
source.frame_bytes[0] = 0;
hub.mon_xaction(a, ETH_SEG_RX, 0, 100ns);
hub.mon_xaction(b, ETH_SEG_RX, 1, 100ns);
if (a == null || b == null) `uvm_fatal("HUB_TEST", "missing complete frame")
if (a == b || a == source || b == source ||
    a.frame_bytes.size() != 60 || b.frame_bytes.size() != 60)
  `uvm_fatal("HUB_TEST", "subscriber copies are not independent")
foreach (a.frame_bytes[i])
  if (a.frame_bytes[i] != byte'(i + 17) || b.frame_bytes[i] != byte'(i + 17))
    `uvm_fatal("HUB_TEST", "complete frame bytes changed")
a.frame_bytes[0] = 255;
if (b.frame_bytes[0] != 17) `uvm_fatal("HUB_TEST", "consumer modified another copy")
```

- [x] **Step 2：加入 Makefile 定向入口并在 53 首次运行。** 新目标 `hub-test` 转发到
  `hub-run BUILD=build/sampling_hub`；源码顺序为 interface、types、eth_seg_pkg、
  eth_seg_hub_test_pkg、tb_hub；top 为 tb_hub，完成标志 `ETH_HUB_TEST_COMPLETE`。
  在尚未实现 hub 时，`make hub-test SEED=7` 应因缺失类型/API 编译失败。

- [x] **Step 3：实现每个订阅独立的槽对象及广播。** 同文件内的内部类
  `eth_seg_subscription` 保存
  `eth_seg_seq_item frames[$]`、`int unsigned depth`、`bit active=1`、`process reader`。
  hub 使用 `slots[2][int unsigned]` 存槽句柄，方向枚举经校验后索引；取消时先设置 active=0，
  再清空并移除索引；重新订阅创建新槽。每个订阅逐一创建 item 并 copy 后入队：

```systemverilog
// 先校验方向、非空输入、订阅存在性以及槽容量；fatal 后必须显式 return。
eth_seg_seq_item copy = eth_seg_seq_item::type_id::create("sample_copy");
copy.copy(item);
slot.frames.push_back(copy);
```

  非法方向/深度/重复订阅报告 `ETH_SAMPLE_CFG`；无订阅读取报告
  `ETH_SAMPLE_SUB`；空发布输入报告 `ETH_SAMPLE_NULL`；容量溢出报告
  `ETH_SAMPLE_OVERFLOW` 并保持原队列不变。无订阅的合法发布不缓存。

- [x] **Step 4：实现等待、取消和读取进程清理。** 将调用者 process::self() 存入槽，
  对已有且未 FINISHED/KILLED 的 reader 报 `ETH_SAMPLE_READER`。每次唤醒后重新
  检查取消、队列和原截止时间，避免同一时刻复位删包后误报超时。以下内层等待放在
  独立子进程内，disable fork 只清理本次等待，不能杀死用户其它线程：

```systemverilog
time started, remaining;
tr = null;
started = $time;
forever begin
  if (!slot.active) begin
    slot.reader = null;
    return;
  end
  if (slot.frames.size() != 0) begin
    tr = slot.frames.pop_front();
    slot.reader = null;
    return;
  end
  if (timeout != 0 && $time-started >= timeout) begin
    slot.reader = null;
    `uvm_error("ETH_SAMPLE_TIMEOUT", "no complete frame before timeout")
    return;
  end
  remaining = timeout == 0 ? 0 : timeout-($time-started);
  fork
    begin
      fork
        wait (!slot.active || slot.frames.size() != 0);
        begin
          if (timeout != 0) #(remaining);
          else wait (1'b0);
        end
      join_any
      disable fork;
    end
  join
end
```

  reader 赋值和校验在 fork 前完成；禁止定时轮询。核对 VCS 对队列 size 的 wait
  唤醒行为；必要时用“先检查条件再等待”的状态计数通知实现同一语义。

- [x] **Step 5：实现方向复位并完成负向测试。** hub 每方向保存已知状态、当前状态、
  epoch。首次通知同步状态；首次断言及后续断言边沿 epoch 加一，清空该方向队列，
  不删除订阅；释放时保留 epoch。重复状态不重复发布 reset_ap。
  hub 的状态更新/队列清理完成后才发布通知，避免回调看到旧数据。

```systemverilog
// 复位只清空 RX，等待中的 RX 读取继续等到新的整包。
hub.write_sample_rx(source);
hub.write_sample_reset_rx(1);
if (hub.pending(ETH_SEG_RX, 0) != 0)
  `uvm_fatal("HUB_TEST", "reset retained queued frame")
hub.write_sample_reset_rx(0);
fork
  hub.mon_xaction(a, ETH_SEG_RX, 0, 100ns);
  begin #10ns; hub.write_sample_rx(source); end
join
if (a == null) `uvm_fatal("HUB_TEST", "reader did not recover after reset")
```

  为 timeout/overflow/重复订阅/未订阅/并发读取分别安装仅匹配 ID、severity 的
  report catcher，核对每次恰好命中一次后移除；其它诊断不得屏蔽。
  另验证取消→立即重订阅时旧读者返回 null、新订阅保留新包；kill 正在等待的
  reader 后新线程能继续读取；空队列等待前已有包立即返回；两个 hub 相互隔离。
  将 source.aborted、CRC 和错误边带设置为非默认值后发布，核对完整事务的状态
  不被过滤或丢失。复位等待测试还须核对原始 timeout 截止时间不被复位重启。

- [x] **Step 6：53 运行并审查本任务。** `make hub-test SEED=7` 必须完整结束、
  所有精确负向计数符合预期、零意外 ERROR/FATAL。审阅完整新增文件及 include 顺序，
  记录定向结果；提交 `feat: add whole-packet monitor subscriptions`。

## Task 2：连接 Monitor、sequencer 和 passive agent

**Files:** 修改双向 Monitor、sequencer、agent 和 `test/bind/eth_seg_bind_test_pkg.sv`。

**Interfaces:** 消费 Task 1 的 hub 和 reset 入口；sequencer 提供
`eth_seg_monitor_hub monitor_hub`、`bit can_send=0`，并转发 subscribe、mon_xaction、
unsubscribe 三个同签名接口。Monitor 新增 `uvm_analysis_port#(bit) reset_state_port`，
1 代表复位断言。句柄缺失报告 `ETH_SAMPLE_HUB`。

- [x] **Step 1：修改 bind 的 passive 检查并加入实际整包采样。** 原检查中的
  `observer.sequencer != null` 改成检查其必须存在且 can_send=0；全部 driver
  必须仍为 null。在 end_of_elaboration 检查静态查询得到该 sequencer，订阅双向。

```systemverilog
if (observer.sequencer == null || observer.sequencer.can_send ||
    observer.tx_driver != null || observer.rx_driver != null ||
    observer.ready_driver != null)
  `uvm_fatal("BIND_ROLE", "passive must sample without drivers")
observer.sequencer.subscribe(ETH_SEG_TX, 0);
observer.sequencer.subscribe(ETH_SEG_RX, 0);
```

  使用现有 prepare_frames 的输入快照，分别消费 FRAME_COUNT 个 TX/RX 整包并逐字节
  核对；与现有六个 analysis sink 同时运行，不以两个被测路径互相比对代替独立期望。

- **Step 2（执行调整，未单独运行红测）：** 原计划在实现前运行 bind-test，
  预期缺少 API 或 passive sequencer 为空。实际在连接实现后首次运行，
  green2 和最终回归验证 passive 整包读取及无 driver；不声明存在独立 bind 红测。

- [x] **Step 3：实现始终存在的 hub/sqr 及连接。** build 创建双向 Monitor、hub 和
  sequencer，立即设置 sequencer.monitor_hub，供其它组件 connect 时安全借用；
  active 分支仍只创建角色对应 driver。connect 先连接 driver，再设置 can_send，
  双向 analysis 和复位端口连接如下，最后登记 static sqr：

```systemverilog
// 在 build_phase 创建两个组件后关联；不依赖其它组件 connect 的执行次序。
sequencer.monitor_hub = monitor_hub;
// 以下连接和登记在 connect_phase 完成。
tx_monitor.item_collected_port.connect(monitor_hub.sample_tx);
rx_monitor.item_collected_port.connect(monitor_hub.sample_rx);
tx_monitor.reset_state_port.connect(monitor_hub.reset_tx);
rx_monitor.reset_state_port.connect(monitor_hub.reset_rx);
sequencer.can_send = (tx_driver != null || rx_driver != null);
eth_seg_sequencer::register_sqr(get_full_name(), sequencer);
```

  不提前在 build 登记静态句柄。转发方法先校验 hub 非空，错误返回不再继续访问。
  `mon_xaction` 在任何失败路径先置输出 tr=null。

- [x] **Step 4：增加 Monitor 复位通知。** 在各自 clocking block 唤醒后、原有复位
  和 valid 判断之前，首次采样及状态变化时写 reset_state_port。通知条件和现有
  低有效复位判定一致，不修改 ready 历史、segment 算法、无效拍或格式解码。
  每个 Monitor 只通知自己的方向，不从 TX 线程推断 RX 状态。

- [x] **Step 5：运行绑定和时序定向检查。** 53 执行 `make bind-test SEED=7`、
  `make timing-test SEED=7`；确保三速率 passive 实际取包、双向 payload 和边带正确，
  active driver 所有权及 ready 两拍关系保持。审阅完整触及文件后提交
  `feat: expose monitor sampling on active and passive sequencers`。

## Task 3：扩展 eth_base_seq 的采样和批量 body

**Files:** 修改 `seq_lib/eth_base_seq.sv`、`src/eth_net_packet_pkg.sv`、
`test/net_packet/eth_net_packet_test_pkg.sv`。

**Interfaces:** 消费 Task 2 的 can_send/monitor_hub 和转发接口；产生以下覆写入口：

```systemverilog
int count = 1;
protected function eth_seg_sequencer require_sqr(bit sending = 0);
virtual function net_packet_pkg::packet create_packet(int unsigned packet_index);
virtual function void packet_queued(int unsigned packet_index);
```

`require_sqr` 检查类型及空句柄，sending=1 时要求 can_send；分别使用
`ETH_NET_SQR`、`ETH_NET_PASSIVE`。默认 packet_queued 无副作用。公共采样方法
与 Task 1 完全相同，先 require_sqr(0)，再调用 sequencer 方法。

- [x] **Step 1：加入批量与采样测试。** 在原三速率四格式 case 中创建持久采样 seq，
  通过 set_sequencer 关联对端，订阅后才启动流量。既有 8 TX+8 RX 内容检查保留。
  新增显式 pkt/count=3、无 pkt/count=3，以及逐包不同 MAC 的派生生成器：

```systemverilog
// 测试子类只覆写生成，不另写 body/count；协议字段变化后必须重新打包。
virtual function packet create_packet(int unsigned packet_index);
  packet p = super.create_packet(packet_index);
  eth_header header = p.get_eth();
  header.dst_mac = 48'h123456780000 + packet_index;
  p.do_pack();
  return p;
endfunction
```

  接收端检查三帧目的 MAC 分别为 0x123456780000、1、2，且调用方 seq.pkt 仍为空。
  显式 pkt 包含手动改过的 raw_data，三次发送必须保持这些字节不被重新生成。
  检查 count=0、负数、wrong/null sqr、passive、create_packet 返回 null 的报告和无发包。
  为 400G 连续满负载增加 32 个 14B Ethernet 头短包的批次，核对 Monitor 的
  same_cycle_boundaries 增量大于零且订阅按线序返回全部 32 包。其它 case 保留
  跨周期长包、周期和随机 ready/valid、固定及随机负载；记录实际命中的节奏场景。

- **Step 2（执行调整，未单独运行红测）：** 批量测试在实现后首次运行，
  green3 两种子及最终回归验证逐字节期望和 count/type/passive/生成器负向诊断；
  不声明存在独立 count 红测。所有阻塞调用仍有整体仿真超时保护。

- [x] **Step 3：实现默认生成器和唯一批量循环。** create_packet 每次 new 独立 packet，
  构造 ETH_IPV4_UDP、pkt_len=256、PAYLOAD_FIXED、payload_fixed_val=0xa5，再 do_pack。
  body 的控制结构如下；所有新函数/task 前添加中文契约说明：

```systemverilog
virtual task body();
  if (require_sqr(1) == null) return;
  if (count <= 0) begin
    `uvm_fatal("ETH_NET_COUNT", "count must be positive")
    return;
  end
  for (int n = 0; n < count; n++) begin
    net_packet_pkg::packet current_packet;
    current_packet = (pkt != null) ? pkt : create_packet(n);
    if (current_packet == null) begin
      `uvm_fatal("ETH_NET_NULL", "packet generator returned null")
      return;
    end
    send_packet(current_packet);
    packet_queued(n);
  end
endtask
```

  send_packet 也校验 require_sqr(1)，覆盖用户派生 body 直接调用的路径。
  packet_to_item 保留现有 raw_data 权威、空输入错误与复制语义。
  类型 package 显式 import eth_seg_types_pkg，不能假定 import 会被其它 package 转导出。
  负向测试捕获 fatal 后，错误路径必须显式返回，禁止进入 item 握手或继续访空。

- [x] **Step 4：实现采样转发，并证明采样不会误发包。** 示例采样对象只
  set_sequencer、subscribe、mon_xaction；记录前后 driver 计数无增加。
  无额外 sequence 父类、无 load_send_config、无 AIP import。

- [x] **Step 5：53 验证三速率四格式及转换边界。** 默认返回不含前导/FCS，FCS
  开启时采样保留尾四字节和状态，短包、VLAN、RoCEv2 ICRC 等原覆盖继续通过。
  审阅完整文件后提交 `feat: add batch sending and whole-packet sampling to eth_base_seq`。

## Task 4：提供 SCB 直接写入及复位清理

**Files:** 修改 `src/eth_seg_scoreboard.sv`、`test/sampling/eth_seg_hub_test_pkg.sv`。

**Interfaces:** 新增 `function void write_before(eth_seg_seq_item item)`、
`function void write_after(eth_seg_seq_item item)`、
`function void flush_direction(eth_seg_dir_e dir)`；前两者使用原 TX 队列。
清理仅删除指定方向的 expected/actual 队列，matched/mismatch 累计统计不清零。

- [x] **Step 1：加入 arrival-order、复制和 reset 检查。** 测试中在 build 创建 sb，
  使用 Task 1 的独立字节对象；检查实际先到也能在期望到达后比较：

```systemverilog
eth_seg_seq_item expected = new("expected");
expected.copy(source);
sb.write_after(source);
source.frame_bytes[0] ^= 8'hff;
sb.write_before(expected);
if (sb.matched_tx != 1 || !sb.is_idle())
  `uvm_fatal("SB_API_TEST", "actual-first or copy ownership failed")
sb.write_before(expected);
sb.flush_direction(ETH_SEG_TX);
if (!sb.is_idle() || sb.matched_tx != 1)
  `uvm_fatal("SB_API_TEST", "flush changed counters or retained items")
```

- [x] **Step 2：实现 wrappers、校验及清理。** wrappers 调用 write_expect_tx/
  write_actual_tx；四个原入口均拒绝 null，报告 `ETH_SEG_SB_NULL` 后返回。
  flush_direction 用 case 选择 TX/RX 两个 FIFO；其它值报 `ETH_SEG_SB_DIR`。
  不修改现有匹配规则，也不因为 actual 先到就报告 mismatch。

```systemverilog
function void write_before(eth_seg_seq_item item);
  write_expect_tx(item);
endfunction
function void write_after(eth_seg_seq_item item);
  write_actual_tx(item);
endfunction
```

- [x] **Step 3：完成定向验证。** 53 运行 `make hub-test SEED=7`；补充期望先到、
  修改实际字节产生 `ETH_SEG_SB_TX`、check_phase 剩余产生
  `ETH_SEG_SB_TX_REMAINDER` 的精确负向测试；验证 flush TX 不删除 RX 队列。
  验证后提交 `feat: add direct scoreboard input and explicit reset cleanup`。

## Task 5：精简 AIP 适配并验证命令生命周期

**Files:** 修改两个 `examples/aip/*.sv` 及原 net_packet AIP 测试 package/send.tcl。

**Interfaces:** 使用 Task 3 的 inherited count、create_packet、packet_queued；保留
四个 ethN_net_send 命令名称和 `aip_cmd_seq` 注册方式。

- [x] **Step 1：扩展持久采样测试。** AIP test 为每个 agent 建一个长期采样 seq，
  end_of_elaboration 注册，运行时消费 TX 整包；Tcl 第一次 count=2，改参数后第二次
  count=1，验证该订阅累计收到三包，且其它 IP 各自数量和内容正确。
  原独立 eth_net_sink 继续比较，两个观测消费者不能共享可变事务。

- [x] **Step 2：把原 body 的逐包构造改成 create_packet。** 使用局部 packet p、
  require_sqr(1) 得到实际 agent 参数前缀；长度、模板及协议字段继续在每次构造时读取：

```systemverilog
p = new();
p.build_from_template(ETH_IPV4_UDP);
p.pkt_len = 256;
p.load_params(param_path);
`aip_int(param_path, byte unsigned, payload_byte, 8'ha5)
p.payload_mode = PAYLOAD_FIXED;
p.payload_fixed_val = payload_byte;
if (p.pkt_len < 14 || p.pkt_len > 16384 ||
    p.pkt_len < p.get_all_headers_length() + p.get_all_trailers_length()) begin
  `uvm_fatal("ETH_NET_AIP_LENGTH", "invalid packet length")
  return null;
end
p.do_pack();
return p;
```

  删去子类 count 和 body。覆写 `packet_queued(int unsigned packet_index)`，函数体
  调用 `aip_activity::tick()`。不新增解析任意命令参数的代码。

- [x] **Step 3：保护原始帧 Tcl 入口。** eth_seg_aip_frame_seq 在 `$cast` 成功后检查
  sqr_handle.can_send；passive 报 `ETH_AIP_PASSIVE` 并 return。其原 count 循环保留，
  因为它继承的是 eth_seg_base_seq，不是 eth_base_seq。原错误路径补显式返回。

- [x] **Step 4：在 53 运行真实 UCLI。**

```bash
make net-packet-aip-test NET_PACKET="$ETH_NET_DEP" AIP_CORE="$ETH_AIP_DEP" SEED=7
make aip-test AIP_CORE="$ETH_AIP_DEP" SEED=7
```

  核对四个 IP、重复命令、长度/MAC/payload 变更、继承 count 和长期订阅数量；
  每条 Tcl 命令继续检查 ack/status。命令返回后等待 driver、Monitor、采样消费者
  全部完成再结束 test。审阅后提交 `refactor: reuse base batch loop in AIP packet commands`。

## Task 6：提供可运行 RM/SCB 采样集成示例

**Files:** 新建 `examples/sampling/eth_rm_scb_example_pkg.sv`、
`test/sampling/eth_rm_scb_test_pkg.sv`、`test/sampling/tb_rm_scb.sv`、
`docs/integration/sampling.md`；修改 Makefile、net_packet/bind 文档及 README。

**Interfaces:** 示例组件 `eth_rm_scb_example` 拥有 sb、rm_seq、scb_seq 和工作进程；
`string agent_name` 指定既有 MAC agent。生产方法
`virtual task model_predict(input eth_seg_seq_item input_pkt, output eth_seg_seq_item expected_pkt)`
缺省 deep copy 输入并设置 direction=ETH_SEG_TX；业务派生类可覆写。
示例 `bit sampling_ready` 通知 test 已完成订阅，`int unsigned predictions/outputs`
累计本次有效批次处理量。目标出口以 TX 表示，订阅 ID 使用 0。
复位协调另保存 `bit subscribed`、`bit reset_seen[2]` 和
`bit reset_asserted[2]`；首次观察到两个方向的状态后才允许启动工作进程。

- [x] **Step 1：构造独立刺激测试。** HDL 测试提供 100/200/400 三条 link，MAC agent
  产生 DUT 入口，测试专用 CLIENT agent 按预先构造的输出字节脚本产生出口。
  它是演示用刺激模型，不作为用户 DUT 正确性的证明；expected 只来自采样 RX 的 RM。
  独立输出脚本与输入 packet 快照对应，禁止从 hub 或 RM 的结果反向生成 actual。
  顶层复位可由测试控制；pin checker 继续检查接口时序。

- [x] **Step 2：实现查找和初始化。** 示例 build 只创建自身 sb 和两个采样对象。
  connect 用 `uvm_root::get().find({agent_name, ".sequencer"})` cast 成非参数化 sqr，
  连接 sqr.monitor_hub.reset_ap 到示例的 reset analysis_imp；此时所有组件已 build，
  不依赖兄弟 agent 的静态表登记顺序。end_of_elaboration 再核对 get_sqr 返回同一对象，
  两个采样 seq.set_sequencer(sqr)，在发包前注册 RX/TX。错误名字立即 fatal。

- [x] **Step 3：实现两条独立消费线程。** 以下线程属于示例工作进程，采样对象
  不调用 start；预测延时可由 task 覆写，以验证 actual-first：

```systemverilog
fork
  forever begin
    eth_seg_seq_item input_pkt, expected_pkt;
    rm_seq.mon_xaction(input_pkt, ETH_SEG_RX, 0);
    if (input_pkt == null) break;
    model_predict(input_pkt, expected_pkt);
    if (expected_pkt != null) begin
      sb.write_before(expected_pkt);
      predictions++;
    end
  end
  forever begin
    eth_seg_seq_item actual_pkt;
    scb_seq.mon_xaction(actual_pkt, ETH_SEG_TX, 0);
    if (actual_pkt == null) break;
    sb.write_after(actual_pkt);
    outputs++;
  end
join
```

  保存工作进程句柄，两个循环为该进程的子进程；SCB 比较累计数由 test 根据当前
  epoch 的基准计算，不能每次复位清除全部历史统计。

- [x] **Step 4：实现示例的整条链路复位协调。** reset analysis 回调是 function，
  只更新状态、kill 工作进程、取消两个订阅、flush TX 比较队列；禁止在回调中 wait。
  RX 或 TX 任一方向断言都执行该链路清理。释放后，run 中协调线程等两个方向
  状态都已知且都非复位，只在 subscribed=0 时注册，再创建新的工作进程并置
  sampling_ready。每次断言立即清除 ready；回调取消订阅后设置 subscribed=0。
  end_of_elaboration 的首次注册设置 subscribed=1，避免无初始复位的环境重复注册。

```systemverilog
// 位于复位通知回调的断言分支；worker 是 process 句柄，两个采样任务归它所有。
sampling_ready = 0;
if (worker != null) worker.kill();
rm_seq.unsubscribe(ETH_SEG_RX, 0);
scb_seq.unsubscribe(ETH_SEG_TX, 0);
sb.flush_direction(ETH_SEG_TX);
subscribed = 0;
```

  hub 自身的按方向清理仍保留订阅；示例显式取消双向是用户层选择的“整链路在途包
  全部丢弃”策略。test 必须等待 sampling_ready 才启动新批次，以免重订阅前丢观察包。
  此处 ready 是示例运行期采样状态，不是 bind time-zero 初始化标记。

- [x] **Step 5：加入可判错的场景与终止条件。** 一个场景先输出后完成 RM 预测，
  一个场景先预测后输出；故意改一个出口字节须捕获一次 ETH_SEG_SB_TX。
  复位场景先让 RM 持有一个等待中的输入、hub 留一个完整包、Monitor 留半包，再
  断言复位，释放后发送内容明显不同的新批次，核对不存在跨 epoch 比较。
  完成条件要求预期包数、matched 差值、driver/Monitor idle、hub pending=0、
  RM 无在途预测、sb.is_idle，并设置 100us 整体超时。

- [x] **Step 6：53 验证并完成用户文档。** 新目标 `sampling-test` 转发到
  `sampling-run BUILD=build/sampling`，沿用 NET_SRC/NET_INC 并编译示例和测试，
  top=tb_rm_scb，完成标志 `ETH_SAMPLING_TEST_COMPLETE`。运行：

```bash
make sampling-test NET_PACKET="$ETH_NET_DEP" SEED=7
```

  文档包含 seq.pkt/count、create_packet 覆写、set_sequencer 采样用法、portid 含义、
  先订阅后发包、默认/FCS 格式、null 返回、取消和复位、passive 查询变化、多个 IP
  独立 sb，以及发包完成/物理排空区别。删除旧示例中重复声明 count 的用法。
  明确 Tcl 支持 `set_param` 配合 count，未扩展任意命令字段解析。
  完整审阅后提交 `feat: add RM and scoreboard whole-packet sampling example`。

## Task 7：远程回归、证据和最终审查

**Files:** 新建 `docs/development/sampling-validation.md`；日志放在忽略目录
`results/sampling_validation/`。不创建包含登录凭据的脚本。

- [x] **Step 1：准备干净的远程运行目录。** 在 53 新建本任务目录，仅同步 tracked
  源码和本次明确新增的实现文件。使用已有依赖并记录 git rev-parse HEAD：

```bash
export ETH_NET_DEP=/home/ubuntu/ryan/eth_sgment_runs/net-packet-base-seq-b8a4c146/net_packet
export ETH_AIP_DEP=/home/ubuntu/ryan/eth_sgment_runs/aip-core-update-cd339ef
```

  预期 net_packet=b8a4c1469511159a59d1a547ed0b5fe896a68e5e，
  aip_core=cd339eff8d4b0982be885a0a71f3e593a4aed239；不同则记录并调查，不能偷偷替换依赖。
  本任务执行所有 VCS 命令前使用加载了 ~/.bashrc 的 bash，确认 vcs 和 license 可用。

- [x] **Step 2：完成尚未覆盖的回归。** 任务内已在最终相同源码上通过的定向测试
  直接复用日志；源码再次变动时只重跑受影响目标。命令清单如下：

```bash
make hub-test SEED=7
make sampling-test NET_PACKET="$ETH_NET_DEP" SEED=7
make net-packet-test NET_PACKET="$ETH_NET_DEP" SEED=7
make net-packet-test NET_PACKET="$ETH_NET_DEP" SEED=19
make bind-test SEED=7
make aip-test AIP_CORE="$ETH_AIP_DEP" SEED=7
make net-packet-aip-test NET_PACKET="$ETH_NET_DEP" AIP_CORE="$ETH_AIP_DEP" SEED=7
make run RATE=100 BUILD=build/sampling_smoke SEED=7
make timing-test SEED=7
make timing-checker-test
```

  smoke 本身同时包含三速率，不以 RATE 标签重复编译三次充当新覆盖。
  net_packet 两个种子验证随机节奏下的新增采样路径。timing-checker 按现有七个
  精确场景判定。每个目标都检查完成标志、完整 summary 和意外错误数。

- [x] **Step 3：核对设计覆盖并记录证据。** 汇总实际用例数、各方向收包数、
  subscribed/consumed/reset-discard/overflow 等测试统计；对照设计第 7 节逐项列出
  证据目标。统计从日志读取，不能预先填入计划中的期望值作为实际结果。
  文档记下源码提交/快照、依赖、VCS 版本、种子、命令、失败修复及最终日志路径。

- [x] **Step 4：完整技术审查并提交。** 主会话检查涉及目录内的源码全文与示例，
  包括未直接修改但与本次数据流相连的 driver、codec、env：
  对象复制、读者进程死亡、取消后的旧槽、复位通知顺序、跨方向清理、body/count
  继承、raw_data 更新、passive 无驱动和准确中文注释。运行 `git diff --check`，
  确认无上传文件或构建产物被暂存；提交验证文档和必要修复。当前步骤完成的是
  本地交付及 53 验证，远程发布按用户指令处理。

## 设计覆盖自审

| 设计验收项 | 落实任务 |
| --- | --- |
| 三速率、整包、同拍边界、节奏与格式 | 2 的 bind 采样，3 的十二格式组合/满速短包，7 的回归 |
| 独立订阅、对象复制、无历史回放、多 IP | 1 的 hub 契约，5 的四 IP Tcl |
| 等待、超时、溢出、取消和读取进程终止 | 1 的定向边界及精确负向测试 |
| 半包/缓存/已取包的复位处理 | 1 的方向清理，2 的 Monitor 通知，6 的整链路协调 |
| passive 采样、发送拒绝、静态表隔离 | 2 的真实 bind，3 和 5 的发送入口校验 |
| 批量计数、重放、新包生成、重复命令和改参 | 3 的 body/generator，5 的 UCLI |
| SCB 两种到达顺序、复制、残留和错误检测 | 4 的直接写入测试，6 的延时预测链路 |
| 原 smoke/bind/net_packet/AIP/timing/checker | 7 的命令与实际日志核对 |

## 实施方式选择

用户已选择在当前会话实施：主会话写代码及审查，沿用已有测试代理完成 53
上的 VCS 验证，遵守 AGENTS.md 的模型分工。交付保留在当前功能分支，
远程发布按用户后续指令处理。
