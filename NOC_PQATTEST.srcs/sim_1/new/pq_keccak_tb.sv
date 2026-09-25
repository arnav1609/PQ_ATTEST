`timescale 1ns/1ps
//=============================================================================
// Testbench : tb_keccak_f1600
// File      : pq_keccak_tb.sv
//
// Checks the iterative Keccak-f[1600] core against the team's Python golden
// reference, at EVERY ROUND, not only at the final output.
//
//-----------------------------------------------------------------------------
// WHY THIS FILE WAS REWRITTEN  (defect V-11)
//-----------------------------------------------------------------------------
// The previous version hard-coded 25 expected lanes:
//
//     expected_zero[0][1] = 64'h84d5_ccf9_33c0_478a;
//
// Twenty of the twenty-five were WRONG - transposed, not mistyped. The Python
// reference prints the state with y as the OUTER loop:
//
//     for y in range(5):
//         row = [f"{state[x][y]:016x}" for x in range(5)]
//
// so printed row 0 is state[0][0] state[1][0] ... state[4][0]. The testbench
// read the printed row index as the FIRST subscript. Only the five diagonal
// lanes happened to land correctly.
//
// The RTL was correct. Running that testbench would have reported twenty lane
// failures against a correct implementation, and the natural response is to
// start "fixing" theta/rho/pi/chi. That is exactly V-01, where 36 "VC leaked"
// failures were a wrong property rather than a wrong DUT.
//
// Fix: expected values are no longer transcribed by hand. They are generated
// by gen_keccak_vectors.py directly in the RTL's own [x][y] order and read
// with $readmemh.
//
//-----------------------------------------------------------------------------
// WHY PER-ROUND CHECKPOINTS  (implementation plan, section 5)
//-----------------------------------------------------------------------------
// The plan requires comparing "at meaningful internal checkpoints, not only
// final output". A final-only check tells you round 24 is wrong and nothing
// about which of the five step modules caused it. A per-round check fails at
// round 0 and points at one module.
//
//-----------------------------------------------------------------------------
// NEGATIVE CONTROL  (Stage 2 sign-off criterion 5)
//-----------------------------------------------------------------------------
// PHASE 3 deliberately corrupts one expected lane and requires the checker to
// report a failure. A testbench that has never been shown to fail is not
// evidence of anything. This is built in rather than left as a manual step.
//=============================================================================

module tb_keccak_f1600;

    import keccak_pkg::*;

    //=========================================================================
    // VECTOR FILE
    //
    // Overridable from the command line:
    //     xelab -d KECCAK_VEC_FILE=\"...\" ...
    // Default is the absolute path of the checked-in file, because XSim's
    // working directory is the sim run directory, not the source directory.
    //=========================================================================

`ifndef KECCAK_VEC_FILE
  `define KECCAK_VEC_FILE \
    "C:/vivado_verilog_proj/NOC_PQATTEST/NOC_PQATTEST.srcs/sim_1/new/keccak_rounds.memh"
`endif

    localparam int LANES_PER_STATE = STATE_DIM * STATE_DIM;   // 25
    localparam int TOTAL_LANES     = NUM_ROUNDS * LANES_PER_STATE;

    // index = round*25 + x*5 + y
    lane_t golden [0:TOTAL_LANES-1];

    //=========================================================================
    // DUT SIGNALS
    //=========================================================================

    logic   clk;
    logic   rst;
    logic   start;
    state_t state_in;

    state_t state_out;
    logic   busy;
    logic   done;
    logic   round_valid;
    round_t round_index;

    //=========================================================================
    // SCOREBOARD
    //=========================================================================

    int unsigned checks_done;
    int unsigned lane_failures;
    int unsigned rounds_seen;
    int unsigned final_failures;

    // Negative-control bookkeeping
    bit          neg_ctrl_active;
    int unsigned neg_ctrl_hits;
    lane_t       neg_ctrl_saved;
    localparam int NEG_CTRL_INDEX = 0 * LANES_PER_STATE + 3 * STATE_DIM + 2;
                                                        // round 0, lane [3][2]

    //=========================================================================
    // DUT
    //=========================================================================

    keccak_f1600 u_dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .state_in    (state_in),
        .state_out   (state_out),
        .busy        (busy),
        .done        (done),
        .round_valid (round_valid),
        .round_index (round_index)
    );

    //=========================================================================
    // CLOCK
    //=========================================================================

    initial clk = 1'b0;
    always #5 clk = ~clk;

    //=========================================================================
    // PER-ROUND CHECKER
    //
    // Sampled on the NEGATIVE edge on purpose. round_valid, round_index and
    // state_out are all updated by the same posedge; reading them from a
    // posedge-triggered block in the testbench is a race between two
    // procedural blocks. Sampling half a cycle later removes the race without
    // needing a clocking block, and there is no setup requirement being
    // checked here.
    //=========================================================================

    int idx;   // declared here, not inside the loop: XSim rejects automatic
               // declarations in unnamed procedural blocks.

    always @(negedge clk) begin

        if (!rst && round_valid) begin

            rounds_seen++;

            for (int x = 0; x < STATE_DIM; x++) begin
                for (int y = 0; y < STATE_DIM; y++) begin

                    idx = int'(round_index) * LANES_PER_STATE +
                          x * STATE_DIM + y;

                    checks_done++;

                    if (state_out[x][y] !== golden[idx]) begin

                        lane_failures++;

                        if (neg_ctrl_active) begin
                            neg_ctrl_hits++;
                        end
                        else if (lane_failures <= 10) begin
                            $error(
                              "ROUND %0d lane [%0d][%0d] : got %016h exp %016h",
                              round_index, x, y, state_out[x][y], golden[idx]
                            );
                        end

                    end

                end
            end

        end

    end

    //=========================================================================
    // TASKS
    //=========================================================================

    task automatic do_reset();
        rst   = 1'b1;
        start = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk);
    endtask

    task automatic run_permutation();
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // 24 rounds + DONE, with generous margin. A hang here is a real
        // failure, not a timing guess, so it is bounded and reported.
        fork
            begin
                wait (done === 1'b1);
            end
            begin
                repeat (200) @(posedge clk);
                $error("TIMEOUT: done never asserted");
            end
        join_any
        disable fork;
    endtask

    task automatic check_final();
        int fidx;
        for (int x = 0; x < STATE_DIM; x++) begin
            for (int y = 0; y < STATE_DIM; y++) begin
                fidx = (NUM_ROUNDS - 1) * LANES_PER_STATE + x * STATE_DIM + y;
                if (state_out[x][y] !== golden[fidx]) begin
                    final_failures++;
                    $error("FINAL lane [%0d][%0d] : got %016h exp %016h",
                           x, y, state_out[x][y], golden[fidx]);
                end
            end
        end
    endtask

    task automatic clear_counters();
        checks_done    = 0;
        lane_failures  = 0;
        rounds_seen    = 0;
        final_failures = 0;
    endtask

    //=========================================================================
    // MAIN
    //=========================================================================

    initial begin

        int unsigned p1_checks, p1_fail, p1_rounds, p1_final;

        neg_ctrl_active = 1'b0;
        neg_ctrl_hits   = 0;
        clear_counters();

        //---------------------------------------------------------------------
        // Load golden vectors
        //---------------------------------------------------------------------

        for (int i = 0; i < TOTAL_LANES; i++) begin
            golden[i] = 64'hxxxx_xxxx_xxxx_xxxx;
        end

        $readmemh(`KECCAK_VEC_FILE, golden);

        // A $readmemh that silently fails to open leaves the array at X and
        // every comparison then "passes" as a mismatch or fails for the wrong
        // reason. TB_GOLDEN had exactly this hazard. Check it explicitly.
        if (^golden[0] === 1'bx || ^golden[TOTAL_LANES-1] === 1'bx) begin
            $fatal(1,
              "VECTOR LOAD FAILED: %s could not be read, or is short. Run gen_keccak_vectors.py.",
              `KECCAK_VEC_FILE);
        end

        $display("=======================================================");
        $display(" tb_keccak_f1600");
        $display(" vectors : %s", `KECCAK_VEC_FILE);
        $display(" loaded  : %0d lanes (%0d rounds x %0d lanes)",
                 TOTAL_LANES, NUM_ROUNDS, LANES_PER_STATE);
        $display("=======================================================");

        //---------------------------------------------------------------------
        // PHASE 1 : zero-state permutation, checked every round
        //---------------------------------------------------------------------

        $display("\n[PHASE 1] all-zero input, per-round comparison");

        state_in = '{default:'0};
        do_reset();
        clear_counters();
        run_permutation();
        @(negedge clk);
        check_final();

        p1_checks = checks_done;
        p1_fail   = lane_failures;
        p1_rounds = rounds_seen;
        p1_final  = final_failures;

        $display("  rounds observed  : %0d (expected %0d)", p1_rounds, NUM_ROUNDS);
        $display("  lane comparisons : %0d (expected %0d)",
                 p1_checks, NUM_ROUNDS * LANES_PER_STATE);
        $display("  lane mismatches  : %0d", p1_fail);
        $display("  final mismatches : %0d", p1_final);

        //---------------------------------------------------------------------
        // PHASE 2 : back-to-back run, same input, must be repeatable
        //
        // Catches state that survives a completed permutation - a round
        // counter that does not reload, or a state register that is not
        // re-captured on start.
        //---------------------------------------------------------------------

        $display("\n[PHASE 2] second permutation without reset (repeatability)");

        clear_counters();
        state_in = '{default:'0};
        run_permutation();
        @(negedge clk);
        check_final();

        $display("  rounds observed  : %0d", rounds_seen);
        $display("  lane mismatches  : %0d", lane_failures);
        $display("  final mismatches : %0d", final_failures);

        if (rounds_seen != NUM_ROUNDS)
            $error("PHASE 2: expected %0d rounds, saw %0d", NUM_ROUNDS, rounds_seen);

        p1_fail  += lane_failures;
        p1_final += final_failures;

        //---------------------------------------------------------------------
        // PHASE 3 : NEGATIVE CONTROL
        //
        // Corrupt one known-good expected lane and require the checker to see
        // it. If this phase reports zero hits, the checker is not checking and
        // PHASE 1 and 2 mean nothing.
        //---------------------------------------------------------------------

        $display("\n[PHASE 3] negative control - deliberate defect injection");

        neg_ctrl_saved         = golden[NEG_CTRL_INDEX];
        golden[NEG_CTRL_INDEX] = neg_ctrl_saved ^ 64'h1;   // single-bit flip
        neg_ctrl_active        = 1'b1;
        neg_ctrl_hits          = 0;

        clear_counters();
        state_in = '{default:'0};
        do_reset();
        run_permutation();
        @(negedge clk);

        neg_ctrl_active        = 1'b0;
        golden[NEG_CTRL_INDEX] = neg_ctrl_saved;           // restore

        $display("  injected  : round 0 lane [3][2], one bit flipped");
        $display("  detected  : %0d mismatch(es)", neg_ctrl_hits);

        if (neg_ctrl_hits == 0) begin
            $error("NEGATIVE CONTROL FAILED: the checker did not detect an injected defect. Every PASS in this file is meaningless until this is fixed.");
        end
        else if (neg_ctrl_hits != 1) begin
            $display("  note      : %0d hits; expected exactly 1. A single-lane",
                     neg_ctrl_hits);
            $display("              corruption should produce a single-lane failure.");
        end

        //---------------------------------------------------------------------
        // PHASE 4 : reset behaviour
        //---------------------------------------------------------------------

        $display("\n[PHASE 4] reset clears state and control");

        do_reset();
        @(negedge clk);

        if (busy !== 1'b0) $error("PHASE 4: busy asserted after reset");
        if (done !== 1'b0) $error("PHASE 4: done asserted after reset");

        for (int x = 0; x < STATE_DIM; x++)
            for (int y = 0; y < STATE_DIM; y++)
                if (state_out[x][y] !== 64'd0)
                    $error("PHASE 4: state_out[%0d][%0d] not cleared by reset", x, y);

        //---------------------------------------------------------------------
        // SUMMARY
        //---------------------------------------------------------------------

        $display("\n=======================================================");
        $display(" SUMMARY");
        $display("   per-round lane comparisons : %0d", p1_checks);
        $display("   lane mismatches            : %0d", p1_fail);
        $display("   final-state mismatches     : %0d", p1_final);
        $display("   negative control detected  : %0d", neg_ctrl_hits);

        if (p1_fail == 0 && p1_final == 0 &&
            p1_rounds == NUM_ROUNDS && neg_ctrl_hits > 0) begin
            $display(" OVERALL : PASS");
        end
        else begin
            $display(" OVERALL : FAIL");
        end
        $display("=======================================================");

        $finish;

    end

endmodule
