# N-8.1 XSim regression (NI endpoint containment, 10d/10e).
# Each run: clean snapshot, recompile proof, simulate.log copied AFTER close_sim.
#   tb_ni_n81  4 configs: MAC off/on x W=16/1          -> logs/n81_ni_{m0w16,m0w1,m1w16,m1w1}_<date>.log
#   tb_noc_ni  (existing NI TB, updated for N-8.1)       -> logs/n81_nitb_<date>.log
#   tb_n6_two_tile_stress (NIs WD_LIMIT=64 in the TB)    -> logs/n81_n6_<date>.log
#   Router-only TBs (N-7, M8, TB1) are NOT rerun here: no router file changed;
#   NOC_PKG.sv only gained a default-preserving `ifdef PQ_MAC_ON.
# Usage (Vivado Tcl console, project open, no simulation running):
#   source C:/vivado_verilog_proj/NOC_PQATTEST/scripts/n81_xsim.tcl
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set XDIR $R/NOC_PQATTEST.sim/sim_1/behav/xsim
set DATE [clock format [clock seconds] -format %Y-%m-%d]
set SIM  [get_filesets sim_1]
set CO   {xsim.compile.xvlog.more_options}
set CO_SAVED [get_property $CO $SIM]

# Make sure the new TB is in sim_1 and enabled.
set TBF $R/NOC_PQATTEST.srcs/sim_1/new/tb_ni_n81.sv
if {[llength [get_files -quiet -of_objects $SIM $TBF]] == 0} {
  add_files -fileset sim_1 -norecurse $TBF
  puts "added tb_ni_n81.sv to sim_1"
}
foreach f {noc_network_interface.sv noc_addr_decoder.sv} {
  catch {set_property is_enabled true [get_files -quiet */$f]}
}
update_compile_order -fileset sim_1

proc n81_run {top tag defs} {
  global R XDIR DATE SIM CO CO_SAVED
  puts "\n######## $tag ($top) defines={$defs} ########"
  set_property top $top $SIM
  set_property top_lib xil_defaultlib $SIM
  set opts $CO_SAVED
  foreach d $defs { append opts " -d $d" }
  set_property -name $CO -value [string trim $opts] -objects $SIM
  after 5000
  catch {reset_simulation -simset sim_1 -mode behavioral}
  set_property -name {xsim.simulate.runtime} -value {1ns} -objects $SIM
  set t0 [clock seconds]
  set ok 0
  for {set t 0} {$t < 3 && !$ok} {incr t} {
    if {[catch {launch_simulation} e]} { puts "launch retry ($t): $e"; after 5000 } else { set ok 1 }
  }
  if {!$ok} { puts "$tag: launch FAILED 3x"; return }
  set sdb $XDIR/xsim.dir/xil_defaultlib/${top}.sdb
  if {[file exists $sdb] && [file mtime $sdb] >= $t0} {
    puts "$tag: RECOMPILED ${top}.sdb @ [clock format [file mtime $sdb]]"
  } else {
    puts "$tag: *** ${top} NOT RECOMPILED - RESULT INVALID ***"
  }
  catch {run all}
  catch {close_sim}
  file copy -force $XDIR/simulate.log $R/logs/${tag}_${DATE}.log
  puts "saved logs/${tag}_${DATE}.log"
}

set err [catch {
  n81_run tb_ni_n81             n81_ni_m0w16 {}
  n81_run tb_ni_n81             n81_ni_m0w1  {N81_W=1}
  n81_run tb_ni_n81             n81_ni_m1w16 {PQ_MAC_ON}
  n81_run tb_ni_n81             n81_ni_m1w1  {PQ_MAC_ON N81_W=1}
  n81_run tb_noc_ni             n81_nitb     {}
  n81_run tb_n6_two_tile_stress n81_n6       {}
} emsg]
set_property -name $CO -value $CO_SAVED -objects $SIM
set_property -name {xsim.simulate.runtime} -value {20us} -objects $SIM
set_property top tb_noc_mesh_n7 $SIM
if {$err} { puts "SCRIPT ERROR: $emsg" }
puts "N-8.1 XSim finished. Verilator reference (same sources): tb_ni_n81 m0w16 115/0, m0w1 114/0,"
puts "m1w16 113/0, m1w1 112/0 (difference = SKIPs); tb_noc_ni 161/0; N-6 126/0."
foreach t {n81_ni_m0w16 n81_ni_m0w1 n81_ni_m1w16 n81_ni_m1w1 n81_nitb n81_n6} {
  set f $R/logs/${t}_${DATE}.log
  if {![file exists $f]} { puts [format "%-14s NO LOG" $t]; continue }
  set fh [open $f r]; set txt [read $fh]; close $fh
  set res "?"; regexp {RESULT\s*[:=]\s*(\S+)} $txt -> res
  set nf [regexp -all {\[FAIL\]} $txt]; set na [regexp -all {Assertion|Error:} $txt]
  puts [format "%-14s RESULT=%-5s FAIL-lines=%d assert/error-lines=%d" $t $res $nf $na]
}
