set root [file normalize [file dirname [info script]]]
set project_dir [file join $root build hls]
set source_dir [file join $root hls]

open_project -reset $project_dir
set_top vakili_r1_p16_top
add_files -cflags "-std=c++14 -I$source_dir" \
    [file join $source_dir vakili_r1_p16.cpp]

open_solution -reset solution1
set_part xc7a100tcsg324-1
create_clock -period 10 -name default
set_clock_uncertainty 1.2
config_compile -pipeline_loops 0
csynth_design

puts "HLS RTL: [file join $project_dir solution1 syn verilog]"
close_project
exit
