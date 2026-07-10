## Clock
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk }]

## Reset button, for example BTNC
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports { rst }]

## USB-UART
set_property -dict { PACKAGE_PIN C4 IOSTANDARD LVCMOS33 } [get_ports { uart_rx_i }]
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports { uart_tx_o }]

## Optional LEDs
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports { led_busy }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { led_done }]