# Ethernet segmented UVM VIP

`eth_seg_pkg` 将事务、配置、驱动、监视器、agent 和 environment 统一打包。接口参数
`ETH_RATE_G` 仅支持 100、200、400；一个 `tb_top` 同时实例化三种宽度，测试通过类型化
`uvm_config_db` 传递独立 virtual interface。CLIENT active agent 驱动 TX，MAC active agent
驱动 RX 与 ready；两端可分别改为 passive 连接真实 DUT。

默认事务从目的 MAC 字节开始，不含前导和 FCS。配置 `preamble_passthrough` 或 `include_fcs`
后，codec/monitor 会处理 7×55、D5 前导及低字节优先 CRC32。`fcs_present` 明确表示事务已经
携带 FCS，`inject_fcs_error` 只在 FCS 开启时翻转 CRC；驱动 `item_done` 仅表示已复制入队，
物理完成须核对 `sent_ap`/monitor 的预期数量及 scoreboard 排空，不能仅凭 `is_idle()` 判定。

在 `10.11.10.53` 载入 VCS/UVM 1.2 与 license 环境后运行：

```text
make compile RATE=100
make run RATE=200 TEST=eth_seg_smoke_test SEED=7
make regress
make bind-test SEED=7
make timing-test SEED=7
make timing-checker-test
```

日志位于 `build/<RATE>/logs/`，`scripts/check_log.py` 检查 UVM summary 和非零错误计数。
原 smoke testbench 是双 active VIP 自检；新增时序测试使用独立 HDL ready 源，均不包含厂商 F-Tile 加密 RTL 模型。

`gap_segments` / sequence 的 `inter_frame_gap` 以有效 idle segment 计数，TX/RX 均执行。
固定/随机负载按每帧占用的 segment 数换算间隔，外部 ready/valid 气泡不消费该计数。
真实 DUT 正沿更新 ready、包内停顿、复位恢复及 checker 字段有效范围见
[时序审查与定向回归](docs/development/timing-audit.md)。

接入真实 DUT 时，配置必须使用与接口参数一致的句柄类型，例如
`uvm_config_db#(virtual eth_seg_if#(200))::set(null, "uvm_test_top", "vif", vif200)`；
`eth_seg_config#(200).eth_rate_g` 也必须保持 200，否则 agent build 会立即报告错误。

如需按图片中的方式，在 module 内封装 interface 和 root agent 后 `bind` 到已有 DUT，
使用 [eth_seg_bind_wrapper](bind/eth_seg_bind_wrapper.sv)，只需要 `AGENT_NAME` 和 `RATE`。
cfg 保持默认值，顶层 `#0; run_test();` 启动；agent 自动发布静态
`eth_seg_sequencer::sqr[agent_name]`，env 无需创建 agent 或转接 sequencer。
完整接线、配置与时序约定见 [bind 集成说明](docs/integration/bind.md)。

[AIP Tcl 示例](examples/aip/eth_seg_aip_pkg.sv) 使用 `aip_core/update` 的 `aip_cmd_seq`
启动命名 sequencer，通过 `aip_int` 读取发包长度；核心 VIP 不依赖 AIP。
验证入口为 `make aip-test AIP_CORE=/path/to/aip_core`，包含四个 IP 的真实 Tcl 发包测试。

网络报文使用可选的 `eth_net_packet_pkg::eth_base_seq`：把
`net_packet_pkg::packet.raw_data` 转成独立字节事务，保留协议头、payload 和 RoCEv2 ICRC，
前导/Ethernet FCS 仍由 agent cfg 控制。支持直接设置 `seq.pkt` 后 `start(sqr)`，
支持 `count` 批量重放，或覆写 `create_packet()` 逐包生成；也可在业务 body 中调用 `send_packet(pkt)`。完整编译顺序、接口和网络报文 Tcl 示例见
[net_packet 集成说明](docs/integration/net_packet.md)。验证入口：

```bash
make net-packet-test NET_PACKET=/path/to/net_packet SEED=7
make net-packet-aip-test NET_PACKET=/path/to/net_packet AIP_CORE=/path/to/aip_core SEED=7
```

`eth_base_seq` 还提供 subscribe/mon_xaction/unsubscribe，一次取得 Monitor 已组好的
完整 Ethernet 帧。RM/SCB 使用 set_sequencer 关联长期对象；SCB 支持直接
write_before/write_after，passive agent 同样可取包。用法、复位协调与完整示例见
[整包采样及 RM/SCB 集成](docs/integration/sampling.md)。

```bash
make hub-test SEED=7
make sampling-test NET_PACKET=/path/to/net_packet SEED=7
```
