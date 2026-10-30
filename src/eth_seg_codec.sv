// src 字节编解码层：统一前导与 Ethernet CRC32，刻意不共享 segment 边界状态机。
// 所有方法为静态且无持久状态；输入事务由调用者拥有，encode 输出新队列，decode 更新调用者对象。
// include_fcs 时数组保留尾部四字节，错误 CRC 是合法错误帧而不是格式解析失败。
class eth_seg_codec;
  // 按 Ethernet 反射多项式计算 CRC；输入为空时返回零，前导字节由调用者排除。
  static function bit [31:0] crc32(input byte unsigned data[]);
    bit [31:0] crc;
    crc = 32'hffffffff;
    foreach (data[i]) begin
      crc ^= {24'b0, data[i]};
      for (int b = 0; b < 8; b++)
        crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
    end
    return ~crc;
  endfunction

  // 构建物理字节串：显式 FCS 保留原样，缺省 FCS 自动计算，错误注入只翻转尾 CRC 一位。
  // 配置关闭 FCS 时不猜测/剥离用户数组；不支持的 fcs_present 组合由 driver 拒绝。
  static function void encode(input eth_seg_seq_item item, input bit preamble,
                              input bit include_fcs, output eth_seg_byte_queue_t bytes);
    bit [31:0] crc;
    bytes.delete();
    if (preamble) begin
      repeat (7) bytes.push_back(8'h55);
      bytes.push_back(8'hd5);
    end
    foreach (item.frame_bytes[i]) bytes.push_back(item.frame_bytes[i]);
    if (include_fcs && !item.fcs_present) begin
      crc = crc32(item.frame_bytes);
      for (int b = 0; b < 4; b++) bytes.push_back(crc[b*8 +: 8]);
    end
    if (include_fcs && item.inject_fcs_error && bytes.size() >= 4)
      bytes[bytes.size()-1] ^= 8'h01;
  endfunction

  // 验证并移除前导；FCS 字节继续保留到输出数组中，单独填校验状态及低字节优先的数值。
  // 返回零仅表示格式不足或前导错误；CRC 不匹配返回一，使负向错误帧可进入 scoreboard。
  static function bit decode(input eth_seg_byte_queue_t bytes, input bit preamble,
                             input bit include_fcs, ref eth_seg_seq_item item,
                             output string reason);
    int first_byte, body_size;
    byte unsigned body[];
    reason = "";
    first_byte = preamble ? 8 : 0;
    if (bytes.size() < first_byte + (include_fcs ? 4 : 1)) begin
      reason = "frame too short for requested format";
      return 0;
    end
    if (preamble) begin
      for (int b = 0; b < 7; b++) begin
        if (bytes[b] != 8'h55) begin
          reason = "invalid preamble";
          return 0;
        end
      end
      if (bytes[7] != 8'hd5) begin
        reason = "invalid start frame delimiter";
        return 0;
      end
    end
    if (item == null) item = new("decoded_item");
    body_size = bytes.size() - first_byte;
    item.frame_bytes = new[body_size];
    foreach (item.frame_bytes[b]) item.frame_bytes[b] = bytes[first_byte+b];
    item.fcs_present = include_fcs;
    item.fcs_checked = include_fcs;
    item.fcs_ok = 0;
    item.fcs = 0;
    if (include_fcs) begin
      body = new[body_size-4];
      foreach (body[b]) body[b] = item.frame_bytes[b];
      for (int b = 0; b < 4; b++) item.fcs[b*8 +: 8] = item.frame_bytes[body_size-4+b];
      item.fcs_ok = (crc32(body) == item.fcs);
    end
    return 1;
  endfunction
endclass
