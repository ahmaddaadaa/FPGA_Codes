set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -add -name sys_clk -period 10.000 -waveform {0 5} [get_ports clk]

set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} [get_ports rst]
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

set_property IOB TRUE  [get_ports {eth_txen eth_txd[*]}]
set_property IOB FALSE [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]

create_generated_clock -name rmii_ref_clk -source [get_ports clk] -divide_by 2 [get_ports eth_refclk]
create_clock -name rmii_io_virtual -period 20.000 -waveform {0.000 10.000}

set_input_delay  -clock rmii_io_virtual -max 18.0 [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]
set_input_delay  -clock rmii_io_virtual -min 3.0  [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}]
set_output_delay -clock rmii_ref_clk -max 4.0  [get_ports {eth_txen eth_txd[*]}]
set_output_delay -clock rmii_ref_clk -min -1.5 [get_ports {eth_txen eth_txd[*]}]

set_multicycle_path 2 -setup -from [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}] -to [get_clocks sys_clk]
set_multicycle_path 1 -hold  -from [get_ports {eth_crsdv eth_rxerr eth_rxd[*]}] -to [get_clocks sys_clk]
set_false_path -hold -to [get_ports {eth_txen eth_txd[*]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
