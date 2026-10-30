// 定向 frame sequence：通过公开字段覆盖基础 sequence，便于回归组合连续、间歇、FCS 与错误场景。
// 该类不直接等待物理完成；测试应等待 scoreboard.is_idle() 或 monitor 计数达到预期。
class eth_seg_frame_seq extends eth_seg_base_seq;
  `uvm_object_utils(eth_seg_frame_seq)

  rand int unsigned frame_length;
  constraint frame_length_c { frame_length inside {[9:4096]}; }

  function new(string name = "eth_seg_frame_seq");
    super.new(name);
    random_length = 0;
  endfunction

  // 使用单一指定长度生成一批内容不同的报文，避免随机数组约束覆盖 make_frame 数据。
  virtual task body();
    eth_seg_seq_item item;
    int unsigned nbytes;
    if (frame_length < 9) begin
      if (!randomize(frame_length)) frame_length = min_frame_bytes;
    end
    nbytes = frame_length;
    for (int unsigned f = 0; f < frame_count; f++) begin
      item = eth_seg_seq_item::type_id::create($sformatf("directed_frame_%0d", f));
      make_frame(item, nbytes, f);
      start_item(item);
      finish_item(item);
    end
  endtask
endclass
