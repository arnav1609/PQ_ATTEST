# N-2.5 GUI flow setup: adds the synth wrapper + constraints to the OPEN
# project and makes noc_mesh_synth_top the synthesis top. Run with the
# project open. Afterwards use Run Synthesis / Run Implementation as usual.
set R C:/vivado_verilog_proj/NOC_PQATTEST
set TOP $R/synth/noc_mesh_synth_top.sv
set XDC $R/synth/n25_mesh.xdc
if {[llength [get_files -quiet $TOP]] == 0} { add_files -norecurse -fileset sources_1 $TOP }
if {[llength [get_files -quiet $XDC]] == 0} { add_files -norecurse -fileset constrs_1 $XDC }
set_property is_enabled true [get_files $TOP]
set_property is_enabled true [get_files $XDC]
set_property top noc_mesh_synth_top [get_filesets sources_1]
after 5000
puts "sources_1 top = [get_property top [get_filesets sources_1]]"
puts "constraints   = [get_files -of_objects [get_filesets constrs_1]]"
