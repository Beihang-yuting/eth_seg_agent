# 整包采样与批量发包验证记录

日期：2026-10-30。产品基线 `26abff6`，设计/计划提交 `83838af` / `1d7458e`。
本次交付扩展 eth_base_seq、agent 的整包订阅缓存及 SCB 直接写入接口，配套可运行
RM/SCB 示例。使用方法见 [采样集成](../integration/sampling.md) 和
[net_packet 集成](../integration/net_packet.md)。

## 环境与源码记录

所有 VCS 编译和运行均在 `10.11.10.53` 完成，执行前加载该主机 `~/.bashrc`。
VCS 为 `W-2024.09-SP1_Full64`，UVM 为 1.2。独立运行根目录：

```text
/home/ubuntu/ryan/eth_sgment_runs/whole-packet-sampling-20261030
```

外部依赖固定为：

| 依赖 | 提交 | 53 上的路径 |
| --- | --- | --- |
| net_packet | b8a4c1469511159a59d1a547ed0b5fe896a68e5e | /home/ubuntu/ryan/eth_sgment_runs/net-packet-base-seq-b8a4c146/net_packet |
| aip_core/update | cd339eff8d4b0982be885a0a71f3e593a4aed239 | /home/ubuntu/ryan/eth_sgment_runs/aip-core-update-cd339ef |

每轮使用不可变源码压缩包及独立目录；用户上传的图片、PDF、goldenbench.tar.gz
未加入仿真工程。压缩包和原始日志保存在本地忽略目录 `results/sampling_validation/`，
不提交构建产物或登录凭据。源码以快照 SHA256 关联验证结果：

| 快照 | SHA256 |
| --- | --- |
| core_green2.tar.gz | 37221b2a1177adaf09b2771c8e35353479435c3ba6735830711ad58314fa0113 |
| batch_green3.tar.gz | 645d4e65a19205ee76d9ce629472a74266ef2193cdd545a7d1d21ef900b50cb6 |
| rm_green4.tar.gz | 9eb4ec188434a501dd9855bc9953eb99c22e6ac8be8ae91a97230338d3d3638a |
| final_green5.tar.gz | 3445b3b74a8c753cc814356111609c58b90dee65d33ea6c01f7382c1fe345e6d |
| final_hub_green6.tar.gz | 2a4776536a68c5878e0f8fed2e2cdfa551d83dd9356a99bdbaaed960e4d1fc4d |

green5 是最终产品源码快照；green6 只将 hub 测试接收器的 write 形参名与 UVM
基类统一为 t，消除 SV-ANDNMD 编译告警，产品源码未变。green2 的普通 AIP 和
green4 的 smoke/timing/checker 结果复用：它们不调用本轮末次修改的阻塞采样方法，
正常静态登记路径未变；采样、bind、net_packet 和网络 AIP 路径在 green5 重新验证。
green5 完整日志另存 `green5_validation_logs.tar.gz`，SHA256 为
`f82a4609e015db6f122c802be40258847bc6532e1ccf8eeb7ad049e9a5375a0c`。

## 验证结果

green5 五个目标及 net_packet 第二个随机种子全部通过；green6 的 hub 告警修正复测通过。

实际回归证据：

| 目标 | 种子 | 已通过结果 | 日志（相对 results/sampling_validation） |
| --- | --- | --- | --- |
| hub-test | 7 | 110 项检查，14 次预期诊断（9 fatal、5 error），形参名告警已消除 | green6/logs/hub.log |
| sampling-test | 7 | 三速率合计 24 次匹配、3 次精确预期 mismatch；每速率丢弃一个半包并清理三类在途状态 | green5/build/sampling/logs/sampling.log |
| net-packet-test | 7、19 | 每种子 12 条链路、472 帧；13 次预期 fatal；analysis/seq 两条路径逐字节通过 | green5/build/net_packet/logs/net_packet_test.log、net_packet_seed19.log |
| bind-test | 7 | 四实例各 8 TX + 8 RX，每实例三组 Monitor 和 passive 采样通过，12 个独立 sqr | green5/build/bind/logs/bind_test.log |
| net-packet-aip-test | 7 | 四个 IP 分别 3/3/1/4 帧；Tcl 重复命令/改参及持久采样通过 | green5/build/net_packet_aip/logs/net_packet_aip_test.log |
| aip-test | 7 | 四个命名 IP 分别匹配 3/3/1/4 帧；真实 Tcl 命令及参数隔离 | green2/aip/aip_test.log |
| smoke | 7 | 同一仿真包含 100/200/400G；原格式、负载及错误帧自检通过 | green4/smoke/eth_seg_smoke_test.log |
| timing-test | 7 | 三速率 × 两种前导设置，共 6 个 fixture 完成全部阶段 | green4/timing/timing_all.log |
| timing-checker-test | 定向 | 7/7 场景按精确诊断通过 | green4/checker/*.log |

普通 UVM 回归要求完成标记、完整 summary 和零意外错误；上述 UVM 日志的最终
WARNING/ERROR/FATAL 均为 0。定向负向测试只捕获预期 ID/严重级别并核对次数。
checker 的四个非法输入场景各产生一个指定 VCS 原生 Error，另外三个合法场景零错误，
通过 `scripts/check_timing_checker.py` 判定，不能把这组日志描述为原生零错误。
hub 单元测试没有物理 interface 实例，编译时有 UII-L 提示；它只测试事务级逻辑，
该提示不影响测试。green5 其它四个目标的编译无 Warning/Error/Fatal。

## 覆盖与证据对应

| 设计契约 | 验证方法 |
| --- | --- |
| 完整 EOP、字节序、FCS/前导及错误边带 | net_packet 三速率四格式，analysis 与 seq 各自比对独立原始字节期望；bind 检查 EOP 边带 |
| 单拍多包、跨周期、连续/周期/随机节奏 | 400G 默认格式额外 32 短包/方向，断言同拍包边界出现；其它格式与 timing 覆盖气泡及负载 |
| 独立订阅、无历史回放、多 IP、深拷贝 | hub 双订阅改写隔离与双实例；bind 四链路；AIP 四 IP 独立命令/参数 |
| 超时、取消、重订阅、读者死亡、并发读取 | hub 阻塞读取、旧槽取消和重新使用同编号、kill 后接管、精确错误诊断 |
| 容量/错误配置 | hub 验证零容量、重复订阅、未订阅、空事务、溢出；错误后已有队列保持 |
| 复位与等待同时发生 | hub 同时入包/复位，等待下一包；跨复位保留原 20ns 截止时间；重复通知抑制及 epoch |
| 三层在途状态同时复位 | sampling-test 让 RM 持有旧包、hub 留整包、Monitor 留半包，再复位并验证新批次 |
| passive 与静态表 | bind 观察者无 driver 但可取包；发送入口拒绝 passive；hub 检查重复登记不能覆盖及按拥有者撤销 |
| count 与生成方式 | net_packet 每方向各 3 次显式快照重放、默认生成、按索引生成；错误生成/count/type 不进入握手 |
| Tcl 生命周期 | 网络 AIP 同端口两次命令、运行时改参；持久采样对象累计消费并核对字节 |
| SCB 到达顺序和判错能力 | hub 直接写入测试；sampling-test 实际先到/期望先到窗口断言、故意坏字节、残留检查及方向清理 |

hub 的检查次数含逐字节断言，并非相同数量的独立测试场景。各目标的完成条件除包数
之外还检查相关队列、driver/Monitor、RM 和 SCB 状态；不以 finish_item 或空队列单独判定。

## 复现命令

在 53 上加载 VCS 环境，并进入对应快照目录后：

```bash
export ETH_NET_DEP=/home/ubuntu/ryan/eth_sgment_runs/net-packet-base-seq-b8a4c146/net_packet
export ETH_AIP_DEP=/home/ubuntu/ryan/eth_sgment_runs/aip-core-update-cd339ef
make hub-test SEED=7
make sampling-test NET_PACKET="$ETH_NET_DEP" SEED=7
make net-packet-test NET_PACKET="$ETH_NET_DEP" SEED=7
build/net_packet/simv +ntb_random_seed=19 -l build/net_packet/logs/net_packet_seed19.log
python3 scripts/check_log.py build/net_packet/logs/net_packet_seed19.log run ETH_NET_TEST_COMPLETE
make bind-test SEED=7
make net-packet-aip-test NET_PACKET="$ETH_NET_DEP" AIP_CORE="$ETH_AIP_DEP" SEED=7
make aip-test AIP_CORE="$ETH_AIP_DEP" SEED=7
make run RATE=100 BUILD=build/sampling_smoke SEED=7
make timing-test SEED=7
make timing-checker-test
```

第二个 net_packet 种子复用同一 simv，不重复编译；smoke 一次已包含三种速率。
Makefile 自动执行编译/运行日志检查，完整终端输出另保存在 green2～4 的 `console/`
及 green5～6 的 `validation_console/` 下。

## 开发过程中处理的问题与审查范围

首次 hub 红测因尚未定义 hub 类型而编译失败，证据在 `red/`。首次实现编译发现
测试 helper 的 check 名字与 UVM 基类冲突，改为 ensure；同时以显式完成位替代
对 process.status() 的 wait。green2 通过 93 项检查及 12 次精确预期诊断。
bind 和批量发送未分别保留实现前的红测快照，后续以独立字节期望、负向诊断及
完整传输计数验证，不将此记录伪称为所有目标均经历独立红绿过程。

最终审查增加了唤醒后重新检查队列的循环：刚入队的包可能在同一仿真时刻被复位
删除，此时继续等新包，使用剩余 timeout，避免提前误报超时。静态登记的 fatal
后增加显式 return，防止测试捕获 fatal 后继续覆盖旧表项。

审查覆盖全部 src/seq_lib 实现、两个 AIP 适配、bind/interface、涉及的测试及 RM/SCB
示例，重点核对深拷贝、读者终止、旧槽隔离、复位通知顺序、batch 继承、raw_data
权威性、passive 能力以及中文接口说明。提交前检查文档链接、快照源码一致性和
`git diff --check`，并确认未暂存用户上传文件或构建日志。

这些测试使用 VIP、独立引脚刺激和响应壳，未运行用户 DUT 或厂商 F-Tile RTL。
SCB 当前按出口顺序比较，乱序匹配需要业务键；示例预测方法支持单输出或丢弃，
复制到多个出口的业务需要扩展消费流程。FCS 传输检查复用 codec CRC 计算，
不作为 CRC 算法的独立认证。
