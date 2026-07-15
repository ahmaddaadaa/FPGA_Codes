set root [file normalize [file dirname [info script]]]
set build_dir [file join $root build]
set project_dir [file join $build_dir vivado]
set report_dir [file join $build_dir reports]
set hls_dir [file join $build_dir hls solution1 syn verilog]

if {$argc == 1} {
    set hls_dir [file normalize [lindex $argv 0]]
} elseif {$argc != 0} {
    error "Usage: vivado -mode batch -source build_fpga.tcl ?-tclargs <hls-verilog-dir>?"
}

set rtl_dir [file join $root rtl]
set sources [list \
    [file join $rtl_dir mlp_types_pkg.vhd] \
    [file join $rtl_dir sync_ram_s8.vhd] \
    [file join $rtl_dir sync_ram_s32.vhd] \
    [file join $rtl_dir tiny_mlp_accelerator_banked.vhd] \
    [file join $rtl_dir vakili_udp_rmii_endpoint.vhd] \
    [file join $rtl_dir tiny_mlp_ethernet_top.vhd]]
set constraints [file join $root constraints nexysa7_ethernet.xdc]
set hls_sources [glob -nocomplain -directory $hls_dir *.v]

foreach source [concat $sources [list $constraints]] {
    if {![file exists $source]} {
        error "Missing source: $source"
    }
}
if {[llength $hls_sources] == 0} {
    error "No HLS Verilog found in $hls_dir; run build_hls.tcl first"
}

file mkdir $report_dir
create_project vakili_mnist_p16 $project_dir \
    -part xc7a100tcsg324-1 -force
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

foreach source $sources {
    read_vhdl -vhdl2008 $source
}
read_verilog $hls_sources
read_xdc $constraints
set_property top tiny_mlp_ethernet_top [get_filesets sources_1]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {![string match "*Complete*" [get_property STATUS [get_runs synth_1]]]} {
    error "Synthesis failed"
}

open_run synth_1
report_utilization -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -file [file join $report_dir post_synth_timing.rpt]
close_design

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {![string match "*Complete*" [get_property STATUS [get_runs impl_1]]]} {
    error "Implementation failed"
}

open_run impl_1
report_utilization -file [file join $report_dir post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 6 \
    -file [file join $report_dir post_route_utilization_hierarchical.rpt]
report_timing_summary -file [file join $report_dir post_route_timing.rpt]
close_design

set generated [file join $project_dir vakili_mnist_p16.runs impl_1 \
    tiny_mlp_ethernet_top.bit]
set bitstream [file join $build_dir vakili_mnist_p16.bit]
if {![file exists $generated]} {
    error "Bitstream was not generated: $generated"
}
file copy -force $generated $bitstream
puts "Bitstream: $bitstream"
exit
