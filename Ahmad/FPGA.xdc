# Cmod A7 onboard 12 MHz clock
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports {clk12}]
create_clock -name clk12 -period 83.333 [get_ports {clk12}]

# SPI inputs from ESP32
# GPIO13 MOSI -> JA1
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports {spi_mosi}]

# GPIO14 SCLK -> JA3
set_property -dict { PACKAGE_PIN N18 IOSTANDARD LVCMOS33 } [get_ports {spi_sclk}]

# GPIO32 CS -> JA4
set_property -dict { PACKAGE_PIN L18 IOSTANDARD LVCMOS33 } [get_ports {spi_cs_n}]

# SPI output to ESP32
# JA2 -> GPIO33 MISO
set_property -dict { PACKAGE_PIN G19 IOSTANDARD LVCMOS33 } [get_ports {spi_miso}]

# Cmod LEDs
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports {led0}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {led1}]