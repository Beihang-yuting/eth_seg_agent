// test/net_packet 验证层：三种 RATE × 四种前导/FCS 格式，双向比较物理 monitor 字节。
// 依赖 net_packet_pkg、eth_net_packet_pkg；test 拥有 case、agent、期望队列和刺激报文。
// 期望直接来自输入 raw_data，不能用被测 packet_to_item 生成，以发现漏字节/换序/重打包。
package eth_net_packet_test_pkg;
  import uvm_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  `include "uvm_macros.svh"

  // 批量业务示例只遍历报文，所有转换和握手都复用公共 send_packet。
  class eth_net_batch_seq extends eth_base_seq;
    packet packets[$];

    // 队列借用 case 持有的报文，发送期间 case 不修改它们。
    function new(string name = "eth_net_batch_seq");
      super.new(name);
    endfunction

    // 顺序入队；物理完成由 case 的两个 monitor 接收器判定。
    virtual task body();
      foreach (packets[i]) send_packet(packets[i]);
    endtask
  endclass

  // 单个接收器独立持有期望快照，可同时检查字节、EOP、FCS 和无错误边带。
  class eth_net_sink extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_seq_item expected[$];
    int received = 0;

    // 接收器归 case/test 所有；analysis_export 由 uvm_subscriber 创建。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 直接复制源字节并按 cfg 构造尾 CRC；不调用被测转换函数。
    // 此测试验证传输边界，不把共用 CRC 算法的结果当作独立算法认证。
    function void expect_bytes(input byte unsigned bytes[$], input bit preamble,
                               input bit fcs, input eth_seg_dir_e direction);
      eth_seg_seq_item exp = new("expected");
      byte unsigned body[];
      bit [31:0] crc;

      body = new[bytes.size()];
      foreach (body[i]) body[i] = bytes[i];
      exp.frame_bytes = new[bytes.size() + (fcs ? 4 : 0)];
      foreach (body[i]) exp.frame_bytes[i] = body[i];
      if (fcs) begin
        crc = eth_seg_codec::crc32(body);
        for (int i = 0; i < 4; i++) exp.frame_bytes[body.size()+i] = crc[8*i +: 8];
      end
      exp.fcs_present = fcs;
      exp.direction = direction;
      exp.empty_bytes = (8 - ((exp.frame_bytes.size() + (preamble ? 8 : 0)) % 8)) % 8;
      expected.push_back(exp);
    endfunction

    // 只比较真实引脚重建的事务；多包、少字节、ICRC 被剥离等都产生明确错误。
    function void write(eth_seg_seq_item t);
      eth_seg_seq_item exp;

      received++;
      if (expected.size() == 0) begin
        `uvm_error("ETH_NET_EXTRA", "unexpected monitor packet")
        return;
      end
      exp = expected.pop_front();
      if (t.frame_bytes.size() != exp.frame_bytes.size())
        `uvm_error("ETH_NET_SIZE", $sformatf("got=%0d expected=%0d", t.frame_bytes.size(), exp.frame_bytes.size()))
      else foreach (exp.frame_bytes[i]) begin
        if (t.frame_bytes[i] !== exp.frame_bytes[i]) begin
          `uvm_error("ETH_NET_BYTES", $sformatf("frame=%0d byte=%0d got=%02x expected=%02x", received, i, t.frame_bytes[i], exp.frame_bytes[i]))
          break;
        end
      end
      if (t.aborted || t.direction != exp.direction || t.empty_bytes != exp.empty_bytes ||
          t.fcs_present != exp.fcs_present || t.fcs_checked != exp.fcs_present ||
          (exp.fcs_present && !t.fcs_ok) || t.inject_error || t.rx_error || t.rx_fcs_error ||
          (t.direction == ETH_SEG_RX && t.rx_status != 1))
        `uvm_error("ETH_NET_FORMAT", t.convert2string())
    endfunction
  endclass

  // 负向接口测试只捕获当前明确指定的 fatal，禁止全局屏蔽其它异常。
  class eth_net_expected_fatal extends uvm_report_catcher;
    string expected_id;
    int caught = 0;

    // catcher 仅在单个边界调用期间注册，调用结束立即撤销。
    function new();
      super.new("expected_fatal");
    endfunction

    // 精确匹配严重级别和 ID；捕获时累计次数供测试核对。
    virtual function action_e catch();
      if (get_severity() == UVM_FATAL && get_id() == expected_id) begin
        caught++;
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass

  // 一条 link 的格式在 build 后固定；十二条独立 link 避免运行中改格式引入歧义。
  class eth_net_rate_case #(int RATE = 100) extends uvm_component;
    int format_mode;
    bit done = 0;
    eth_seg_agent#(RATE) client, mac;
    eth_seg_config#(RATE) client_cfg, mac_cfg;
    eth_net_sink tx_sink, rx_sink;

    // case 名字与 HDL 侧 vif 的路径一一对应。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 创建双 active agent；共享同一 link，但分别占有 TX 和 RX/ready 驱动权。
    function void build_phase(uvm_phase phase);
      virtual eth_seg_if#(RATE) vif;

      super.build_phase(phase);
      if (!uvm_config_db#(virtual eth_seg_if#(RATE))::get(this, "", "vif", vif))
        `uvm_fatal("ETH_NET_VIF", "typed interface missing")
      client_cfg = new("client_cfg");
      mac_cfg = new("mac_cfg");
      client_cfg.vif = vif;
      mac_cfg.vif = vif;
      mac_cfg.role = ETH_SEG_MAC;
      client_cfg.preamble_passthrough = format_mode[1];
      mac_cfg.preamble_passthrough = format_mode[1];
      client_cfg.include_fcs = format_mode[0];
      mac_cfg.include_fcs = format_mode[0];
      mac_cfg.ready_pattern = (format_mode == 0) ? ETH_SEG_CONTINUOUS :
                              (format_mode == 1) ? ETH_SEG_PERIODIC : ETH_SEG_RANDOM;
      mac_cfg.rx_valid_pattern = mac_cfg.ready_pattern;
      if (format_mode == 3) begin
        client_cfg.traffic_load_pct = 50;
        mac_cfg.traffic_load_pct = 50;
        client_cfg.random_load = 1;
        mac_cfg.random_load = 1;
      end
      client = eth_seg_agent#(RATE)::type_id::create("client", this);
      mac = eth_seg_agent#(RATE)::type_id::create("mac", this);
      client.cfg = client_cfg;
      mac.cfg = mac_cfg;
      tx_sink = new("tx_sink", this);
      rx_sink = new("rx_sink", this);
    endfunction

    // 订阅对端 monitor，确保比较的是公共引脚采样而非 driver 的完成通知。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mac.tx_monitor.item_collected_port.connect(tx_sink.analysis_export);
      client.rx_monitor.item_collected_port.connect(rx_sink.analysis_export);
    endfunction

    // 构造常见网络帧、VLAN、隧道、RoCEv2 和最小 Ethernet 头；salt 区分方向/端口。
    // 自动打包例使用确定性 payload，以便另建期望；随机 payload 例仅打包一次后取快照。
    function packet make_packet(input int index, input int salt, input bit pack_now = 1);
      packet p = new();
      eth_header eh;

      case (index)
        0: begin p.build_from_template(ETH_IPV4_UDP); p.pkt_len = 60; end
        1: begin p.build_from_template(ETH_IPV6_TCP); p.pkt_len = 127; end
        2: begin p.build_from_template(ETH_ARP); p.pkt_len = 64; end
        3: begin p.build_from_template(ETH_IPV4_UDP_VXLAN_ETH_IPV4_UDP); p.pkt_len = 255; end
        4: begin p.build_from_template(ETH_IPV4_UDP_ROCEV2); p.pkt_len = 513; end
        5: begin
          vlan_header vh = new();
          ipv4_header ip = new();
          udp_header udp = new();
          eh = new();
          if (!p.add_layer(eh) || !p.add_layer(vh) || !p.add_layer(ip) || !p.add_layer(udp))
            `uvm_fatal("ETH_NET_BUILD", "VLAN stack rejected")
          p.pkt_len = 78;
        end
        6: begin
          eh = new();
          if (!p.add_layer(eh)) `uvm_fatal("ETH_NET_BUILD", "Ethernet stack rejected")
          p.pkt_len = 14;
        end
        default: begin p.build_from_template(ETH_IPV4_UDP); p.pkt_len = 901; end
      endcase
      eh = p.get_eth();
      eh.dst_mac = 48'h123456789abc + salt;
      eh.src_mac = 48'hfedcba987654 + index;
      p.payload_mode = (index == 7) ? PAYLOAD_RANDOM : PAYLOAD_INCREMENT;
      if (pack_now) p.do_pack();
      return p;
    endfunction

    // 默认 body 发送第一帧，派生 body 批量发送其余帧，覆盖两种公共使用方式。
    task send_stream(input bit is_rx);
      eth_base_seq single = new("single");
      eth_net_batch_seq batch = new("batch");
      eth_seg_sequencer sqr_handle;
      eth_net_sink sink;
      int salt = RATE + format_mode * 10 + (is_rx ? 1000 : 0);

      sqr_handle = eth_seg_sequencer::get_sqr(is_rx ? mac.get_full_name() : client.get_full_name());
      sink = is_rx ? rx_sink : tx_sink;
      for (int i = 0; i < 8; i++) begin
        packet p = make_packet(i, salt, i != 0);
        packet reference_packet;
        byte unsigned expected_bytes[$];

        // 第一帧输入只有协议栈，发送时应自动打包；期望由另一个确定性对象产生。
        if (i == 0) begin
          reference_packet = make_packet(i, salt);
          expected_bytes = reference_packet.raw_data;
        end
        else expected_bytes = p.raw_data;
        if (i == 4 && !p.verify_rocev2_icrc())
          `uvm_fatal("ETH_NET_ICRC", "source RoCEv2 ICRC is invalid")
        sink.expect_bytes(expected_bytes, client_cfg.preamble_passthrough,
                          client_cfg.include_fcs, is_rx ? ETH_SEG_RX : ETH_SEG_TX);
        if (i == 0) single.pkt = p;
        else batch.packets.push_back(p);
      end
      single.start(sqr_handle);
      batch.start(sqr_handle);
    endtask

    // 等全部引脚报文被消费且驱动/监视器空闲；有上限，漏包不能静默结束。
    task run_phase(uvm_phase phase);
      wait (client_cfg.vif.i_tx_rst_n && client_cfg.vif.i_rx_rst_n);
      fork
        send_stream(0);
        send_stream(1);
      join
      for (int cycles = 0; cycles < 5000; cycles++) begin
        if (tx_sink.received == 8 && rx_sink.received == 8 && client.tx_driver.is_idle() &&
            mac.rx_driver.is_idle() && mac.tx_monitor.is_idle() && client.rx_monitor.is_idle()) break;
        @(negedge client_cfg.vif.i_clk_tx);
      end
      repeat (5) @(negedge client_cfg.vif.i_clk_tx);
      if (tx_sink.received != 8 || rx_sink.received != 8 || tx_sink.expected.size() || rx_sink.expected.size() ||
          !client.tx_driver.is_idle() || !mac.rx_driver.is_idle() ||
          !mac.tx_monitor.is_idle() || !client.rx_monitor.is_idle())
        `uvm_fatal("ETH_NET_TIMEOUT", $sformatf("TX/RX received=%0d/%0d pending expectations=%0d/%0d driver_idle=%0b/%0b monitor_idle=%0b/%0b",
                   tx_sink.received, rx_sink.received, tx_sink.expected.size(), rx_sink.expected.size(),
                   client.tx_driver.is_idle(), mac.rx_driver.is_idle(),
                   mac.tx_monitor.is_idle(), client.rx_monitor.is_idle()))
      `uvm_info("ETH_NET_RATE_PASS", $sformatf("RATE=%0d preamble=%0b fcs=%0b: 8 TX + 8 RX matched", RATE, format_mode[1], format_mode[0]), UVM_NONE)
      done = 1;
    endtask
  endclass

  // 总测试持有唯一 objection，同时验证转换的对象隔离和错误入口。
  class eth_net_packet_test extends uvm_test;
    `uvm_component_utils(eth_net_packet_test)
    eth_net_rate_case#(100) case100[4];
    eth_net_rate_case#(200) case200[4];
    eth_net_rate_case#(400) case400[4];

    // test 由 run_test 创建；子 case 在 build 中创建。
    function new(string name = "eth_net_packet_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 每种速率覆盖无格式、仅 FCS、仅前导、前导加 FCS 四种静态配置。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      for (int i = 0; i < 4; i++) begin
        case100[i] = new($sformatf("r100_m%0d", i), this);
        case200[i] = new($sformatf("r200_m%0d", i), this);
        case400[i] = new($sformatf("r400_m%0d", i), this);
        case100[i].format_mode = i;
        case200[i].format_mode = i;
        case400[i].format_mode = i;
      end
    endfunction

    // 检查重复转换不重打包、不改错误注入字节，且源、两个结果之间完全独立。
    // 对 null/空栈/短帧/坏栈/未启动发送逐个匹配预期 fatal，任何额外诊断仍正常失败。
    task check_conversion_contract();
      eth_base_seq seq = new("conversion");
      packet p = new();
      eth_seg_seq_item a, b;
      byte unsigned snapshot[$];
      eth_net_expected_fatal catcher = new();

      // randomize 的 post_randomize 已打包；若转换再次打包，随机 payload 会改变。
      if (!p.randomize() with { pkt_kind == ETH_IPV4_UDP; pkt_len == 129; })
        `uvm_fatal("ETH_NET_RANDOM", "source packet randomization failed")
      p.raw_data[40] ^= 8'h80;
      snapshot = p.raw_data;
      a = seq.packet_to_item(p);
      b = seq.packet_to_item(p);
      if (a == b || a.fcs_present || a.frame_bytes.size() != snapshot.size() ||
          b.frame_bytes.size() != snapshot.size() || p.raw_data != snapshot)
        `uvm_fatal("ETH_NET_SNAPSHOT", "conversion changed source or reused transaction")
      foreach (snapshot[i])
        if (a.frame_bytes[i] !== snapshot[i] || b.frame_bytes[i] !== snapshot[i])
          `uvm_fatal("ETH_NET_SNAPSHOT", "prepacked bytes were changed")
      p.raw_data[0] ^= 8'hff;
      a.frame_bytes[1] ^= 8'hff;
      if (a.frame_bytes[0] != snapshot[0] || b.frame_bytes[1] != snapshot[1] || p.raw_data[1] != snapshot[1])
        `uvm_fatal("ETH_NET_COPY", "source and converted arrays alias")

      uvm_report_cb::add(null, catcher);
      catcher.expected_id = "ETH_NET_NULL";
      a = seq.packet_to_item(null);
      if (a != null) `uvm_fatal("ETH_NET_NEGATIVE", "null packet produced a transaction")
      p = new();
      catcher.expected_id = "ETH_NET_EMPTY";
      a = seq.packet_to_item(p);
      if (a != null) `uvm_fatal("ETH_NET_NEGATIVE", "empty packet produced a transaction")
      repeat (13) p.raw_data.push_back(0);
      catcher.expected_id = "ETH_NET_LENGTH";
      a = seq.packet_to_item(p);
      if (a != null) `uvm_fatal("ETH_NET_NEGATIVE", "short packet produced a transaction")
      p.raw_data.delete();
      p.layer_stack.push_back(null);
      catcher.expected_id = "ETH_NET_LAYER";
      a = seq.packet_to_item(p);
      if (a != null) `uvm_fatal("ETH_NET_NEGATIVE", "null layer produced a transaction")
      begin
        ipv4_header ip = new();
        p.layer_stack[0] = ip;
      end
      a = seq.packet_to_item(p);
      if (a != null) `uvm_fatal("ETH_NET_NEGATIVE", "L3-only stack produced a transaction")
      catcher.expected_id = "ETH_NET_SQR";
      seq.send_packet(p);
      uvm_report_cb::delete(null, catcher);
      if (catcher.caught != 6) `uvm_fatal("ETH_NET_NEGATIVE", "expected six precise boundary diagnostics")
      `uvm_info("ETH_NET_CONVERSION_PASS", "byte snapshots, deep copies and six negative boundaries passed", UVM_NONE)
    endtask

    // 同时等待十二个 link，计数/格式错误仍由 UVM summary 决定最终成败。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      check_conversion_contract();
      foreach (case100[i]) wait (case100[i].done && case200[i].done && case400[i].done);
      `uvm_info("ETH_NET_TEST_COMPLETE", "12 links, 192 physical frames and conversion contract passed", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
