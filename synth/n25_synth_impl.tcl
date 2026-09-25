# =============================================================================
# N-2.5 / STEP 4 : full NoC-lane synthesis + implementation, crypto OOC synth
# Part xc7a100tcsg324-1, target clock 20.000 ns (50 MHz).  Vivado 2024.1.
#
# NON-PROJECT flow on purpose: reads an explicit file list, so the .xpr's
# AutoDisabled flags, top settings and background refresh cannot interfere,
# and nothing in the project is modified.
#
# HOW TO RUN (Vivado Tcl console):
#   close_project
#   source C:/vivado_verilog_proj/NOC_PQATTEST/synth/n25_synth_impl.tcl
#   (afterwards: open_project C:/vivado_verilog_proj/NOC_PQATTEST/NOC_PQATTEST.xpr)
#
# Outputs: reports/n25_<date>/  (utilization, hierarchical utilization,
# timing summary, top paths) - post-synth AND post-route for the mesh,
# post-synth (out-of-context) for each crypto top.
# No bitstream: only clk is pin-locked (E3, Arty 100 MHz oscillator pin);
# rst/led are auto-placed. This run measures area and timing only.
# =============================================================================
if {[llength [get_projects -quiet]] > 0} {
    error "A project is open. Run 'close_project' first (this is a non-project flow)."
}
set R    C:/vivado_verilog_proj/NOC_PQATTEST
set S    $R/NOC_PQATTEST.srcs/sources_1/new
set PART xc7a100tcsg324-1
set PER  20.000
set DATE [clock format [clock seconds] -format %Y-%m-%d]
set OUT  $R/reports/n25_$DATE
file mkdir $OUT
set LOG  [open $OUT/SUMMARY.txt w]
proc note {msg} { global LOG; puts $msg; puts $LOG $msg; flush $LOG }
note "N-2.5 run [clock format [clock seconds]] | Vivado [version -short] | part $PART | clock ${PER} ns"

# ---------------------------------------------------------------- NoC mesh
set NOC_FILES [list \
    $S/NOC_PKG.sv $S/NOC_FIFO.sv $S/NOC_CROSSBAR.sv $S/NOC_XY_ROUTING.sv \
    $S/NOC_arbiter.sv $S/allocator.sv $S/noc_credit_counter.sv \
    $S/NOC_DATAPTAH.sv $S/noc_router.sv $S/noc_mesh_3x2.sv \
    $R/synth/noc_mesh_synth_top.sv]
foreach f $NOC_FILES { if {![file exists $f]} { error "missing $f" } }
read_verilog -sv $NOC_FILES

note "\n==== MESH: synth_design noc_mesh_synth_top ===="
# Wrapped in catch so a mesh failure still lets the crypto runs report.
if {[catch {
    synth_design -top noc_mesh_synth_top -part $PART
    create_clock -name clk -period $PER [get_ports clk]
    set_property PACKAGE_PIN E3 [get_ports clk]
    set_property IOSTANDARD LVCMOS33 [get_ports {clk rst led}]
    set_false_path -from [get_ports rst]
    set_false_path -to   [get_ports led]

    # Anti-trim proof (Council D3a): six router instances must survive synthesis.
    set routers [get_cells -quiet -hierarchical -regexp {.*GEN_R\[[0-5]\]\.r}]
    note "MESH router instances after synth: [llength $routers] (expected 6)"
    if {[llength $routers] != 6} { note "*** WARNING: router count != 6 - logic may have been trimmed or renamed; inspect hier report ***" }

    report_utilization                                   -file $OUT/mesh_post_synth_util.rpt
    report_utilization -hierarchical -hierarchical_depth 4 -file $OUT/mesh_post_synth_util_hier.rpt
    report_timing_summary -max_paths 10                  -file $OUT/mesh_post_synth_timing.rpt
    note "MESH post-synth WNS (estimate): [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"

    note "\n==== MESH: opt / place / route ===="
    opt_design
    place_design
    route_design
    report_utilization                                   -file $OUT/mesh_post_route_util.rpt
    report_utilization -hierarchical -hierarchical_depth 4 -file $OUT/mesh_post_route_util_hier.rpt
    report_timing_summary -max_paths 10                  -file $OUT/mesh_post_route_timing.rpt
    report_timing -max_paths 5 -nworst 1 -path_type full -file $OUT/mesh_post_route_top5_paths.rpt
    report_route_status                                  -file $OUT/mesh_route_status.rpt
    note "MESH post-route WNS: [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"
    note "MESH post-route WHS: [get_property SLACK [get_timing_paths -max_paths 1 -hold]] ns"
    close_design
} e]} {
    note "*** MESH FAILED: $e"
    catch {close_design}
}

# ---------------------------------------------------------------- crypto OOC
set CRYPTO_FILES [list \
    $S/pq_keccak_pkg.sv $S/SHA3_PKG.sv $S/kmac_pkg.sv $S/pq_kdf_pkg.sv \
    $S/pq_measurement_pkg.sv $S/pqattest_stg7_pkg.sv $S/TRNG_PKG.sv \
    $S/pq_keccak_theta.sv $S/pq_keccak_rho.sv $S/pq_keccak_pi.sv \
    $S/pq_keccak_chi.sv $S/pq_keccak_iota.sv $S/pq_keccak_round.sv \
    $S/pq_keccak_f1600.sv \
    $S/SHA3_PAD.sv $S/SHA3_ABSORB.sv $S/SHA3_256.sv \
    $S/kmac_encode.sv $S/kmac_absorb.sv $S/kmac_128.sv \
    $S/pq_kdf.sv $S/pq_measurement.sv $S/pqattest_stg7.sv \
    $S/TRNG_HEALTH.sv $S/TRNG_CONDITIONER.sv $S/TRNG_TOP.sv]
foreach f $CRYPTO_FILES { if {![file exists $f]} { error "missing $f" } }
read_verilog -sv $CRYPTO_FILES

foreach top {pq_attestation_tag pq_kdf pq_measurement trng_top} {
    note "\n==== CRYPTO OOC: $top ===="
    if {[catch {
        synth_design -top $top -part $PART -mode out_of_context
        create_clock -name clk -period $PER [get_ports clk]
        report_utilization    -file $OUT/crypto_${top}_util.rpt
        report_utilization -hierarchical -hierarchical_depth 3 -file $OUT/crypto_${top}_util_hier.rpt
        report_timing_summary -max_paths 5 -file $OUT/crypto_${top}_timing.rpt
        note "$top post-synth OOC WNS (estimate): [get_property SLACK [get_timing_paths -max_paths 1 -setup]] ns"
        close_design
    } e]} {
        note "*** $top FAILED: $e"
        catch {close_design}
    }
}
note "\nN-2.5 script finished. Reports in $OUT"
close $LOG
