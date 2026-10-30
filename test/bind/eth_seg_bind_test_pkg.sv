// test/bind 验证层：检查双参数 bind、#0 初始化、静态 sqr、多实例隔离及双向读回。
// 依赖 UVM、eth_seg_pkg、eth_seg_types_pkg；本 package 不创建 interface 或 agent，
// 只借用 wrapper 发布的句柄，拥有 sequence、期望队列及六路 monitor 接收器。
package eth_seg_bind_test_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  // 单次 sequence 只负责送入事务副本；物理完成由外部 monitor 接收器判定。
  class bind_frame_sequence extends uvm_sequence#(eth_seg_seq_item);
    eth_seg_seq_item frames[$];

    // sequence 由参数化 case 显式 new；无 factory 覆盖需求，不注册额外类型名。
    function new(string name = "bind_frame_sequence");
      super.new(name);
    endfunction

    // 按队列顺序发送；finish_item 只代表 driver 入队，不能据此结束 test。
    task body();
      foreach (frames[i]) begin
        start_item(frames[i]);
        finish_item(frames[i]);
      end
    endtask
  endclass

  // 每个 monitor 独立持有期望队列，防止仅验证 active 的本地发送意图。
  // write 在 monitor 的回调内执行，只读事务且不消耗仿真时间。
  class bind_packet_sink extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_seq_item expected[$];
    int received = 0;

    // 创建 analysis_export；接收器由 case 拥有并随 UVM 层次销毁。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 深拷贝期望项，避免多个接收器共享可变事务；建表在启动 sequence 前完成。
    function void expect_packet(eth_seg_seq_item item);
      eth_seg_seq_item cp = new("expected_copy");
      cp.copy(item);
      expected.push_back(cp);
    endfunction

    // 检查所有字节和 EOP 语义；多包、坏格式、错误边带或 FCS 格式丢失立即报告。
    // SOP/EOP 的累计 segment_index 不与物理 lane 编号混用，这里只比较 empty。
    function void write(eth_seg_seq_item t);
      eth_seg_seq_item exp;
      received++;
      if (expected.size() == 0) begin
        `uvm_error("BIND_EXTRA", "unexpected monitor packet")
        return;
      end
      exp = expected.pop_front();
      if (t.frame_bytes.size() != exp.frame_bytes.size())
        `uvm_error("BIND_LENGTH", $sformatf("got %0d, expected %0d bytes", t.frame_bytes.size(), exp.frame_bytes.size()))
      else foreach (exp.frame_bytes[i])
        if (t.frame_bytes[i] !== exp.frame_bytes[i]) begin
          `uvm_error("BIND_BYTES", $sformatf("packet %0d byte %0d differs", received, i))
          break;
        end
      if (t.aborted || t.direction != exp.direction || t.empty_bytes != exp.empty_bytes ||
          t.fcs_present != exp.fcs_present || t.fcs_checked != exp.fcs_present ||
          (exp.fcs_present && !t.fcs_ok))
        `uvm_error("BIND_FORMAT", t.convert2string())
      if (t.direction == ETH_SEG_TX && t.inject_error != exp.inject_error)
        `uvm_error("BIND_TX_ERROR", "TX EOP error differs")
      if (t.direction == ETH_SEG_RX &&
          {t.rx_fcs_error, t.rx_error, t.rx_status} !== {exp.rx_fcs_error, exp.rx_error, exp.rx_status})
        `uvm_error("BIND_RX_STATUS", "RX EOP status differs")
    endfunction
  endclass

  // 一组 case 对应一个实际 bound net target；三种 RATE 用相同测试逻辑。
  // client、MAC、passive 都观察双向总线，六个 sink 必须分别收到完整有序数据。
  class bind_rate_case #(int RATE = 100) extends uvm_component;
    localparam int FRAME_COUNT = 8;
    eth_seg_agent#(RATE) client, mac, observer;
    eth_seg_config#(RATE) published_cfg;
    virtual eth_seg_if#(RATE) published_vif;
    bind_packet_sink tx_sink[3], rx_sink[3];
    bind_frame_sequence tx_seq, rx_seq;
    bit done = 0;

    // case 名称同时作为显式 agent 名字前缀，例如 case100_client。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 顶层 #0 后、run_test 前调用；先验证 wrapper 没有覆盖任何行为默认值，
    // 再为闭环测试选择 MAC/passive 和格式/节奏，模拟用户自行调整 cfg。
    static function void configure(eth_seg_config#(RATE) c, m, o);
      eth_seg_config#(RATE) configs[3];
      configs[0] = c;
      configs[1] = m;
      configs[2] = o;
      foreach (configs[i]) begin
        if (configs[i] == null)
          uvm_pkg::uvm_report_fatal("BIND_INIT", "#0 did not observe synchronous cfg creation");
        if (configs[i].role != ETH_SEG_CLIENT || configs[i].is_active != UVM_ACTIVE ||
            configs[i].preamble_passthrough || configs[i].include_fcs ||
            configs[i].ready_pattern != ETH_SEG_CONTINUOUS || configs[i].rx_valid_pattern != ETH_SEG_CONTINUOUS ||
            configs[i].traffic_load_pct != 100 || configs[i].random_load)
          uvm_pkg::uvm_report_fatal("BIND_DEFAULT", "wrapper must preserve cfg defaults");
        configs[i].preamble_passthrough = (RATE != 100);
        configs[i].include_fcs = (RATE == 400);
      end
      m.role = ETH_SEG_MAC;
      o.is_active = UVM_PASSIVE;
      m.enable_protocol_check = 0;
      o.enable_protocol_check = 0;
      m.ready_pattern = (RATE == 100) ? ETH_SEG_CONTINUOUS :
                        (RATE == 200) ? ETH_SEG_PERIODIC : ETH_SEG_RANDOM;
      m.rx_valid_pattern = m.ready_pattern;
      c.traffic_load_pct = (RATE == 400) ? 50 : 100;
      m.traffic_load_pct = c.traffic_load_pct;
      c.random_load = (RATE == 400);
      m.random_load = c.random_load;
    endfunction

    // 只读取 wrapper 发布的 root 句柄；缺少实例或错误 RATE 类型会在 build 直接失败。
    function void build_phase(uvm_phase phase);
      string observer_name;
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_client_agent"}, client) ||
          !uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_mac_agent"}, mac))
        `uvm_fatal("BIND_HANDLE", "missing active root agent")
      if (!uvm_config_db#(string)::get(this, "", "observer_name", observer_name) ||
          !uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {observer_name, "_agent"}, observer))
        `uvm_fatal("BIND_HANDLE", "missing auto-named passive root agent")
      if (!uvm_config_db#(eth_seg_config#(RATE))::get(this, "", {get_name(), "_client_cfg"}, published_cfg) ||
          !uvm_config_db#(virtual eth_seg_if#(RATE))::get(this, "", {get_name(), "_client_vif"}, published_vif))
        `uvm_fatal("BIND_HANDLE", "missing published cfg/vif")
      if (published_cfg != client.cfg || published_vif != client.cfg.vif ||
          client.cfg.vif == mac.cfg.vif || client.cfg.vif == observer.cfg.vif)
        `uvm_fatal("BIND_HANDLE", "wrapper interface ownership or publication differs")
      if (client.get_parent() != uvm_root::get() || mac.get_parent() != uvm_root::get() ||
          observer.get_parent() != uvm_root::get())
        `uvm_fatal("BIND_PARENT", "agent must be a UVM root child")
      if (client.cfg.role != ETH_SEG_CLIENT || mac.cfg.role != ETH_SEG_MAC ||
          observer.cfg.is_active != UVM_PASSIVE ||
          client.cfg.preamble_passthrough != (RATE != 100) || client.cfg.include_fcs != (RATE == 400) ||
          mac.cfg.ready_pattern != ((RATE == 100) ? ETH_SEG_CONTINUOUS :
                                   (RATE == 200) ? ETH_SEG_PERIODIC : ETH_SEG_RANDOM) ||
          mac.cfg.rx_valid_pattern != mac.cfg.ready_pattern ||
          mac.cfg.random_load != (RATE == 400) || client.cfg.traffic_load_pct != ((RATE == 400) ? 50 : 100))
        `uvm_fatal("BIND_CONFIG", "user cfg adjustment differs")
      foreach (tx_sink[i]) begin
        tx_sink[i] = new($sformatf("tx_sink%0d", i), this);
        rx_sink[i] = new($sformatf("rx_sink%0d", i), this);
      end
    endfunction

    // connect 时所有 root agent 已完成 build，保证 monitor 存在；不依赖 root build 顺序。
    function void connect_phase(uvm_phase phase);
      eth_seg_agent#(RATE) agents[3];
      super.connect_phase(phase);
      agents[0] = client;
      agents[1] = mac;
      agents[2] = observer;
      foreach (agents[i]) begin
        agents[i].tx_monitor.item_collected_port.connect(tx_sink[i].analysis_export);
        agents[i].rx_monitor.item_collected_port.connect(rx_sink[i].analysis_export);
      end
      if (client.tx_driver == null || client.rx_driver != null || client.ready_driver != null ||
          mac.tx_driver != null || mac.rx_driver == null || mac.ready_driver == null ||
          observer.sequencer != null || observer.tx_driver != null ||
          observer.rx_driver != null || observer.ready_driver != null)
        `uvm_fatal("BIND_ROLE", "incorrect active/passive driver construction")
    endfunction

    // 生成可复现字节及非零 EOP 边带；每帧占两拍的 segment，末段覆盖 empty=0..7。
    // 编码只用于构建 bind 传输期望，不把这项测试当作 CRC 算法的独立验证。
    function void prepare_frames(bind_frame_sequence seq, bit is_rx);
      for (int n = 0; n < FRAME_COUNT; n++) begin
        eth_seg_seq_item item = new("stimulus");
        eth_seg_seq_item exp = new("expected");
        eth_seg_byte_queue_t bytes;
        int pre_bytes = client.cfg.preamble_passthrough ? 8 : 0;
        int fcs_bytes = client.cfg.include_fcs ? 4 : 0;
        item.frame_bytes = new[2*(RATE/25*8) - pre_bytes - fcs_bytes - n];
        foreach (item.frame_bytes[b]) item.frame_bytes[b] = byte'(n*31 + b*7 + (is_rx ? 93 : 11));
        item.inject_error = n[0];
        item.rx_fcs_error = n[0];
        item.rx_error = n[1:0];
        item.rx_status = n[2:0];
        seq.frames.push_back(item);
        exp.copy(item);
        exp.direction = is_rx ? ETH_SEG_RX : ETH_SEG_TX;
        exp.empty_bytes = n;
        exp.fcs_present = client.cfg.include_fcs;
        eth_seg_codec::encode(item, client.cfg.preamble_passthrough, client.cfg.include_fcs, bytes);
        exp.frame_bytes = new[bytes.size() - pre_bytes];
        foreach (exp.frame_bytes[b]) exp.frame_bytes[b] = bytes[b + pre_bytes];
        foreach (tx_sink[i]) begin
          if (is_rx) rx_sink[i].expect_packet(exp);
          else tx_sink[i].expect_packet(exp);
        end
      end
    endfunction

    // 六路接收器均清空期望队列才算物理传输结束，避免 finish_item 的提前完成掩盖漏包。
    function bit all_received();
      foreach (tx_sink[i])
        if (tx_sink[i].received != FRAME_COUNT || rx_sink[i].received != FRAME_COUNT ||
            tx_sink[i].expected.size() || rx_sink[i].expected.size()) return 0;
      return 1;
    endfunction

    // 等复位解除后启动双向流；设置周期上限并检查尾部无幽灵包、无未完报文。
    // 所有 case 由 test 的单一 objection 包住，本组件不单独控制仿真生命周期。
    task run_phase(uvm_phase phase);
      if (eth_seg_sequencer::get_sqr(client.get_full_name()) != client.sequencer ||
          eth_seg_sequencer::get_sqr(mac.get_full_name()) != mac.sequencer ||
          eth_seg_sequencer::get_sqr(observer.get_full_name()) != null ||
          eth_seg_sequencer::get_sqr("missing_agent") != null)
        `uvm_fatal("BIND_SQR", "static sequencer registry differs or passive was registered")
      wait (client.cfg.vif.i_tx_rst_n && mac.cfg.vif.i_rx_rst_n);
      @(posedge client.cfg.vif.i_clk_tx);
      tx_seq = new("tx_seq");
      rx_seq = new("rx_seq");
      prepare_frames(tx_seq, 0);
      prepare_frames(rx_seq, 1);
      fork
        tx_seq.start(eth_seg_sequencer::get_sqr(client.get_full_name()));
        rx_seq.start(eth_seg_sequencer::get_sqr(mac.get_full_name()));
      join
      for (int cycles = 0; cycles < 2000 && !all_received(); cycles++)
        @(negedge client.cfg.vif.i_clk_tx);
      if (!all_received()) `uvm_fatal("BIND_TIMEOUT", "six monitor streams did not complete")
      repeat (12) @(negedge client.cfg.vif.i_clk_tx);
      if (!all_received() || !client.tx_driver.is_idle() || !mac.rx_driver.is_idle() ||
          !observer.tx_monitor.is_idle() || !observer.rx_monitor.is_idle())
        `uvm_fatal("BIND_DRAIN", "unexpected trailing packet or pending state")
      if (!client.cfg.vif.tx_drive_enabled || client.cfg.vif.rx_drive_enabled || client.cfg.vif.ready_drive_enabled ||
          mac.cfg.vif.tx_drive_enabled || !mac.cfg.vif.rx_drive_enabled || !mac.cfg.vif.ready_drive_enabled ||
          observer.cfg.vif.tx_drive_enabled || observer.cfg.vif.rx_drive_enabled || observer.cfg.vif.ready_drive_enabled)
        `uvm_fatal("BIND_OWNERSHIP", "wrong interface drive ownership")
      `uvm_info("BIND_RATE_PASS", $sformatf("RATE=%0d: 8 TX + 8 RX frames matched on all 3 agents", RATE), UVM_LOW)
      done = 1;
    endtask
  endclass

  // 顶层 test 只拥有验证组件；agent 的创建入口始终在 bound wrapper 内。
  class eth_seg_bind_test extends uvm_test;
    `uvm_component_utils(eth_seg_bind_test)
    bind_rate_case#(100) case100;
    bind_rate_case#(200) case200;
    bind_rate_case#(400) case400;
    bind_rate_case#(100) case100b;

    // factory 创建测试；case 通过直接 new 保留编译期参数类型。
    function new(string name = "eth_seg_bind_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 创建四个 IP 的验证组件；两个 100G 检查同类型实例不会覆盖静态 sqr。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      case100 = new("case100", this);
      case200 = new("case200", this);
      case400 = new("case400", this);
      case100b = new("case100b", this);
    endfunction

    // 任一 case 卡住均触发有界超时；仅全部完成后发布严格日志检查使用的完成标记。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork : completion_or_timeout
        begin
          wait (case100.done && case200.done && case400.done && case100b.done);
          if (eth_seg_sequencer::sqr.num() != 8)
            `uvm_fatal("BIND_SQR_COUNT", "four links must publish eight independent active sequencers")
          `uvm_info("ETH_BIND_TEST_COMPLETE", "all bind integration checks completed", UVM_NONE)
        end
        begin
          #20us;
          `uvm_fatal("BIND_GLOBAL_TIMEOUT", "bind test did not complete within 20 us")
        end
      join_any
      disable completion_or_timeout;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
