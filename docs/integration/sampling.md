# 通过 eth_base_seq 采样整包并接入 RM/SCB

`mon_xaction()` 每次返回一个完整 Ethernet 帧。TX/RX Monitor 负责从 SOP 到 EOP
重建字节，RM 可以直接解析 `eth_seg_seq_item.frame_bytes`，不需要处理 segment。

默认返回目的 MAC 到 payload 的字节，包含线上实际 padding。开启前导码时 Monitor
验证并移除前导；开启 FCS 时沿用原事务格式，尾部四字节保留在 frame_bytes，
通过 `fcs_present/fcs_checked/fcs_ok/fcs` 判断。CRC 错误、EOP 错误边带仍可采样；
到 EOP 的格式错误帧保留 `aborted`，复位打断的半包不发布。

## 最小用法

在 UVM connect 完成后、发包前执行初始化。`portid` 是消费者编号：同一 agent、
同一方向需要两份独立数据时使用不同编号；TX 的 0 和 RX 的 0 是两个独立订阅。

```systemverilog
import eth_seg_types_pkg::*;
import eth_seg_pkg::*;
import eth_net_packet_pkg::*;

eth_base_seq sample_seq = new("sample_seq");
eth_seg_sequencer sqr = eth_seg_sequencer::get_sqr("eth0");

// 采样对象只关联 sequencer，不调用会执行默认发包 body 的 start()。
sample_seq.set_sequencer(sqr);
sample_seq.subscribe(ETH_SEG_RX, 0);
```

在 RM 的运行线程中取完整包：

```systemverilog
forever begin
  eth_seg_seq_item input_pkt;
  sample_seq.mon_xaction(input_pkt, ETH_SEG_RX, 0, 10us);
  if (input_pkt == null) break;
  // input_pkt.frame_bytes 已是整包，可直接交给业务解析和预测。
end
```

方法声明：

```systemverilog
function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0,
                        int unsigned depth = 1024);
task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                 input int unsigned portid = 0, input time timeout = 0);
function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
```

| 情况 | 行为 |
| --- | --- |
| 队列有包 | 立即移交队首整包，不增加固定周期等待 |
| 队列空，timeout=0 | 阻塞到完整包或取消订阅 |
| 非零 timeout 到期 | 返回 null，报告 ETH_SAMPLE_TIMEOUT / UVM_ERROR |
| 取消订阅 | 清空该队列，等待者返回 null；重复取消无副作用 |
| 取消后重建同编号 | 建立新队列，旧等待者不会取走新队列的数据 |
| 多订阅者 | 每个订阅者有独立事务及字节数组 |
| 同订阅并发读取 | ETH_SAMPLE_READER / UVM_FATAL；改用不同 portid |
| 读者线程被 kill | 后续读者可继续使用原订阅，不会永久占用 |
| 队列容量用完 | ETH_SAMPLE_OVERFLOW / UVM_FATAL，不静默丢包 |
| 未订阅读取/重复订阅 | 配置 fatal，不隐式建立或清空队列 |

必须先订阅再发包；未订阅时不保存历史数据。阻塞只影响调用线程，Monitor 持续
接收并向订阅队列入包。需要查积压时使用 `sqr.monitor_hub.pending(dir, portid)`。

## RM 和 SCB 的连接

针对 MAC 角色模拟入口的报文处理 DUT，方向关系如下：

```text
RX driver → o_rx_mac_* → DUT 入口 → RX Monitor → RM → sb.write_before(expected)
DUT 出口 → i_tx_mac_* → TX Monitor → 采样线程 → sb.write_after(actual)
```

RM 和 SCB 各自持有长期 `eth_base_seq` 对象，并行调用 RX/TX 的 mon_xaction。
同一个 scoreboard 的 `write_before()`、`write_after()` 分别写入 TX expected/actual
队列，内部深拷贝，支持任意一方先到。两个方法均为 `function void`；调用返回时
另一侧可能还没有包，因此不返回“立即匹配成功”。

业务期望来自 RM 时，勿再将 driver.sent_ap 接入同一个 expected 队列。
当前比较按出口包序进行；多出口各用独立 SCB，乱序输出需要业务层增加匹配键。
RM 预期丢包时不写 expected，预期复制时按出口顺序写入多个 expected。

完整可运行组件位于
[`eth_rm_scb_example_pkg.sv`](../../examples/sampling/eth_rm_scb_example_pkg.sv)。
它仅创建 RM/SCB 所需对象，借用既有 agent，不重复创建 bind agent。
在环境 build 中创建组件即可：

```systemverilog
eth_rm_scb_example rm_scb;

// 放在 env.build_phase 中；先 import eth_rm_scb_example_pkg::*。
rm_scb = eth_rm_scb_example::type_id::create("rm_scb", this);
rm_scb.agent_name = "eth0";
```

默认 `model_predict()` 做字节透传。用户派生该组件并覆写这个 task，实现业务协议
解析、修改和预测；返回 null 表示预期丢弃。需要复制多个包的模型可自行编写采样
消费线程，按上述公共接口向 SCB 写多包。该示例的单返回值模型用于一进一出/丢包。

四个 IP 分别创建四个组件，设置 eth0/eth1/eth2/eth3；即使都是 100G，也拥有独立
sequencer、队列和 scoreboard。采样对象无需 RATE 参数。passive agent 也能通过
get_sqr 查到 sequencer 并采样，但 can_send=0，公共发包入口明确拒绝发送。

## 复位和测试结束

hub 按各自 Monitor 的时钟观察复位，清空对应方向队列，保留订阅。正在等待的
mon_xaction 继续等复位后的包，原 timeout 不重计。已经取走的包归 RM，hub 无法撤回。

`sqr.monitor_hub.reset_ap` 发布按值传递的 `eth_seg_reset_notice_t`，包含 direction、
asserted、epoch。首次采样同步状态，后续状态变化才通知，epoch 在每次断言时递增。
用户环境据此决定如何终止旧预测和调用 `sb.flush_direction(ETH_SEG_TX)`；清理不
重置累计匹配/错误统计。analysis 连接在 connect_phase 完成；在兄弟 agent 尚未
登记静态表时，可按完整路径查找已在 build 创建的 sequencer，参考示例实现。

示例采用“任一方向复位，整条链路在途数据全部丢弃”的策略：立即停止两个消费
线程、取消双向订阅、清理 TX 比较队列，等待两方向释放后重新订阅。
test 等待 `rm_scb.sampling_ready` 再启动新流量。这个状态用于运行期复位协调；
bind 的 time-zero 创建方式仍为 `#0; run_test()`。

结束测试前，持有 objection 并核对预期收包数、匹配数、driver/Monitor 空闲、
订阅队列排空、RM 无在途预测、SCB 无残留。仅调用 seq.start 或仅观察 is_idle
不足以证明没有丢包。通过后可调用示例的 stop_sampling，再释放 objection。

## 编译和验证

依次编译 net_packet_pkg、interface、eth_seg_types_pkg、eth_seg_pkg、
eth_net_packet_pkg，再编译示例 package 和用户环境。采样组件本身不依赖 AIP；
不用 net_packet 时，也可直接调用 `eth_seg_sequencer` 的三个同名采样接口。

在 53 的 VCS 环境运行：

```bash
make hub-test SEED=7
make sampling-test NET_PACKET=/path/to/net_packet SEED=7
make net-packet-test NET_PACKET=/path/to/net_packet SEED=7
```

sampling-test 用两端独立刺激源模拟 DUT 引脚，验证三速率的整包预测、两种到达顺序、
错误数据和复位恢复；不包含用户 DUT。验证结果见
[采样验证记录](../development/sampling-validation.md)。
