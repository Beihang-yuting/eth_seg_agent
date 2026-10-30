# Ethernet segmented UVM VIP

`eth_seg_pkg` 将事务、配置、驱动、监视器、agent 和 environment 统一打包。接口参数
`ETH_RATE_G` 仅支持 100、200、400；一个 `tb_top` 同时实例化三种宽度，测试通过类型化
`uvm_config_db` 传递独立 virtual interface。CLIENT active agent 驱动 TX，MAC active agent
驱动 RX 与 ready；两端可分别改为 passive 连接真实 DUT。

默认事务从目的 MAC 字节开始，不含前导和 FCS。配置 `preamble_passthrough` 或 `include_fcs`
后，codec/monitor 会处理 7×55、D5 前导及低字节优先 CRC32。`fcs_present` 明确表示事务已经
携带 FCS，`inject_fcs_error` 只在 FCS 开启时翻转 CRC；驱动 `item_done` 仅表示已复制入队，
物理完成请观察 `sent_ap`、monitor 计数或 scoreboard `is_idle()`。

在 `10.11.10.53` 载入 VCS/UVM 1.2 与 license 环境后运行：

```text
make compile RATE=100
make run RATE=200 TEST=eth_seg_smoke_test SEED=7
make regress
make bind-test SEED=7
```

日志位于 `build/<RATE>/logs/`，`scripts/check_log.py` 检查 UVM summary 和非零错误计数。
当前 testbench 是双 active VIP 自检，不包含厂商 F-Tile 加密 RTL 模型。

接入真实 DUT 时，配置必须使用与接口参数一致的句柄类型，例如
`uvm_config_db#(virtual eth_seg_if#(200))::set(null, "uvm_test_top", "vif", vif200)`；
`eth_seg_config#(200).eth_rate_g` 也必须保持 200，否则 agent build 会立即报告错误。

如需按图片中的方式，在 module 内封装 interface 和 root agent 后 `bind` 到已有 DUT，
使用 [eth_seg_bind_wrapper](bind/eth_seg_bind_wrapper.sv)。它支持 100/200/400G、CLIENT/MAC、
active/passive、前导/FCS 及 supply 强度接管。完整接线、启动顺序和 UVM 句柄获取见
[bind 集成说明](docs/integration/bind.md)，可运行示例在 [test/bind](test/bind/tb_bind.sv)。
