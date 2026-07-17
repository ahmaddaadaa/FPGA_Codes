## Pinless constraint for the transport-free P16 accelerator comparison.
##
## The accelerator is synthesized and implemented out of context. Its parameter
## write ports and complete output bus remain primary ports, so Vivado cannot
## constant-fold the memories or arithmetic. No PACKAGE_PIN assignments are
## appropriate because this target is a routed utilization checkpoint, not a
## programmable board image.

create_clock -add -name core_clk -period 10.00 -waveform {0 5} [get_ports { clk }]
