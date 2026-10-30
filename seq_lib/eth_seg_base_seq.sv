// 基础 sequence：提供确定性/随机报文构造和错误字段入口，发送完成语义由 driver sent_ap 决定。
// 本类只操作字节事务，不假设 RATE；因此同一 sequence 可用于 100/200/400G agent。
class eth_seg_base_seq extends uvm_sequence #(eth_seg_seq_item);
  `uvm_object_utils(eth_seg_base_seq)

  int unsigned frame_count = 1;
  int unsigned min_frame_bytes = 60;
  int unsigned max_frame_bytes = 256;
  bit include_fcs = 0;
  bit inject_fcs_error = 0;
  bit inject_error = 0;
  bit random_length = 1;
  int unsigned inter_frame_gap = 0;

  function new(string name = "eth_seg_base_seq");
    super.new(name);
  endfunction

  // 以可复现的索引填充 Ethernet DA/SA/Type 和 payload，最小 9B 以满足 SOP/EOP 分段约束。
  virtual function void make_frame(ref eth_seg_seq_item item, int unsigned nbytes,
                                   int unsigned frame_index);
    if (nbytes < 9) nbytes = 9;
    item.frame_bytes = new[nbytes];
    for (int i = 0; i < nbytes; i++) begin
      if (i < 6) item.frame_bytes[i] = 8'h10 + i;
      else if (i < 12) item.frame_bytes[i] = 8'h20 + (i-6);
      else if (i == 12) item.frame_bytes[i] = 8'h08;
      else if (i == 13) item.frame_bytes[i] = 8'h00;
      else item.frame_bytes[i] = byte'((frame_index * 17 + i) & 8'hff);
    end
    // include_fcs 时 transaction 明确携带尾部四字节；codec 不会重复追加显式 FCS。
    if (include_fcs) begin
      byte unsigned body[];
      bit [31:0] crc;
      body = new[item.frame_bytes.size()];
      foreach (body[j]) body[j] = item.frame_bytes[j];
      crc = eth_seg_codec::crc32(body);
      item.frame_bytes = new[body.size()+4];
      foreach (body[j]) item.frame_bytes[j] = body[j];
      for (int j = 0; j < 4; j++) item.frame_bytes[body.size()+j] = crc[j*8 +: 8];
      item.fcs = crc;
      item.fcs_present = 1;
    end
    else item.fcs_present = 0;
    item.inject_fcs_error = inject_fcs_error;
    item.inject_error = inject_error;
    item.gap_segments = inter_frame_gap;
    item.direction = ETH_SEG_TX;
  endfunction

  // 子类可覆写该 task 以增加特殊报文；默认连续产生 frame_count 个事务。
  virtual task body();
    eth_seg_seq_item item;
    int unsigned nbytes;
    for (int unsigned f = 0; f < frame_count; f++) begin
      item = eth_seg_seq_item::type_id::create($sformatf("frame_%0d", f));
      if (random_length && max_frame_bytes > min_frame_bytes)
        nbytes = $urandom_range(max_frame_bytes, min_frame_bytes);
      else nbytes = min_frame_bytes;
      make_frame(item, nbytes, f);
      // make_frame 已经生成了合法的 DA/SA/Type、payload 和（如启用的）FCS。
      // 不再对 frame_bytes 二次 randomize，否则随机化会覆盖已计算的 CRC。
      start_item(item);
      finish_item(item);
    end
  endtask
endclass
