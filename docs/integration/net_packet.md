# net_packet 与 eth_base_seq

`eth_base_seq` 把 `net_packet_pkg::packet` 转成 `eth_seg_seq_item`，通过现有
sequencer/driver 发送。sequence 不需要 RATE 参数，同一类型可用于 100G、200G、400G，
也可分别启动在 CLIENT agent 的 TX sequencer 或 MAC agent 的 RX sequencer 上。

```text
net_packet_pkg::packet.raw_data
              ↓ 逐字节复制
eth_seg_seq_item.frame_bytes
              ↓ sequencer → driver → segmented interface
```

适配类型位于 `eth_net_packet_pkg`，实现文件为 `seq_lib/eth_base_seq.sv`。
原有 `eth_seg_base_seq` / `eth_seg_frame_seq` 继续提供基础字节刺激；基础 VIP 不依赖
`net_packet` 或 AIP，只有使用网络报文适配时才编译额外 package。

## 编译与依赖

已核对的上游版本：

- `net_packet` main：`b8a4c1469511159a59d1a547ed0b5fe896a68e5e`。
- 可选 Tcl 接入：`aip_core` update，`cd339eff8d4b0982be885a0a71f3e593a4aed239`。

使用 `net_packet/src/net_packet_pkg.sv` 的统一 package 入口。不要再将
`core/packet.sv` 等组件 include 到另一个 package 或 `$unit`，否则会产生不兼容的
同名 packet 类型或 include guard 冲突。include 路径参考上游 `filelist_pkg.f`，
本仓库 Makefile 的 `NET_INC` 已列出这些路径。

基本编译顺序如下，原有 VIP 需要的 `+incdir+src` 等路径仍保留：

```text
uvm_pkg（VCS 使用 -ntb_opts uvm-1.2）
net_packet/src/net_packet_pkg.sv
rtl/eth_seg_if.sv
src/eth_seg_types.sv
src/eth_seg_pkg.sv
src/eth_net_packet_pkg.sv
用户 test/sequence package
```

不单独编译 `seq_lib/eth_base_seq.sv`，它由 `eth_net_packet_pkg` include。
若使用 AIP 示例，在同一次编译中把 `aip_core_pkg.sv` 放到 `net_packet_pkg.sv` 前，
从而启用上游 `packet.load_params()` 的 AIP 参数读取，再编译
`examples/aip/eth_net_packet_aip_pkg.sv`。

## 直接发送一帧

下面的代码放在 UVM `run_phase` 或已启动的业务 sequence 中。先等 DUT 复位解除，
并确保 agent 的 build/connect 已完成、静态 sqr 已登记。

```systemverilog
import net_packet_pkg::*;
import eth_seg_pkg::*;
import eth_net_packet_pkg::*;

// 报文由调用方创建；明确完成打包后交给通用 sequence。
packet pkt = new();
eth_base_seq seq = eth_base_seq::type_id::create("seq");
eth_seg_sequencer sqr = eth_seg_sequencer::get_sqr("eth0");

pkt.build_from_template(ETH_IPV4_UDP);
pkt.pkt_len = 256;
pkt.payload_mode = PAYLOAD_INCREMENT;
pkt.do_pack();

seq.pkt = pkt;
seq.start(sqr);
```

如果使用上游 `packet_item`，传入 `seq.pkt = net_item.pkt`。这里读取的是网络
`raw_data`，不调用 UVM 的 `pack_bytes()`；上游 UVM 打包格式还包含长度等序列化信息，
不能直接当作 Ethernet 帧发送。

`seq.start()` 返回表示 driver 已接收/复制事务，**不表示物理发送完成**。
test 需要继续持有 objection，等 monitor/scoreboard 收完期望报文后结束。
顶层 `#0; run_test();` 只协调 bind 的 cfg/agent 初始化；Tcl/sequence 要在
UVM connect 后启动，详见 [bind 集成说明](bind.md)。

## 批量发送

`count` 由 eth_base_seq 统一定义，默认 1，必须大于零：

```systemverilog
seq.pkt = pkt;  // 显式 pkt：重放相同 raw_data 字节快照。
seq.count = 100;
seq.start(sqr);
```

不设置 pkt 时，每轮调用 create_packet() 新建独立报文；默认 256B IPv4/UDP、
payload=0xa5。子类可覆写 create_packet，基类负责 count 循环。不要在子类重复
声明 count，也不要在覆写的 create_packet 中再循环 count 次。

## 派生业务 sequence

业务层只决定每包内容，继承默认批量循环：

```systemverilog
// 用户 sequence package：依赖 net_packet_pkg、eth_seg_pkg、eth_net_packet_pkg。
class my_udp_seq extends eth_base_seq;
  `uvm_object_utils(my_udp_seq)

  // count 是继承的字段，仍可由 Tcl 宏直接设置。
  function new(string name = "my_udp_seq");
    super.new(name);
    count = 10;
  endfunction

  // 每次随机化触发 post_randomize 打包；转换保持该字节快照。
  virtual function packet create_packet(int unsigned packet_index);
    packet p = new();
    if (!p.randomize() with { pkt_kind == ETH_IPV4_UDP; pkt_len == 256; }) begin
      `uvm_fatal("PACKET_RANDOM", "network packet randomization failed")
      return null;
    end
    return p;
  endfunction
endclass
```

复杂业务也可覆写 body 并调用 send_packet；此时发送循环由该 body 自己负责。
采样方法可以直接在本类对象上使用，详见 [整包采样及 RM/SCB](sampling.md)。

需要逐包调整 EOP 错误边带时，可在派生 `body()` 中使用
`eth_seg_seq_item item = packet_to_item(p)`，设置 `item.inject_error`、
`item.rx_error` 等字段后调用 `start_item(item); finish_item(item);`。
转换函数也可在不绑定 sequencer 时单独调用；`send_packet()` 必须在已启动的
sequence 中使用。

## 字节、格式和所有权约定

| 项目 | 行为 |
| --- | --- |
| 输入 | `packet`，已有 `raw_data` 时以这些字节为准 |
| 尚未打包 | `raw_data` 为空且具有 Ethernet 协议栈时调用一次 `do_pack()` |
| 拷贝 | 每次返回新 transaction 和独立数组，不保留源数组别名 |
| 字节顺序 | `raw_data[0]` → `frame_bytes[0]` → 首个有效 segment 的低 8 位 |
| 默认格式 | 从目的 MAC 开始，不含前导码和 Ethernet FCS |
| 前导/FCS 开启 | 仍由 agent cfg/codec 添加；转换结果 `fcs_present=0` |
| 协议尾部 | RoCEv2 ICRC 等保持原样，属于 Ethernet 载荷内容 |
| 长度 | 使用实际 `raw_data.size()`；不截断、不额外补齐，至少 14B |
| 已打包的错误帧 | 保留修改过的字节与错误校验和，不重新计算 |
| 发送速率/节奏 | 使用原 agent 配置；TX ready 固定两拍延迟保持不变 |

未打包路径会修改调用方 packet 的 `raw_data` 和自动计算字段；发送期间不要由其它
线程修改同一个 packet。已打包后若修改协议头字段，应显式调用 `do_pack()`；
转换器无法判断非空 `raw_data` 是否对应最新字段。再次 `do_pack()` 也可能重新生成
随机 payload，因此已有定制字节或错误注入时直接使用当前 `raw_data`。

传给 packet_to_item/send_packet 的空句柄、没有字节也没有协议栈、
自动打包路径中的空协议层/非 Ethernet 起始层、
小于 14B 的结果都会产生明确 UVM fatal。更短的底层异常刺激可继续直接创建
`eth_seg_seq_item`。自动打包可能加入 RoCEv2 对齐字节，实际长度应看 `raw_data.size()`。
手动导入的字节也须满足不含前导/Ethernet FCS 的输入约定；转换器不猜测并删除尾字节。

## AIP Tcl 发包

`examples/aip/eth_net_packet_aip_pkg.sv` 中的 `eth_net_packet_aip_seq` 继承
`eth_base_seq`，只覆写 create_packet/packet_queued；继承的 `count` 由
`aip_cmd_seq` 设置，批量循环只有基类一份。每帧按当前
sequencer 的父 agent 全名读取参数，默认 256B IPv4/UDP，payload 为 `8'ha5`。

四个示例命令映射到 `eth0`～`eth3`；用户按自己的 `AGENT_NAME` 修改宏即可：

```systemverilog
`aip_cmd_seq(eth0_net_send, eth_net_packet_aip_seq,
             eth_seg_sequencer::get_sqr("eth0"))
```

Tcl 在 `run_phase` 中运行的 bridge 上执行：

```tcl
source [file join $::env(AIP_CORE) dist aip_init.tcl]
set_param path=eth0.tmpl value=ETH_IPV4_UDP
set_param path=eth0.pkt_len value=256
set_param path=eth0.outer_eth.dst_mac value=0x123456789abc
set_param path=eth0.outer_ipv4.dst_addr value=0xc0a80102
set_param path=eth0.outer_udp.dst_port value=4791
set_param path=eth0.payload_byte value=0x5a
eth0_net_send count=10
```

`tmpl`、`pkt_len` 和协议头字段使用上游 `packet.load_params()`；`payload_byte`
使用 `aip_int`。参数仅影响此例生成的新报文，不会修改 agent cfg。示例校验长度
在 14～16384B 且容纳得下协议栈；公共转换 sequence 本身不施加这个示例上限。
顶层 env 无需重复创建 bind agent 或转接 sequencer。
每个命令创建新的发送 sequence，Monitor 订阅缓存在 agent 内持续存在。
没有 load_send_config；参数在每包生成时直接读取，之后的修改不影响已经入队的副本。
当前 aip_cmd_seq 自动解析 count/time；其它报文参数使用上面的 set_param，
没有自动支持 `eth0_net_send count=10 pkt_len=256` 这样的任意字段映射。

## 验证入口

在 `10.11.10.53` 载入 VCS/license 环境后运行：

```bash
make net-packet-test NET_PACKET=/path/to/net_packet SEED=7
make net-packet-aip-test NET_PACKET=/path/to/net_packet AIP_CORE=/path/to/aip_core SEED=7
```

普通测试覆盖三速率 × 四种前导/FCS 组合，每条 link 至少发送 17 TX + 17 RX，
400G 默认格式另加每方向32短包，共472个物理帧；analysis 与 seq 两条路径逐字节比较
IPv4/UDP、IPv6/TCP、ARP、VLAN、VXLAN、RoCEv2、短帧和随机 payload；同时检查连续、
周期、随机 ready/valid 及随机负载。转换边界测试覆盖随机化后已打包输入、字节错误保留、
深拷贝以及六次精确匹配的转换 fatal；另验证七次 count/type/passive/生成器边界。

AIP 测试通过真实 UCLI/Tcl 启动四个命名 bind agent，检查多种协议、48-bit MAC 参数、
同端口运行时改参和同速率不同实例隔离。所有用例都等待 monitor 完成，不以命令返回
或 driver 入队作为传输成功依据。测试使用 VIP 和响应壳，不包含厂商 MAC RTL。
