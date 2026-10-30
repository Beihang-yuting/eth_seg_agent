// src 配置层：将编译期速率类型与运行期角色、格式、节奏策略绑定。
// agent 持有配置，子组件借用同一对象；运行中不应改变格式或队列深度。
// 类型参数贯穿 vif，避免不同宽度接口通过无类型句柄被误连接。
class eth_seg_config #(int RATE = 100) extends uvm_object;
  `uvm_object_param_utils(eth_seg_config#(RATE))

  virtual eth_seg_if #(RATE) vif;
  int eth_rate_g = RATE;
  eth_seg_role_e role = ETH_SEG_CLIENT;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit preamble_passthrough = 0, include_fcs = 0;
  bit enable_protocol_check = 1;
  eth_seg_pattern_e ready_pattern = ETH_SEG_CONTINUOUS;
  eth_seg_pattern_e rx_valid_pattern = ETH_SEG_CONTINUOUS;
  int ready_high_cycles = 8, ready_low_cycles = 2, ready_high_pct = 70;
  int rx_valid_high_cycles = 8, rx_valid_low_cycles = 2, rx_valid_high_pct = 70;
  int traffic_load_pct = 100;
  bit random_load = 0;
  int load_min_pct = 10, load_max_pct = 100;
  int max_pending = 64;

  // 创建独立配置对象；vif 必须由 testbench 显式赋值后再构建 agent。
  function new(string name = "eth_seg_config");
    super.new(name);
  endfunction

  // 校验全部静态约束并返回首个原因；不发 report，调用者决定 fatal 的组件上下文。
  function bit validate(output string reason);
    reason = "";
    if (!(RATE inside {100, 200, 400})) reason = "RATE must be 100, 200 or 400";
    else if (eth_rate_g != RATE) reason = "eth_rate_g does not match parameter RATE";
    else if (vif == null) reason = "virtual interface is null";
    else if (!(role inside {ETH_SEG_CLIENT, ETH_SEG_MAC})) reason = "invalid role";
    else if (!(is_active inside {UVM_ACTIVE, UVM_PASSIVE})) reason = "invalid active/passive mode";
    else if (!(ready_pattern inside {ETH_SEG_CONTINUOUS, ETH_SEG_PERIODIC, ETH_SEG_RANDOM}) ||
             !(rx_valid_pattern inside {ETH_SEG_CONTINUOUS, ETH_SEG_PERIODIC, ETH_SEG_RANDOM}))
      reason = "invalid timing pattern";
    else if (ready_high_cycles <= 0 || ready_low_cycles <= 0 ||
             rx_valid_high_cycles <= 0 || rx_valid_low_cycles <= 0)
      reason = "periodic high and low cycle counts must be positive";
    else if (!(ready_high_pct inside {[0:100]}) || !(rx_valid_high_pct inside {[0:100]}))
      reason = "timing percentage must be 0..100";
    else if (!(traffic_load_pct inside {[1:100]}) || !(load_min_pct inside {[1:100]}) ||
             !(load_max_pct inside {[1:100]}) || load_min_pct > load_max_pct)
      reason = "load percentage must be 1..100 with min <= max";
    else if (max_pending <= 0) reason = "max_pending must be positive";
    return reason == "";
  endfunction
endclass
