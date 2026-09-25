# N-6 mutation pass (rev 2).
# LESSON (2026-09-23): Tcl 'file copy' PRESERVES the source mtime, and xvlog --incr
# only recompiles a file NEWER than its .sdb. Mutants created in the same second
# were silently skipped (M-b/M-c ran the M-a snapshot). Rev 2 therefore:
#   1. stamps mtime=now after every copy, 2. reset_simulation before every launch,
#   3. proves recompilation by checking noc_router.sdb is newer than the launch,
#   4. ends with a CONTROL run on the restored pristine router (must be 118/0).
# Usage: source this file.  Optional: set N6_MUTANTS {b c} before sourcing.
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set SRC  $R/NOC_PQATTEST.srcs/sources_1/new/noc_router.sv
set XDIR $R/NOC_PQATTEST.sim/sim_1/behav/xsim
set SDB  $XDIR/xsim.dir/xil_defaultlib/noc_router.sdb
if {![info exists N6_MUTANTS]} { set N6_MUTANTS {a b c} }
if {![info exists N6_SUFFIX]}  { set N6_SUFFIX "" }

set_property top tb_n6_two_tile_stress [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
after 5000
set_property -name {xsim.simulate.runtime} -value {1ns} -objects [get_filesets sim_1]

proc n6_run {tag srcfile} {
  global R SRC XDIR SDB N6_SUFFIX
  puts "\n######## $tag ########"
  file copy -force $srcfile $SRC
  after 1100
  file mtime $SRC [clock seconds]
  catch {reset_simulation -simset sim_1 -mode behavioral}
  set t0 [clock seconds]
  set ok 0
  for {set t 0} {$t < 3 && !$ok} {incr t} {
    if {[catch {launch_simulation} e]} { puts "launch retry ($t): $e"; after 5000 } else { set ok 1 }
  }
  if {!$ok} { puts "$tag: launch FAILED 3x"; return }
  if {[file exists $SDB] && [file mtime $SDB] >= $t0} {
    puts "$tag: RECOMPILED noc_router.sdb @ [clock format [file mtime $SDB]]"
  } else {
    puts "$tag: *** noc_router NOT RECOMPILED - RESULT INVALID ***"
  }
  catch {run all}
  catch {close_sim}
  file copy -force $XDIR/simulate.log $R/logs/n6_${tag}${N6_SUFFIX}_2026-09-23.log
  puts "saved logs/n6_${tag}${N6_SUFFIX}_2026-09-23.log"
}

set err [catch {
  foreach m $N6_MUTANTS { n6_run mut_$m $R/mut/noc_router_mut_$m.svmut }
} emsg]

# ALWAYS restore the pristine router, then prove it with a control run.
catch { n6_run control_restored $R/mut/noc_router.sv.orig }
file copy -force $R/mut/noc_router.sv.orig $SRC
file mtime $SRC [clock seconds]
set_property -name {xsim.simulate.runtime} -value {20us} -objects [get_filesets sim_1]
if {$err} { puts "SCRIPT ERROR: $emsg" }
puts "noc_router.sv restored from mut/noc_router.sv.orig (mtime refreshed)"
