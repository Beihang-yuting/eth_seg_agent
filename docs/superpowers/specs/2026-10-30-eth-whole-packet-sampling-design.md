# Ethernet 整包采样与批量发包设计

日期：2026-10-30。代码基线：`26abff6`。

状态：已按用户确认的设计完成实现，53 上定向验证及回归通过。具体快照、
测试计数和适用范围见 [采样验证记录](../../development/sampling-validation.md)。

## 1. 使用目标与约束

用户通过 Tcl 一次发送多个网络报文，RM 和 SCB 通过 `eth_base_seq` 的公共接口
取得接口上实际传输的完整 Ethernet 帧。RM 负责协议解析和业务预测，不承担
segment 拼接。SCB 接收 RM 的期望整包和 DUT 的实际出口整包并进行比较。

已确认的约束：

- 直接扩展现有 `eth_base_seq`，不增加另一层公共 sequence 父类。
- 发包数量由 `count` 控制；不添加 `load_send_config()`。
- 保留 `packet_to_item()`、`send_packet()` 和显式 `seq.pkt` 用法。
- 参数在使用处读取；AIP 宏和 Tcl 命令注册留在可选集成 package 中。
- 继续支持 100/200/400G；公共事务、sequencer 和采样接口不带 RATE 参数。
- bind 继续只暴露 AGENT_NAME、RATE，顶层 env 不重复创建 bind 所拥有的 agent。
- 默认无前导码、无 Ethernet FCS；TX ready 延时保持两拍。
- 多个 IP 按完整 agent 名称隔离；`portid` 是同一方向的订阅者编号。

本文补充的实现选择：订阅队列默认容量为 1024 包，可在订阅时设置；队列溢出
立即报 fatal；SCB 首版按每个出口的报文顺序比较。这些属于实现默认值，不增加
bind 参数。

## 2. 数据来源和整包契约

现有 TX/RX Monitor 已经跨时钟、跨 segment 保存当前帧，检测 EOP 后调用
codec 解码，并通过 `item_collected_port` 发布 `eth_seg_seq_item`。
继续复用该组包路径；采样 API 不读取 driver 的发送队列或 `sent_ap`。

```text
引脚有效传输 → TX/RX Monitor 组包 → agent 的 monitor_hub
                                      ├─ RX/订阅者 0 → RM
                                      ├─ TX/订阅者 0 → SCB
                                      └─ 其它订阅者 → 独立分析线程
```

每次成功的 `mon_xaction()` 返回一个完整 EOP 事务：

- `frame_bytes` 为整包字节，默认从目的 MAC 到 payload 末尾；线上 padding 保留。
- 前导码由现有 codec 验证并移除。
- 开启 FCS 时延续现有契约：`frame_bytes` 保留尾部四字节，
  `fcs_present/fcs_checked/fcs_ok/fcs` 描述 FCS。RM 必须按字段识别该格式。
- 保留 direction、起止时间、segment 位置、错误边带等现有字段。
- CRC 错误帧仍然是完整帧，可交给 RM 判断丢弃或转发行为。
- 到达 EOP 但格式错误的帧延续 Monitor 的报错和 `aborted` 标记，采样层不将其
  静默过滤；因复位未到达 EOP 的半包由 Monitor 丢弃，不发布正常事务。
- 同周期完成多个包时，按 Monitor 处理 segment 的顺序逐包发布。

这里的完整帧表示 Ethernet 层组包完成；IP 分片重组等业务处理仍属于 RM。

## 3. 组件、订阅和生命周期

新增非参数化 `eth_seg_monitor_hub`，由每个 agent 创建并拥有，与 Monitor 同寿命。
TX/RX analysis 输出连接到 hub 的独立入口，原有 analysis 连接继续可用。
hub 持有按 `(direction, portid)` 索引的订阅队列。

sequencer 持有 hub 的借用句柄并转发公共接口，不引用 `eth_seg_agent#(RATE)`。
`eth_base_seq` 检查 sequencer 类型后委托给该 sequencer。

公共接口如下，声明中的缺省值即使用契约：

```systemverilog
function void subscribe(
  input eth_seg_dir_e dir,
  input int unsigned portid = 0,
  input int unsigned depth = 1024);

task mon_xaction(
  output eth_seg_seq_item tr,
  input eth_seg_dir_e dir,
  input int unsigned portid = 0,
  input time timeout = 0);

function void unsubscribe(
  input eth_seg_dir_e dir,
  input int unsigned portid = 0);
```

订阅及阻塞行为：

1. 必须先订阅再发包。没有订阅者时不积累历史报文；后来订阅不会回放旧包。
2. 同一订阅重复注册视为配置错误；不允许悄悄清空原有队列。
3. 不同订阅者各获得深拷贝，修改一个返回对象不影响 Monitor 或其它订阅者。
4. 队列有包时立即移交队首对象；空队列等待下一包，无额外固定周期延迟。
5. `timeout=0` 表示无限等待；非零表示从本次调用开始计算的仿真时间。
   超时返回 `tr=null` 并报告 UVM_ERROR；临界点优先处理已经入队的包。
6. 队列达到 depth 后再入包报 UVM_FATAL，避免静默丢包；depth 必须大于零。
7. 同一订阅只允许一个等待中的读取者，重复并发读取立即报错。
   RM 和其它观察者需要独立副本时使用不同 portid。
8. unsubscribe 清空本订阅并唤醒等待者，等待者返回 null。
   删除后重新订阅相同编号时，原等待者不能消费新订阅的数据。
9. 正常取包后队列释放自身引用，返回对象由调用方持有。
10. 禁止类型错误、未订阅读取或空 hub 引用进入无限等待；这些属于配置 fatal。

实现需要使用状态条件配合通知，避免通知先于 wait 引发漏唤醒；读取者被 UVM
终止时也不能永久占用读取状态。为此保留当前读取进程句柄，后续访问核对其状态。

active 和 passive agent 都创建、登记 sequencer，passive 只提供采样服务。
sequencer 标记是否具有发送 driver。公共 `send_packet()`、默认发包 body 及
仓库 AIP 入口在发送前拒绝 passive，防止卡在无人响应的 item 握手。
直接自写底层 `start_item()` 的用户 sequence 仍须自行遵守 active 要求。

静态表在 connect 完成后可用，在 final 撤销登记。顶层 `#0` 仅协调 bind 创建，
不代表 sequencer 已经完成连接。新行为需更新原文档中 passive 查询返回 null 的说明。

## 4. 复位与结束条件

每个方向 Monitor 将观察到的复位状态通知 hub；状态来自与该方向数据一致的
采样时钟。每个方向在首次采样时同步状态，后续只在状态变化时通知。
hub 的复位通知须携带方向及递增的 reset epoch，供环境协调清理。

复位断言时只清空对应方向的订阅队列，保留订阅关系；Monitor 清除半包。
等待中的 `mon_xaction()` 继续等待复位后的新整包，已有 timeout 不重新计时。
unsubscribe 仍可取消该等待，避免将复位处理变成零时间重试循环。

已经返回给 RM 的对象不能从调用方撤回。提供 hub 的 reset analysis 通知和
SCB 的显式方向清理方法，由 test/RM 的复位协调线程停止旧预测、清理对应
expected/actual 队列，并在 DUT 相关复位解除后恢复处理。
具体 DUT 是否丢弃在途包由用户环境决定；hub 不自动修改其它组件的状态。
示例按“复位丢弃该链路全部在途包”处理，并验证不会用复位前期望匹配复位后实际包。

默认 body 返回及 `finish_item()` 完成只代表 driver 接收了事务副本。
测试结束须同时满足预期收包/比较数量、driver 和 Monitor 空闲、消费队列排空、
RM 无在途计算、SCB 无残留，并设置整体超时。仅检查空队列不能证明一包也未丢失。

## 5. eth_base_seq 批量发包与 Tcl

在 `eth_base_seq` 中增加 `int count = 1`，默认 body 校验 count>0 后执行唯一的
批量循环。保持 `packet_to_item()` 的权威 raw_data 与深拷贝行为。

- 显式 `seq.pkt != null`：重复发送该报文 count 次；非空 raw_data 保持原样。
  调用方修改协议字段后需先 repack，发送期间不得并发修改同一个 packet。
- `seq.pkt == null`：每轮调用可覆写的 `create_packet(packet_index)` 生成新对象。
  无 AIP 的缺省实现生成 256B IPv4/UDP、固定 payload 0xa5。
- 生成的本轮 packet 使用局部变量，不能赋给作为调用方输入的 `seq.pkt`，
  以免下一轮误判为显式报文路径。
- 可选 AIP 子类覆写生成入口，在每包构造处直接调用现有 `packet.load_params()`
  和 `aip_int`，按实际 agent 全名读取参数，再调用 do_pack。
- 提供每包入队后的可覆写通知，AIP 适配层在此执行既有 activity tick。
  子类移除重复 count 和 body 循环，避免变量遮蔽或发送 count² 个包。
- 多次 Tcl 命令各创建新 sequence；订阅缓存位于 agent 中，不受命令对象销毁影响。

不增加 `load_send_config()`，也不把 AIP 依赖引入基础 VIP。现有 `packet.load_params()`
属于 net_packet 的协议参数接口，继续在每包使用处调用。

沿用已经验证的 Tcl 语法：

```tcl
set_param path=eth0.pkt_len value=256
set_param path=eth0.payload_byte value=0x5a
eth0_net_send count=100
```

当前上游 `aip_cmd_seq` 自动解析 count/time，不自动把任意命令参数映射成同名
sequence 字段。因此本次不宣称支持 `eth0_net_send count=100 pkt_len=256`。
若要这种语法，需要另行扩展命令解析。参数每包读取一次，不缓存整批配置；批次中
显式更新参数会影响之后构造的包，不影响已入队副本。

AIP time 模式终止 sequence 后，driver 已接受的包仍需排空；不保证撤销已入队数据。

## 6. RM/SCB 集成方式

发送和采样使用同一 class 的不同对象。RM、SCB 创建持久 `eth_base_seq` 对象，
通过 `set_sequencer()` 关联后调用订阅/采样，不调用会执行发包 body 的 start。
订阅在 end_of_elaboration 或之后、流量启动前完成。

针对用户当前报文处理 DUT，agent 使用 MAC 角色：RX driver 驱动 DUT 入口，
RX Monitor 观察实际入口，TX Monitor 观察 DUT 出口。

```systemverilog
// 初始化时分别创建两个采样对象，关联已登记的同一 agent sequencer。
rm_seq.set_sequencer(sqr);
scb_seq.set_sequencer(sqr);
rm_seq.subscribe(ETH_SEG_RX, 0);
scb_seq.subscribe(ETH_SEG_TX, 0);

// 两个独立线程；取消订阅或超时的 null 返回不得送给 RM/SCB。
fork
  forever begin
    eth_seg_seq_item input_pkt, expected_pkt;
    rm_seq.mon_xaction(input_pkt, ETH_SEG_RX, 0);
    if (input_pkt == null) break;
    model_predict(input_pkt, expected_pkt);
    sb.write_before(expected_pkt);
  end
  forever begin
    eth_seg_seq_item actual_pkt;
    scb_seq.mon_xaction(actual_pkt, ETH_SEG_TX, 0);
    if (actual_pkt == null) break;
    sb.write_after(actual_pkt);
  end
join
```

上述代码只展示一进一出的数据流，完整示例另外包含复位、取消和结束控制。
若预测 DUT 丢包则不写 expected；复制包则按预期出口顺序写多个 expected。

在 `eth_seg_scoreboard` 中增加两个 `function void`：

- `write_before(eth_seg_seq_item item)` 转发到 `write_expect_tx()`。
- `write_after(eth_seg_seq_item item)` 转发到 `write_actual_tx()`。

它们沿用现有深拷贝、expected/actual 任意一方先到的队列比较机制；不返回“立即
匹配成功”状态，因为另一个方向的数据可能尚未到达。原 TX/RX analysis API 保留。
空句柄必须明确报错，不能触发对象访问异常。

业务预测时 expected 来源是 RM，不再将 driver.sent_ap 接入同一个 expected 队列。
现有 VIP 自测 env 继续使用原 driver/Monitor 比较连接。
多出口分别实例化 SCB 或明确路由到各出口队列；跨包乱序匹配不属于本次范围。

## 7. 文件范围与验证标准

主要范围：新增 monitor_hub；更新 sequencer、agent、package include 顺序和双向
Monitor 的复位通知；扩展 eth_base_seq 和 SCB；精简可选 AIP 子类；新增整包采样
集成示例与测试；更新 net_packet、bind 文档和 Makefile 测试入口。

在 10.11.10.53 使用 VCS 验证：

1. 三速率下 TX/RX 跨周期、跨 segment、同拍包边界、连续及间断 valid/ready、
   最大及随机负载，返回的整包内容、顺序和边带与独立期望一致。
2. 双订阅者各收完整包、消费者修改对象互不影响、无订阅不缓存、多 IP 不串包。
3. 队列立即返回、阻塞唤醒、超时、溢出、重复订阅、未订阅读取、并发读取，
   以及取消后重新订阅、读取进程终止后的再次读取。
4. 复位半包丢弃、已排队整包清除、订阅保留、等待跨复位恢复；业务 RM/SCB
   清理后不匹配复位前后的不同批次。
5. passive 能获取整包，公共发送入口明确拒绝；静态表仍按 agent 名称隔离。
6. count=1、多包、非法 count、显式 pkt 重放、逐包新建、重复 Tcl 命令、运行中
   改参；核对数量，排除双重循环与陈旧 raw_data。
7. SCB 实际先到/期望先到、直接写入深拷贝、残留检测及错误数据确实能报 mismatch。
8. 保留 smoke、bind、net_packet、普通 AIP、net_packet AIP、timing 与 checker 回归；
   net_packet 覆盖三速率乘四种前导/FCS 组合。

负向测试按精确报告 ID 和次数判定，其余测试要求零意外 UVM_ERROR/FATAL，
均须有明确完成标志和超时。完成后记录命令、依赖版本、日志及测试统计。
实现及实际验证证据以配套验证记录为准；这些测试不包含用户 DUT 或厂商 F-Tile RTL。
