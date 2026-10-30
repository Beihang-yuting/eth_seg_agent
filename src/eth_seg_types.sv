// src 基础类型层：为接口之外的 UVM 组件提供统一协议词汇。
// 本 package 不保存运行状态；枚举和字节队列由各组件按值持有。
package eth_seg_types_pkg;
  typedef enum {ETH_SEG_CLIENT, ETH_SEG_MAC} eth_seg_role_e;
  typedef enum {ETH_SEG_CONTINUOUS, ETH_SEG_PERIODIC, ETH_SEG_RANDOM} eth_seg_pattern_e;
  typedef enum {ETH_SEG_TX, ETH_SEG_RX} eth_seg_dir_e;
  // 复位通知按值复制；epoch 在对应方向每次断言时增加，释放时保持。
  typedef struct {
    eth_seg_dir_e direction;
    bit asserted;
    int unsigned epoch;
  } eth_seg_reset_notice_t;
  typedef byte unsigned eth_seg_byte_queue_t[$];
endpackage
