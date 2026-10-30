// test/sampling 契约测试：直接注入独立整包，隔离 hub 的队列/取消/复位与 SCB 接口。
// 测试拥有输入和期望；被测组件必须复制对象。负向检查仅捕获精确 ID 和严重级别。
package eth_seg_hub_test_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  // 一次只允许一个指定诊断；意外错误继续交给 UVM，不掩盖死锁或数组访问问题。
  class sample_expected_report extends uvm_report_catcher;
    string id;
    uvm_severity severity;
    int caught;

    // 身份由测试拥有，每次 arm/disarm 重置统计。
    function new();
      super.new("sample_expected_report");
    endfunction

    // 精确捕获当前负向用例，不修改其它报告的严重级别。
    virtual function action_e catch();
      if (get_id() == id && get_severity() == severity) begin
        caught++;
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass

  // 保存按值复位通知，用于验证首次同步、重复状态去重和独立 epoch。
  class sample_reset_sink extends uvm_subscriber#(eth_seg_reset_notice_t);
    eth_seg_reset_notice_t notices[$];

    // 测试持有接收器，不保存 hub 内部对象引用。
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // struct 按值入队，后续状态变化不会修改已收到的记录。
    function void write(eth_seg_reset_notice_t t);
      notices.push_back(t);
    endfunction
  endclass

  // 单一测试顺序执行有状态场景，各场景退出时显式取消订阅，防止相互污染。
  class eth_seg_hub_test extends uvm_test;
    `uvm_component_utils(eth_seg_hub_test)
    eth_seg_monitor_hub hub, other;
    eth_seg_scoreboard sb;
    sample_expected_report catcher;
    sample_reset_sink reset_sink;
    eth_seg_sequencer registry_a, registry_b;
    int checks, negative_cases;

    // 组件资源在 build 创建，所有等待均受 HDL 总超时保护。
    function new(string name = "eth_seg_hub_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 两个 hub 用于验证实例隔离；不连接任何 driver。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      hub = eth_seg_monitor_hub::type_id::create("hub", this);
      other = eth_seg_monitor_hub::type_id::create("other", this);
      sb = eth_seg_scoreboard::type_id::create("sb", this);
      catcher = new();
      reset_sink = new("reset_sink", this);
      registry_a = new("registry_a", this);
      registry_b = new("registry_b", this);
    endfunction

    // 在端口解析前接收 hub 复位通知，不依赖其内部状态字段。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      hub.reset_ap.connect(reset_sink.analysis_export);
    endfunction

    // 所有断言由独立输入决定；失败立即终止，避免后续访空掩盖根因。
    function void ensure(bit condition, string message);
      checks++;
      if (!condition) `uvm_fatal("ETH_HUB_TEST", message)
    endfunction

    // 生成固定 60B 快照，并设置非默认边带以发现不完整的深拷贝。
    function eth_seg_seq_item frame(int salt = 0);
      eth_seg_seq_item item = new("source");
      item.frame_bytes = new[60];
      foreach (item.frame_bytes[i]) item.frame_bytes[i] = byte'(17+i+salt);
      item.direction = ETH_SEG_RX;
      item.rx_status = 5;
      item.rx_error = 2;
      item.aborted = 1;
      item.fcs_checked = 1;
      item.fcs_ok = 0;
      return item;
    endfunction

    // 只在预期失败调用附近安装 catcher，调用结束须核对命中次数。
    function void arm(string id, uvm_severity severity = UVM_FATAL);
      catcher.id = id;
      catcher.severity = severity;
      catcher.caught = 0;
      uvm_report_cb::add(null, catcher);
    endfunction

    // 移除 catcher 后再断言，测试断言本身永远不能被误捕获。
    function void disarm();
      uvm_report_cb::delete(null, catcher);
      ensure(catcher.caught == 1, {"expected exactly one ", catcher.id});
      negative_cases++;
    endfunction

    // 无订阅不回放；同一方向不同 portid 各得到完整深拷贝，不与另一 hub 串包。
    task copies();
      eth_seg_seq_item source = frame();
      eth_seg_seq_item a, b;
      hub.write_sample_rx(source);
      hub.subscribe(ETH_SEG_RX, 0, 2);
      hub.subscribe(ETH_SEG_RX, 1, 2);
      other.subscribe(ETH_SEG_RX, 0, 2);
      ensure(hub.pending(ETH_SEG_RX) == 0, "unsubscribed history was replayed");
      hub.write_sample_rx(source);
      source.frame_bytes[0] = 0;
      hub.mon_xaction(a, ETH_SEG_RX, 0, 100ns);
      hub.mon_xaction(b, ETH_SEG_RX, 1, 100ns);
      ensure(a != null && b != null, "missing whole packet");
      ensure(a != b && a != source && b != source, "shared item handles");
      ensure(a.frame_bytes.size() == 60 && b.frame_bytes.size() == 60, "partial packet returned");
      foreach (a.frame_bytes[i])
        ensure(a.frame_bytes[i] == byte'(i+17) && b.frame_bytes[i] == byte'(i+17), "changed bytes");
      ensure(a.aborted && a.rx_status == 5 && a.rx_error == 2 && a.fcs_checked && !a.fcs_ok,
            "error frame metadata lost or filtered");
      a.frame_bytes[0] = 255;
      ensure(b.frame_bytes[0] == 17 && other.pending(ETH_SEG_RX) == 0, "copy or IP isolation failed");
      hub.unsubscribe(ETH_SEG_RX, 0);
      hub.unsubscribe(ETH_SEG_RX, 1);
      other.unsubscribe(ETH_SEG_RX, 0);
    endtask

    // 验证先等后到、取消重建、并发保护以及被 kill 的读者不会永久占用槽。
    task readers();
      eth_seg_seq_item source = frame(1);
      eth_seg_seq_item received, cancelled;
      process reader;
      bit reader_done = 0;
      hub.subscribe(ETH_SEG_TX);
      fork
        hub.mon_xaction(received, ETH_SEG_TX, 0, 100ns);
        begin #5ns; hub.write_sample_tx(source); end
      join
      ensure(received != null && received.frame_bytes[0] == 18, "blocking wakeup failed");
      fork
        begin
          reader = process::self();
          hub.mon_xaction(cancelled, ETH_SEG_TX);
          reader_done = 1;
        end
      join_none
      #1ns;
      arm("ETH_SAMPLE_READER");
      hub.mon_xaction(received, ETH_SEG_TX, 0, 1ns);
      disarm();
      hub.unsubscribe(ETH_SEG_TX);
      hub.subscribe(ETH_SEG_TX);
      hub.write_sample_tx(source);
      wait (reader_done);
      ensure(cancelled == null && hub.pending(ETH_SEG_TX) == 1, "old reader consumed new subscription");
      hub.mon_xaction(received, ETH_SEG_TX);
      reader = null;
      fork
        begin reader = process::self(); hub.mon_xaction(received, ETH_SEG_TX); end
      join_none
      #1ns;
      ensure(reader != null, "reader never started");
      reader.kill();
      hub.write_sample_tx(source);
      hub.mon_xaction(received, ETH_SEG_TX, 0, 10ns);
      ensure(received != null, "killed reader retained ownership");
      hub.unsubscribe(ETH_SEG_TX);
    endtask

    // 容量和配置错误不能继续入队或无期限等待；默认 timeout=0 在 readers 场景验证。
    task errors();
      eth_seg_seq_item source = frame();
      eth_seg_seq_item received;
      arm("ETH_SAMPLE_CFG"); hub.subscribe(ETH_SEG_RX, 0, 0); disarm();
      arm("ETH_SAMPLE_CFG"); hub.subscribe(eth_seg_dir_e'(8)); disarm();
      arm("ETH_SAMPLE_SUB"); hub.mon_xaction(received, ETH_SEG_RX); disarm();
      arm("ETH_SAMPLE_NULL"); hub.write_sample_rx(null); disarm();
      hub.subscribe(ETH_SEG_RX, 0, 1);
      arm("ETH_SAMPLE_CFG"); hub.subscribe(ETH_SEG_RX); disarm();
      hub.write_sample_rx(source);
      arm("ETH_SAMPLE_OVERFLOW"); hub.write_sample_rx(source); disarm();
      ensure(hub.pending(ETH_SEG_RX) == 1, "overflow modified existing queue");
      hub.mon_xaction(received, ETH_SEG_RX);
      arm("ETH_SAMPLE_TIMEOUT", UVM_ERROR);
      hub.mon_xaction(received, ETH_SEG_RX, 0, 10ns);
      disarm();
      ensure(received == null, "timeout returned stale object");
      hub.unsubscribe(ETH_SEG_RX);
    endtask

    // 方向复位清理缓存但保留订阅，跨复位等待使用原始截止时间。
    task resets();
      eth_seg_seq_item source = frame();
      eth_seg_seq_item received;
      time started;
      hub.subscribe(ETH_SEG_RX);
      hub.subscribe(ETH_SEG_TX);
      hub.write_sample_rx(source);
      hub.write_sample_tx(source);
      hub.write_sample_reset_rx(1);
      ensure(hub.pending(ETH_SEG_RX) == 0 && hub.pending(ETH_SEG_TX) == 1, "reset direction isolation failed");
      hub.write_sample_reset_rx(0);
      hub.write_sample_reset_rx(0);
      ensure(reset_sink.notices.size() == 2, "duplicate reset state was published");
      ensure(reset_sink.notices[0].asserted && !reset_sink.notices[1].asserted &&
             reset_sink.notices[0].epoch == 1 && reset_sink.notices[1].epoch == 1,
             "initial reset epoch or release notice wrong");
      fork
        hub.mon_xaction(received, ETH_SEG_RX, 0, 100ns);
        begin #5ns; hub.write_sample_reset_rx(1); #5ns; hub.write_sample_reset_rx(0);
          #5ns; hub.write_sample_rx(source); end
      join
      ensure(received != null, "reset removed subscription or reader");
      // 同一时刻的入包和复位不应返回已被清理的旧包，也不能提前报告 timeout。
      fork
        hub.mon_xaction(received, ETH_SEG_RX, 0, 100ns);
        begin
          #5ns;
          hub.write_sample_rx(source);
          hub.write_sample_reset_rx(1);
          #5ns;
          hub.write_sample_reset_rx(0);
          #5ns;
          source = frame(9);
          hub.write_sample_rx(source);
        end
      join
      ensure(received != null && received.frame_bytes[0] == 26, "same-time reset returned old data");
      started = $time;
      arm("ETH_SAMPLE_TIMEOUT", UVM_ERROR);
      fork
        hub.mon_xaction(received, ETH_SEG_RX, 0, 20ns);
        begin #5ns; hub.write_sample_reset_rx(1); #5ns; hub.write_sample_reset_rx(0); end
      join
      disarm();
      ensure($time-started == 20ns && received == null, "reset restarted timeout");
      ensure(reset_sink.notices.size() == 8 && reset_sink.notices[7].epoch == 4,
             "reset epoch did not count assertions exactly");
      foreach (reset_sink.notices[i])
        ensure(reset_sink.notices[i].direction == ETH_SEG_RX, "reset direction changed");
      hub.unsubscribe(ETH_SEG_RX);
      hub.unsubscribe(ETH_SEG_TX);
    endtask

    // 直接写 SCB 的两种到达次序、输入复制、方向清理和负向残留都应可观察。
    task scoreboard_api();
      eth_seg_seq_item source = frame();
      eth_seg_seq_item expected = frame();
      sb.write_after(source);
      source.frame_bytes[0] ^= 8'hff;
      sb.write_before(expected);
      ensure(sb.matched_tx == 1 && sb.is_idle(), "actual-first or SCB copy failed");
      sb.write_before(expected);
      sb.write_after(expected);
      ensure(sb.matched_tx == 2, "expected-first failed");
      sb.write_before(expected);
      arm("ETH_SEG_SB_TX", UVM_ERROR); sb.write_after(source); disarm();
      ensure(sb.mismatch_tx == 1, "bad data not compared");
      arm("ETH_SEG_SB_NULL", UVM_ERROR); sb.write_after(null); disarm();
      sb.write_before(expected);
      arm("ETH_SEG_SB_TX_REMAINDER", UVM_ERROR); sb.check_phase(null); disarm();
      sb.write_expect_rx(expected);
      sb.flush_direction(ETH_SEG_TX);
      ensure(sb.expect_rx_fifo.size() == 1 && sb.matched_tx == 2, "flush damaged another direction or counters");
      sb.flush_direction(ETH_SEG_RX);
      ensure(sb.is_idle(), "SCB did not drain");
    endtask

    // fatal 被捕获时空/重复登记也不能修改静态表；只有拥有者才能撤销。
    task registry_contract();
      arm("ETH_SQR_REGISTER");
      eth_seg_sequencer::register_sqr("", null);
      disarm();
      eth_seg_sequencer::register_sqr("hub_registry", registry_a);
      arm("ETH_SQR_REGISTER");
      eth_seg_sequencer::register_sqr("hub_registry", registry_b);
      disarm();
      ensure(eth_seg_sequencer::get_sqr("hub_registry") == registry_a, "duplicate overwrote registry");
      eth_seg_sequencer::unregister_sqr("hub_registry", registry_b);
      ensure(eth_seg_sequencer::get_sqr("hub_registry") == registry_a, "non-owner removed registry");
      eth_seg_sequencer::unregister_sqr("hub_registry", registry_a);
      ensure(eth_seg_sequencer::get_sqr("hub_registry") == null, "owner did not unregister");
    endtask

    // 完成标记只在全部并发线程结束、队列清空且所有负向计数准确后发布。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      copies();
      readers();
      errors();
      resets();
      scoreboard_api();
      registry_contract();
      ensure(hub.is_idle() && other.is_idle() && sb.is_idle(), "unit test retained transactions");
      `uvm_info("ETH_HUB_TEST_COMPLETE", $sformatf("checks=%0d expected_reports=%0d", checks, negative_cases), UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
