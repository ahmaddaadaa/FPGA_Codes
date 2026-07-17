set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -add -name sys_clk -period 10.000 -waveform {0 5} [get_ports clk]

set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports rst]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports uart_rx_i]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports uart_tx_o]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports led_busy]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports led_done]

# Nexys A7 LAN8720A RMII interface. The FPGA supplies the 50 MHz REF_CLK.
set_property -dict {PACKAGE_PIN B3  IOSTANDARD LVCMOS33} [get_ports eth_rstn]
set_property -dict {PACKAGE_PIN D5  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports eth_refclk]
set_property -dict {PACKAGE_PIN D9  IOSTANDARD LVCMOS33} [get_ports eth_crsdv]
set_property -dict {PACKAGE_PIN C10 IOSTANDARD LVCMOS33} [get_ports eth_rxerr]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[0]}]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33} [get_ports {eth_rxd[1]}]
set_property -dict {PACKAGE_PIN B9  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports eth_txen]
set_property -dict {PACKAGE_PIN A10 IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd[0]}]
set_property -dict {PACKAGE_PIN A8  IOSTANDARD LVCMOS33 SLEW FAST} [get_ports {eth_txd[1]}]

# Keep TX in the output I/O registers.  Do not pack the RX registers into the
# HR-bank ILOGIC: on this device that inserts ZHOLD_DELAY elements (7.3 ns in
# the routed report), which consumes the LAN8720A's receive-valid window.  The
# RX signals are already isolated from the packet parser by explicit first-stage
# registers in tiny_mlp_uart_ethernet_top.
set_property IOB TRUE  [get_ports {eth_txen eth_txd[*]}]
set_property IOB FALSE [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]

# The registered 50 MHz output is derived from the 100 MHz system clock.
create_generated_clock -name rmii_ref_clk -source [get_ports clk] -divide_by 2 [get_ports eth_refclk]

# Use a virtual copy of the board-side RMII clock for RX constraints.
# Referencing the generated clock directly on returned PHY data includes the
# forwarded ODDR/OBUF latency as source-clock skew even though the data is
# already returned relative to that board-side clock. UG903 recommends a
# virtual clock when an internally generated input reference cannot otherwise
# be represented cleanly.
create_clock -name rmii_io_virtual -period 20.000 -waveform {0.000 10.000}

# LAN8720A RMII timing at 100 Mb/s: RX valid within 14 ns and held 3 ns
# after REF_CLK rising; TX requires 4 ns setup and 1.5 ns hold.  The RX maximum
# includes another 4 ns of conservative allowance for PCB flight time and the
# FPGA-to-PHY forwarded-clock offset.
set_input_delay  -clock rmii_io_virtual -max 18.0 [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]
set_input_delay  -clock rmii_io_virtual -min 3.0  [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]

# TX and the forwarded REF_CLK are both FPGA outputs driven from the same clock
# tree, so the generated clock is the correct reference here. It preserves the
# shared ODDR/OBUF latency instead of imposing an unrealistically early ideal
# virtual-clock edge at the PHY.
set_output_delay -clock rmii_ref_clk -max 4.0  [get_ports {eth_txen eth_txd[*]}]
set_output_delay -clock rmii_ref_clk -min -1.5 [get_ports {eth_txen eth_txd[*]}]

# RX registers are enabled once every two 100 MHz cycles and capture the dibit
# launched by the preceding 50 MHz reference-clock edge.
set_multicycle_path 2 -setup -from [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}] -to [get_clocks sys_clk]
set_multicycle_path 1 -hold  -from [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}] -to [get_clocks sys_clk]

# eth_tx* changes only on rmii_tx_ce, the falling half-cycle of the forwarded
# 50 MHz clock. Static timing cannot infer that phase relationship from a data
# clock-enable, so its same-edge hold check is false. The 10 ns half-cycle is
# still protected by the output setup constraint above and the IOB placement.
set_false_path -hold -to [get_ports {eth_txen eth_txd[*]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
