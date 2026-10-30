# test/net_packet Tcl 网络发包测试：参数按 bind AGENT_NAME 隔离，SV 独立比较线上报文。
# 依赖 aip_core/update 的命名参数语法；Tcl 错误必须让调用进程失败，不能静默继续。
source [file join $::env(AIP_CORE) dist aip_init.tcl]

# 每个命令核对独立 ack 和 status，避免超时旧结果被当作本次成功。
proc eth_net_cmd_ok {args} {
    uplevel #0 $args
    set ack [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$ack != $::_aip_cmd_seq || [aip_check_status] != 0} {
        error "ETH_NET_AIP_TCL_FAIL: $args: [aip_read_result]"
    }
}

eth_net_cmd_ok set_param path=eth1.tmpl value=ETH_IPV6_TCP
eth_net_cmd_ok set_param path=eth1.pkt_len value=128
eth_net_cmd_ok set_param path=eth1.outer_eth.dst_mac value=0xfedcba987654
eth_net_cmd_ok set_param path=eth2.tmpl value=ETH_IPV4_UDP_ROCEV2
eth_net_cmd_ok set_param path=eth2.pkt_len value=129
eth_net_cmd_ok set_param path=eth3.pkt_len value=512
eth_net_cmd_ok set_param path=eth3.outer_eth.dst_mac value=0x010203040506

# eth0 第一批使用默认 256B IPv4/UDP；随后同一 binary 内修改长度、MAC 和 payload。
eth_net_cmd_ok eth0_net_send count=2
eth_net_cmd_ok eth1_net_send count=3
eth_net_cmd_ok eth2_net_send count=1
eth_net_cmd_ok eth3_net_send count=4
eth_net_cmd_ok set_param path=eth0.pkt_len value=64
eth_net_cmd_ok set_param path=eth0.outer_eth.dst_mac value=0x123456789abc
eth_net_cmd_ok set_param path=eth0.payload_byte value=0x5a
eth_net_cmd_ok eth0_net_send count=1
puts "ETH_NET_AIP_TCL_COMPLETE"
eth_net_cmd_ok end_test
run
