# test/aip Tcl 入口：加载指定 aip_core/update，实际调用静态 sqr 发包。
# Tcl 拥有命令次序和参数覆盖；SV subscriber 独立核对字节和每个 IP 的数量。
source [file join $::env(AIP_CORE) dist aip_init.tcl]

# 要求当前命令的独立 ack/status，不能把超时后的旧结果当作新命令成功。
proc eth_cmd_ok {args} {
    uplevel #0 $args
    set ack [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$ack != $::_aip_cmd_seq || [aip_check_status] != 0} {
        error "ETH_AIP_TCL_FAIL: $args: [aip_read_result]"
    }
}

# eth0 未设置长度时使用 sequence 默认 256；其他 IP 的参数按名字隔离。
eth_cmd_ok set_param path=eth1.frame_length value=128
eth_cmd_ok set_param path=eth2.frame_length value=96
eth_cmd_ok set_param path=eth3.frame_length value=512
eth_cmd_ok eth0_send count=2
eth_cmd_ok eth1_send count=3
eth_cmd_ok eth2_send count=1
eth_cmd_ok eth3_send count=4

# 同一 binary 内第二次读参应看到新值，其他实例保持各自的配置。
eth_cmd_ok set_param path=eth0.frame_length value=64
eth_cmd_ok eth0_send count=1
puts "ETH_AIP_TCL_COMPLETE"
eth_cmd_ok end_test
# end_test 的 ack 停在 UCLI；继续运行，SV 等物理发送结束并正常结束 UVM。
run
