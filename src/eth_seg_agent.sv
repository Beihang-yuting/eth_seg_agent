// Agent 层：按 CLIENT/MAC 角色组合发送、接收和 ready 驱动，同时始终保留双向 monitor。
// 配置对象由父 env 通过成员或 config_db 预置；active 角色只申请自己拥有的引脚驱动权。
class eth_seg_agent #(int RATE = 100) extends uvm_agent;
  `uvm_component_param_utils(eth_seg_agent#(RATE))

  eth_seg_config#(RATE) cfg;
  eth_seg_sequencer sequencer;
  eth_seg_tx_driver#(RATE) tx_driver;
  eth_seg_rx_driver#(RATE) rx_driver;
  eth_seg_ready_driver#(RATE) ready_driver;
  eth_seg_tx_monitor#(RATE) tx_monitor;
  eth_seg_rx_monitor#(RATE) rx_monitor;

  // 创建 agent；cfg 和子组件均由 build_phase 按角色与 active/passive 状态决定。
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 从父层取得 cfg，校验 vif/rate 后创建始终存在的监视器以及角色对应 active 驱动器。
  function void build_phase(uvm_phase phase);
    string reason;
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg == null) begin
      cfg = eth_seg_config#(RATE)::type_id::create("cfg");
      `uvm_fatal("ETH_AGENT_CFG", "eth_seg_agent requires cfg from parent or config_db")
    end
    if (!cfg.validate(reason)) `uvm_fatal("ETH_AGENT_CFG", reason)

    tx_monitor = eth_seg_tx_monitor#(RATE)::type_id::create("tx_monitor", this);
    rx_monitor = eth_seg_rx_monitor#(RATE)::type_id::create("rx_monitor", this);
    tx_monitor.cfg = cfg;
    rx_monitor.cfg = cfg;

    if (cfg.is_active == UVM_ACTIVE) begin
      sequencer = eth_seg_sequencer::type_id::create("sequencer", this);
      case (cfg.role)
        ETH_SEG_CLIENT: begin
          tx_driver = eth_seg_tx_driver#(RATE)::type_id::create("tx_driver", this);
          tx_driver.cfg = cfg;
        end
        ETH_SEG_MAC: begin
          rx_driver = eth_seg_rx_driver#(RATE)::type_id::create("rx_driver", this);
          ready_driver = eth_seg_ready_driver#(RATE)::type_id::create("ready_driver", this);
          rx_driver.cfg = cfg;
          ready_driver.cfg = cfg;
        end
        default: `uvm_fatal("ETH_AGENT_ROLE", "unsupported eth_seg_config.role")
      endcase
    end
  endfunction

  // 连接发送 sequencer；MAC 的 RX 与 ready 驱动不使用 sequencer，直接消费配置节奏。
  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg != null && cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == ETH_SEG_CLIENT && tx_driver != null)
        tx_driver.seq_item_port.connect(sequencer.seq_item_export);
      else if (cfg.role == ETH_SEG_MAC && rx_driver != null)
        rx_driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction
endclass
