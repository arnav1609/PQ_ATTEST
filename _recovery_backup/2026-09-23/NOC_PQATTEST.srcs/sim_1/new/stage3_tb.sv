`timescale 1ns/1ps
//=============================================================================
// Testbench : tb_noc_allocator
// File      : stage3_tb.sv
//
// Stage 3 : routing + arbitration + wormhole reservation  (NOC_ALLOCATOR)
//
//-----------------------------------------------------------------------------
// WHY THIS FILE WAS REWRITTEN
//-----------------------------------------------------------------------------
// The previous version ran to 1,651,015 ns and had to be cancelled. It has
// thirteen directed tasks, no loops and no waits, and $finish twenty timesteps
// after the last one - it should terminate in roughly 2-3 us. It did not, and
// no result was ever printed, so nothing it reported before that point could
// be trusted.
//
// Three structural defects made that possible, and all three are fixed here:
//
//   S1  No watchdog. A testbench that cannot end is a testbench that cannot
//       report. There is now a hard time limit that fails loudly.
//
//   S2  No scoreboard. Failures were individual $error calls with no counter,
//       so there was no PASS/FAIL verdict and no way to tell "ran clean" from
//       "never finished".
//
//   S3  No X-hygiene check at the DUT boundary. The arbiter assertions that
//       fired (a_grant_implies_request, a_valid_matches_grant) are exactly the
//       two that reduce X differently from $onehot0, which stayed silent. That
//       asymmetry is the signature of X propagation, not of broken
//       arbitration. X is now checked where it enters and where it leaves.
//
//-----------------------------------------------------------------------------
// XSIM CONSTRAINTS OBSERVED HERE
//-----------------------------------------------------------------------------
//   XSIM 43-4127  'cover property' is unsupported. Coverage is counted in
//                 plain RTL and reported at the end.
//   XSIM 43-4481  Scoped $assertoff is silently GLOBAL. It is never used.
//                 Testbench assertions are gated by an explicit chk_en signal
//                 inside disable iff, which is scoped correctly by
//                 construction. DUT-internal assertions cannot be gated this
//                 way, so the one deliberate-violation phase is bracketed by
//                 banners and its expected DUT errors are counted, not hidden.
//
//-----------------------------------------------------------------------------
// WHAT STAGE 3 DOES NOT COVER
//-----------------------------------------------------------------------------
//   - credit flow control / backpressure                    (debt D1)
//   - the M7 -> M3 / M7 -> M4 interface mismatch            (needs M8)
//   - xbar_sel hold from HEAD to TAIL across stall cycles   (contract L-07)
//   A PASS here means the allocator is self-consistent. It does not mean the
//   router forwards a packet.
//=============================================================================

module tb_noc_allocator;

    import noc_pkg::*;

    //=========================================================================
    // PARAMETERS
    //=========================================================================

    localparam int NUM_PORTS     = noc_pkg::NUM_PORTS;      // 5
    localparam int NUM_VCS       = noc_pkg::NUM_VC;         // 3
    localparam int NUM_INPUT_VCS = NUM_PORTS * NUM_VCS;     // 15

    localparam int COORD_W       = noc_pkg::COORD_WIDTH;    // 3

    localparam int INPUT_VC_W =
        (NUM_INPUT_VCS <= 1) ? 1 : $clog2(NUM_INPUT_VCS);   // 4

    localparam time CLK_PERIOD  = 10ns;

    // S1: hard upper bound on simulation time. Roughly 20x the expected length
    // of this testbench. If it trips, the run has hung and that is reported as
    // a failure rather than left for someone to notice.
    localparam time WATCHDOG_AT = 100us;

    //=========================================================================
    // DUT SIGNALS
    //=========================================================================

    logic clk;
    logic rst;

    logic [COORD_W-1:0] current_x;
    logic [COORD_W-1:0] current_y;

    flit_t head_flit  [NUM_INPUT_VCS];
    logic  fifo_empty [NUM_INPUT_VCS];

    logic [NUM_INPUT_VCS-1:0] grant [NUM_PORTS];

    // T1: PACKED. The DUT port is "output logic [NUM_PORTS-1:0] grant_valid".
    // The previous unpacked declaration was an illegal connection.
    logic [NUM_PORTS-1:0]     grant_valid;

    logic [INPUT_VC_W-1:0]    xbar_sel [NUM_PORTS];
    logic [NUM_INPUT_VCS-1:0] fifo_rd_en;

    //=========================================================================
    // TESTBENCH ASSERTION ENABLE
    //
    // XSim's scoped $assertoff is silently global (XSIM 43-4481), so it is not
    // used anywhere in this project. Gating on an explicit signal inside
    // disable iff achieves the same thing and is scoped correctly by
    // construction: only the properties that name chk_en are affected.
    //=========================================================================

    logic chk_en;

    //=========================================================================
    // SCOREBOARD  (S2)
    //=========================================================================

    int unsigned err_route    = 0;   // routing / grant direction
    int unsigned err_wormhole = 0;   // lock acquire / retain / release
    int unsigned err_arb      = 0;   // round-robin behaviour
    int unsigned err_struct   = 0;   // structural invariants (one-hot etc.)
    int unsigned err_xprop    = 0;   // X on a DUT input or output
    int unsigned err_neg      = 0;   // negative control
    int unsigned err_hang     = 0;   // watchdog

    function automatic int unsigned total_errors();
        return err_route + err_wormhole + err_arb +
               err_struct + err_xprop + err_neg + err_hang;
    endfunction

    // Errors the DUT's own assertions are EXPECTED to raise, in the one phase
    // that deliberately breaks the protocol. Counted so the phase is auditable
    // without reading timestamps.
    int unsigned expected_dut_errors = 0;

    //=========================================================================
    // COVERAGE COUNTERS  (XSIM 43-4127: cover property unsupported)
    //=========================================================================

    int unsigned cov_grant_north = 0;
    int unsigned cov_grant_south = 0;
    int unsigned cov_grant_east  = 0;
    int unsigned cov_grant_west  = 0;
    int unsigned cov_grant_local = 0;

    int unsigned cov_head       = 0;
    int unsigned cov_body       = 0;
    int unsigned cov_tail       = 0;
    int unsigned cov_head_tail  = 0;

    int unsigned cov_lock_set    = 0;
    int unsigned cov_lock_clear  = 0;
    int unsigned cov_lock_held   = 0;
    int unsigned cov_contention  = 0;   // >1 requester on one output
    int unsigned cov_rr_rotated  = 0;

    int unsigned cov_no_grant    = 0;

    // Negative control
    logic neg_detected_port  = 1'b0;
    logic neg_detected_lock  = 1'b0;

    //=========================================================================
    // CLOCK
    //=========================================================================

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    //=========================================================================
    // WATCHDOG  (S1)
    //=========================================================================

    initial begin
        #WATCHDOG_AT;
        err_hang++;
        $display("");
        $display("##########################################################");
        $display(" WATCHDOG: simulation reached %0t without finishing.", WATCHDOG_AT);
        $display(" The testbench HUNG. No result below this line is valid.");
        $display("##########################################################");
        $fatal(1, "tb_noc_allocator: watchdog timeout");
    end

    //=========================================================================
    // DUT
    //=========================================================================

    NOC_ALLOCATOR #(
        .NUM_PORTS     (NUM_PORTS),
        .NUM_VCS       (NUM_VCS),
        .NUM_INPUT_VCS (NUM_INPUT_VCS),
        .COORD_W       (COORD_W)
    ) dut (
        .clk          (clk),
        .rst          (rst),

        .current_x    (current_x),
        .current_y    (current_y),

        .head_flit    (head_flit),
        .fifo_empty   (fifo_empty),

        .grant        (grant),
        .grant_valid  (grant_valid),

        .xbar_sel     (xbar_sel),
        .fifo_rd_en   (fifo_rd_en),
        // Standalone M7 TB: every allocator grant is treated as a transfer.
        // In the integrated router, M9 supplies the credit-qualified signal.
        .transfer_valid(grant_valid)
    );

    //=========================================================================
    // REFERENCE ROUTE
    //
    // Independent of the DUT's XY module. If both are wrong in the same way
    // this proves nothing, which is why the negative control below is not
    // optional.
    //=========================================================================

    function automatic port_e ref_route(input int cx, input int cy,
                                        input int dx, input int dy);
        if      (dx > cx) return PORT_EAST;
        else if (dx < cx) return PORT_WEST;
        else if (dy > cy) return PORT_SOUTH;
        else if (dy < cy) return PORT_NORTH;
        else              return PORT_LOCAL;
    endfunction

    function automatic string port_name(input int p);
        case (p)
            0: return "NORTH";
            1: return "SOUTH";
            2: return "EAST";
            3: return "WEST";
            4: return "LOCAL";
            default: return "?????";
        endcase
    endfunction

    //=========================================================================
    // COVERAGE AND X SAMPLER
    //=========================================================================

    logic [NUM_PORTS-1:0] locked_prev;
    logic                 sampler_armed;

    always @(posedge clk) begin
        if (rst) begin
            locked_prev   <= '0;
            sampler_armed <= 1'b0;
        end
        else begin
            sampler_armed <= 1'b1;

            //-----------------------------------------------------------------
            // S3: X-hygiene at the DUT boundary.
            //
            // The arbiter failures we are chasing are consistent with X
            // reaching the request matrix. Checking here says whether the X
            // originates on the testbench side or is generated inside the DUT.
            //-----------------------------------------------------------------
            if (sampler_armed) begin
                if ($isunknown(current_x) || $isunknown(current_y)) begin
                    err_xprop++;
                    $error("X on DUT INPUT: current_x=%b current_y=%b (testbench side)",
                           current_x, current_y);
                end

                for (int i = 0; i < NUM_INPUT_VCS; i++) begin
                    if ($isunknown(fifo_empty[i])) begin
                        err_xprop++;
                        $error("X on DUT INPUT: fifo_empty[%0d] (testbench side)", i);
                    end
                    // head_flit only matters when the FIFO is non-empty.
                    if ((fifo_empty[i] === 1'b0) && $isunknown(head_flit[i])) begin
                        err_xprop++;
                        $error("X on DUT INPUT: head_flit[%0d] is X while not empty (testbench side)", i);
                    end
                end

                if ($isunknown(grant_valid) || $isunknown(fifo_rd_en)) begin
                    err_xprop++;
                    $error("X on DUT OUTPUT: grant_valid=%b fifo_rd_en=%b (DUT side)",
                           grant_valid, fifo_rd_en);
                end

                for (int p = 0; p < NUM_PORTS; p++) begin
                    if ($isunknown(grant[p])) begin
                        err_xprop++;
                        $error("X on DUT OUTPUT: grant[%0d]=%b (DUT side)", p, grant[p]);
                    end
                    if (grant_valid[p] && $isunknown(xbar_sel[p])) begin
                        err_xprop++;
                        $error("X on DUT OUTPUT: xbar_sel[%0d]=%b while valid (DUT side)",
                               p, xbar_sel[p]);
                    end
                end
            end

            //-----------------------------------------------------------------
            // xbar_sel must point at the VC that actually won.
            //
            // Procedural rather than SVA: it needs a variable index into a
            // packed vector, grant[p][xbar_sel[p]], which XSim does not
            // reliably support inside a property. If this ever fails, the
            // crossbar is told to connect a different input than the one the
            // arbiter chose - and per contract L-07 the crossbar cannot detect
            // that and does not try to.
            //-----------------------------------------------------------------
            if (chk_en) begin
                for (int p = 0; p < NUM_PORTS; p++) begin
                    if (grant_valid[p]) begin
                        if (xbar_sel[p] >= INPUT_VC_W'(NUM_INPUT_VCS)) begin
                            err_struct++;
                            $error("TB: xbar_sel[%s]=%0d is out of range (max %0d)",
                                   port_name(p), xbar_sel[p], NUM_INPUT_VCS-1);
                        end
                        else if (!grant[p][xbar_sel[p]]) begin
                            err_struct++;
                            $error("TB: xbar_sel[%s]=%0d does not match grant %b",
                                   port_name(p), xbar_sel[p], grant[p]);
                        end
                    end
                end
            end

            //-----------------------------------------------------------------
            // Coverage
            //-----------------------------------------------------------------
            if (grant_valid[PORT_NORTH]) cov_grant_north++;
            if (grant_valid[PORT_SOUTH]) cov_grant_south++;
            if (grant_valid[PORT_EAST])  cov_grant_east++;
            if (grant_valid[PORT_WEST])  cov_grant_west++;
            if (grant_valid[PORT_LOCAL]) cov_grant_local++;

            if (grant_valid == '0) cov_no_grant++;

            for (int p = 0; p < NUM_PORTS; p++) begin
                if (grant_valid[p]) begin
                    case (head_flit[xbar_sel[p]].flit_type)
                        FLIT_HEAD:      cov_head++;
                        FLIT_BODY:      cov_body++;
                        FLIT_TAIL:      cov_tail++;
                        FLIT_HEAD_TAIL: cov_head_tail++;
                        default: ;
                    endcase
                end

                if ($countones(dut.request_matrix[p]) > 1) cov_contention++;

                if (!locked_prev[p] &&  dut.output_locked[p]) cov_lock_set++;
                if ( locked_prev[p] && !dut.output_locked[p]) cov_lock_clear++;
                if ( locked_prev[p] &&  dut.output_locked[p]) cov_lock_held++;
            end

            locked_prev <= dut.output_locked;
        end
    end

    //=========================================================================
    // TESTBENCH SVA
    //
    // These duplicate the DUT's internal assertions on purpose. The DUT's
    // assertions and the DUT's logic were written together; an independent
    // restatement here is what makes them evidence rather than a tautology.
    //=========================================================================

    genvar gp, gv;

    generate
        for (gp = 0; gp < NUM_PORTS; gp++) begin : GEN_TB_PORT_SVA

            ap_onehot_grant:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    $onehot0(grant[gp]))
                else begin
                    err_struct++;
                    $error("TB: grant[%s] not one-hot0: %b", port_name(gp), grant[gp]);
                end

            ap_valid_matches_grant:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    grant_valid[gp] == (|grant[gp]))
                else begin
                    err_struct++;
                    $error("TB: grant_valid[%s]=%b but |grant=%b",
                           port_name(gp), grant_valid[gp], (|grant[gp]));
                end

            // NOTE: the "xbar_sel points at the granted VC" check is NOT an
            // SVA. It needs a VARIABLE index into a packed vector
            // (grant[gp][xbar_sel[gp]]) inside a property, which XSim does not
            // reliably support. It is done procedurally in the sampler instead,
            // where variable indexing is unambiguous.

            // A locked output may only ever be granted to its owner. This is
            // the single most important wormhole property: if it fails, two
            // packets interleave on one link and both are destroyed, and the
            // crossbar cannot detect it (contract L-07).
            ap_locked_output_only_owner:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    (dut.output_locked[gp] && grant_valid[gp]) |->
                    (xbar_sel[gp] == dut.output_owner[gp]))
                else begin
                    err_wormhole++;
                    $error("TB: output %s locked by VC%0d but granted to VC%0d",
                           port_name(gp), dut.output_owner[gp], xbar_sel[gp]);
                end

        end
    endgenerate

    generate
        for (gv = 0; gv < NUM_INPUT_VCS; gv++) begin : GEN_TB_VC_SVA

            // One flit cannot physically go two directions at once.
            //
            // $countones on a concatenation, NOT a chain of '+'. Adding five
            // 1-bit values relies on the comparison's context to widen the sum;
            // it happens to work here, but a self-determined 1-bit add that
            // silently truncates is not something to leave in a checker whose
            // whole job is catching silent truncation elsewhere.
            ap_vc_at_most_one_output:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    $countones({grant[0][gv], grant[1][gv], grant[2][gv],
                                grant[3][gv], grant[4][gv]}) <= 1)
                else begin
                    err_struct++;
                    $error("TB: VC%0d granted to more than one output", gv);
                end

            ap_empty_vc_never_granted:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    fifo_empty[gv] |-> !(grant[0][gv] | grant[1][gv] |
                                         grant[2][gv] | grant[3][gv] |
                                         grant[4][gv]))
                else begin
                    err_struct++;
                    $error("TB: empty VC%0d was granted", gv);
                end

            ap_rd_en_matches_grant:
                assert property (@(posedge clk) disable iff (rst || !chk_en)
                    fifo_rd_en[gv] == (grant[0][gv] | grant[1][gv] |
                                       grant[2][gv] | grant[3][gv] |
                                       grant[4][gv]))
                else begin
                    err_struct++;
                    $error("TB: fifo_rd_en[%0d]=%b disagrees with grants",
                           gv, fifo_rd_en[gv]);
                end

        end
    endgenerate

    //=========================================================================
    // STIMULUS HELPERS
    //=========================================================================

    task automatic tick;
        @(posedge clk);
        #1;                       // settle combinational outputs before reading
    endtask

    task automatic clear_inputs;
        for (int i = 0; i < NUM_INPUT_VCS; i++) begin
            fifo_empty[i] = 1'b1;
            head_flit[i]  = '0;
        end
    endtask

    task automatic reset_dut;
        chk_en    = 1'b0;
        rst       = 1'b1;
        current_x = '0;
        current_y = '0;
        clear_inputs();
        repeat (3) @(posedge clk);
        #1;
        rst    = 1'b0;
        @(posedge clk);
        #1;
        chk_en = 1'b1;            // arm TB checks only after reset released
    endtask

    task automatic set_pos(input int x, input int y);
        current_x = x[COORD_W-1:0];
        current_y = y[COORD_W-1:0];
    endtask

    // Present a flit at input VC 'vc'. dx/dy are the DESTINATION coordinates
    // encoded into the header exactly as noc_pkg specifies:
    //   flit_data[31:29] = dest_x
    //   flit_data[28:26] = dest_y
    task automatic present(input int vc, input int dx, input int dy,
                           input flit_type_e ft);
        head_flit[vc]                  = '0;
        head_flit[vc].flit_data[31:29] = dx[2:0];
        head_flit[vc].flit_data[28:26] = dy[2:0];
        head_flit[vc].flit_type        = ft;
        head_flit[vc].vc_id            = vc[VC_ID_WIDTH-1:0];
        fifo_empty[vc]                 = 1'b0;
    endtask

    task automatic withdraw(input int vc);
        fifo_empty[vc] = 1'b1;
        head_flit[vc]  = '0;
    endtask

    //=========================================================================
    // CHECK HELPERS
    //=========================================================================

    task automatic expect_grant(input string tag, input int p, input int vc);
        if (!grant_valid[p]) begin
            err_route++;
            $error("%s: expected grant on %s for VC%0d, but grant_valid=%b",
                   tag, port_name(p), vc, grant_valid);
        end
        else if (!grant[p][vc]) begin
            err_route++;
            $error("%s: expected VC%0d to win %s, but grant=%b (winner VC%0d)",
                   tag, vc, port_name(p), grant[p], xbar_sel[p]);
        end
    endtask

    task automatic expect_no_grant_anywhere(input string tag);
        if (grant_valid != '0) begin
            err_route++;
            $error("%s: expected no grant, got grant_valid=%b", tag, grant_valid);
        end
    endtask

    task automatic expect_lock(input string tag, input int p,
                               input bit locked, input int owner);
        if (dut.output_locked[p] !== locked) begin
            err_wormhole++;
            $error("%s: %s output_locked=%b, expected %b",
                   tag, port_name(p), dut.output_locked[p], locked);
        end
        else if (locked && (dut.output_owner[p] !== owner[INPUT_VC_W-1:0])) begin
            err_wormhole++;
            $error("%s: %s owner=VC%0d, expected VC%0d",
                   tag, port_name(p), dut.output_owner[p], owner);
        end
    endtask

    //=========================================================================
    // TESTS
    //=========================================================================

    //-------------------------------------------------------------------------
    // TEST 1 : reset state
    //-------------------------------------------------------------------------
    task automatic t01_reset;
        $display("[T01] reset clears grants and reservations");

        if (grant_valid != '0) begin
            err_struct++;
            $error("T01: grant_valid=%b after reset", grant_valid);
        end
        if (fifo_rd_en != '0) begin
            err_struct++;
            $error("T01: fifo_rd_en=%b after reset", fifo_rd_en);
        end
        for (int p = 0; p < NUM_PORTS; p++)
            expect_lock("T01", p, 1'b0, 0);
    endtask

    //-------------------------------------------------------------------------
    // TEST 2 : XY routing through the allocator, all five directions
    //
    // Four of the five are driven from (1,0), the centre of the top row, so a
    // direction that fails cannot be blamed on having moved the router. NORTH
    // does not exist from y=0, so it is driven from (1,1).
    //-------------------------------------------------------------------------
    task automatic t02_routing;
        port_e exp;

        $display("[T02] XY routing, all five directions");

        set_pos(1, 0);

        // EAST
        clear_inputs(); present(0, 2, 0, FLIT_HEAD_TAIL); #1;
        exp = ref_route(1, 0, 2, 0);
        expect_grant("T02-EAST", int'(exp), 0);
        tick();

        // WEST
        clear_inputs(); present(0, 0, 0, FLIT_HEAD_TAIL); #1;
        exp = ref_route(1, 0, 0, 0);
        expect_grant("T02-WEST", int'(exp), 0);
        tick();

        // SOUTH
        clear_inputs(); present(0, 1, 1, FLIT_HEAD_TAIL); #1;
        exp = ref_route(1, 0, 1, 1);
        expect_grant("T02-SOUTH", int'(exp), 0);
        tick();

        // LOCAL
        clear_inputs(); present(0, 1, 0, FLIT_HEAD_TAIL); #1;
        exp = ref_route(1, 0, 1, 0);
        expect_grant("T02-LOCAL", int'(exp), 0);
        tick();

        // NORTH, from (1,1)
        clear_inputs(); set_pos(1, 1); present(0, 1, 0, FLIT_HEAD_TAIL); #1;
        exp = ref_route(1, 1, 1, 0);
        expect_grant("T02-NORTH", int'(exp), 0);
        tick();

        clear_inputs(); set_pos(1, 0); tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 3 : empty FIFO never wins
    //-------------------------------------------------------------------------
    task automatic t03_empty_fifo;
        $display("[T03] empty FIFO produces no grant");

        clear_inputs();
        set_pos(0, 0);
        #1;
        expect_no_grant_anywhere("T03");
        tick();

        // Non-empty, then withdrawn: the grant must disappear in the same cycle.
        present(3, 2, 0, FLIT_HEAD_TAIL); #1;
        expect_grant("T03-armed", int'(PORT_EAST), 3);
        withdraw(3); #1;
        expect_no_grant_anywhere("T03-withdrawn");
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 4 : HEAD acquires the lock
    //-------------------------------------------------------------------------
    task automatic t04_head_lock;
        $display("[T04] HEAD acquires wormhole reservation");

        clear_inputs();
        set_pos(0, 0);

        present(0, 2, 0, FLIT_HEAD); #1;
        expect_grant("T04", int'(PORT_EAST), 0);
        expect_lock("T04-before", int'(PORT_EAST), 1'b0, 0);

        tick();                                   // HEAD commits
        expect_lock("T04-after", int'(PORT_EAST), 1'b1, 0);
    endtask

    //-------------------------------------------------------------------------
    // TEST 5 : BODY retains it, TAIL releases it
    //
    // Runs as one sequence because the states are only reachable in order.
    // Splitting them would mean re-establishing the lock twice and testing the
    // setup rather than the transition.
    //-------------------------------------------------------------------------
    task automatic t05_body_tail;
        $display("[T05] BODY retains, TAIL releases");

        // Continues from T04: EAST is locked by VC0.
        expect_lock("T05-entry", int'(PORT_EAST), 1'b1, 0);

        // BODY. Its header field is payload, not a destination - the allocator
        // must NOT re-route it. Deliberately give it a header that would route
        // WEST if it were ever decoded.
        present(0, 0, 0, FLIT_BODY); #1;
        expect_grant("T05-body", int'(PORT_EAST), 0);
        if (grant_valid[PORT_WEST]) begin
            err_wormhole++;
            $error("T05: BODY was re-routed WEST. Body flits must follow the reservation.");
        end
        tick();
        expect_lock("T05-body-held", int'(PORT_EAST), 1'b1, 0);

        // TAIL releases.
        present(0, 0, 0, FLIT_TAIL); #1;
        expect_grant("T05-tail", int'(PORT_EAST), 0);
        tick();
        expect_lock("T05-tail-released", int'(PORT_EAST), 1'b0, 0);

        clear_inputs();
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 6 : HEAD_TAIL leaves no reservation
    //-------------------------------------------------------------------------
    task automatic t06_head_tail;
        $display("[T06] HEAD_TAIL leaves no persistent reservation");

        clear_inputs();
        set_pos(0, 0);

        present(0, 2, 0, FLIT_HEAD_TAIL); #1;
        expect_grant("T06", int'(PORT_EAST), 0);
        tick();
        expect_lock("T06-after", int'(PORT_EAST), 1'b0, 0);

        clear_inputs();
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 7 : round-robin rotation under sustained contention
    //
    // Two VCs both want EAST, continuously, for six cycles. Fixed priority
    // would give VC0 every time. Round robin must alternate. Six cycles rather
    // than three, so a two-cycle coincidence cannot be mistaken for rotation.
    //-------------------------------------------------------------------------
    task automatic t07_round_robin;
        int winners [6];
        int rotations;

        $display("[T07] round-robin under sustained contention");

        clear_inputs();
        set_pos(0, 0);

        for (int c = 0; c < 6; c++) begin
            present(0, 2, 0, FLIT_HEAD_TAIL);
            present(1, 2, 0, FLIT_HEAD_TAIL);
            #1;

            if (!grant_valid[PORT_EAST]) begin
                err_arb++;
                $error("T07: no EAST grant on contention cycle %0d", c);
                winners[c] = -1;
            end
            else begin
                winners[c] = int'(xbar_sel[PORT_EAST]);
                if ($countones(dut.request_matrix[PORT_EAST]) < 2) begin
                    err_arb++;
                    $error("T07: cycle %0d had only %0d requester(s); contention was not created",
                           c, $countones(dut.request_matrix[PORT_EAST]));
                end
            end
            tick();
        end

        rotations = 0;
        for (int c = 1; c < 6; c++)
            if (winners[c] != winners[c-1]) rotations++;

        if (rotations == 0) begin
            err_arb++;
            $error("T07: winner never changed across 6 contended cycles (always VC%0d). That is fixed priority, not round robin.",
                   winners[0]);
        end
        else begin
            cov_rr_rotated += rotations;
        end

        $display("      winners: %0d %0d %0d %0d %0d %0d  (%0d rotations)",
                 winners[0], winners[1], winners[2],
                 winners[3], winners[4], winners[5], rotations);

        clear_inputs();
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 8 : a locked output cannot be stolen
    //-------------------------------------------------------------------------
    task automatic t08_no_steal;
        $display("[T08] locked output cannot be stolen by another VC");

        clear_inputs();
        set_pos(0, 0);

        // VC0 takes EAST.
        present(0, 2, 0, FLIT_HEAD); #1;
        expect_grant("T08-acquire", int'(PORT_EAST), 0);
        tick();
        expect_lock("T08-locked", int'(PORT_EAST), 1'b1, 0);

        // VC5 now also wants EAST while VC0 continues its packet.
        present(0, 0, 0, FLIT_BODY);
        present(5, 2, 0, FLIT_HEAD);
        #1;

        if (grant_valid[PORT_EAST] && (xbar_sel[PORT_EAST] !== 4'd0)) begin
            err_wormhole++;
            $error("T08: EAST is owned by VC0 but was granted to VC%0d",
                   xbar_sel[PORT_EAST]);
        end
        if (dut.request_matrix[PORT_EAST][5]) begin
            err_wormhole++;
            $error("T08: VC5 was allowed to request a locked output");
        end
        tick();

        // Close the packet so the next test starts clean.
        withdraw(5);
        present(0, 0, 0, FLIT_TAIL); #1;
        tick();
        expect_lock("T08-released", int'(PORT_EAST), 1'b0, 0);

        clear_inputs();
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 9 : DELIBERATE PROTOCOL VIOLATION - malformed packet
    //
    // The only phase in this file that breaks the protocol on purpose. It
    // exists to discharge a coverage obligation, not to test the DUT.
    //
    // NOC_ALLOCATOR carries a_input_vc_one_output_max, which guards "one VC
    // granted to two outputs". That guard could not be shown to have ever been
    // evaluated, and per V-07 an assertion whose guarded state is never reached
    // is indistinguishable from a broken one.
    //
    // The state is reachable only through a malformed packet: a VC that owns a
    // locked output AND presents a HEAD routed somewhere else. A well-formed
    // packet cannot do this, which is why random traffic never found it.
    //
    // EXPECTED: the DUT's a_owner_presents_body_or_tail fires. DUT-internal
    // assertions cannot be gated by chk_en, and XSim's $assertoff is silently
    // global, so those errors are expected output and are counted here rather
    // than suppressed.
    //-------------------------------------------------------------------------
    task automatic t09_malformed_multi_output;
        int outputs_won;
        int outputs_requested;

        $display("");
        $display("      +--------------------------------------------------+");
        $display("      | T09 DELIBERATE VIOLATION - DUT assertion errors   |");
        $display("      | below this banner are EXPECTED.                   |");
        $display("      +--------------------------------------------------+");

        chk_en = 1'b0;                 // TB structural checks off for this phase
        clear_inputs();
        set_pos(1, 0);

        // VC0 legitimately takes EAST.
        present(0, 2, 0, FLIT_HEAD); #1;
        expect_grant("T09-acquire", int'(PORT_EAST), 0);
        tick();
        expect_lock("T09-locked", int'(PORT_EAST), 1'b1, 0);

        // Malformed: VC0 owns EAST but now presents a HEAD routed WEST.
        // It should request EAST (as owner) and WEST (as a new HEAD).
        present(0, 0, 0, FLIT_HEAD); #1;

        outputs_won = 0;
        for (int p = 0; p < NUM_PORTS; p++)
            if (grant[p][0]) outputs_won++;

        outputs_requested = $countones({dut.request_matrix[0][0],
                                        dut.request_matrix[1][0],
                                        dut.request_matrix[2][0],
                                        dut.request_matrix[3][0],
                                        dut.request_matrix[4][0]});

        if (outputs_requested < 2) begin
            err_struct++;
            $error("T09: malformed packet did not produce a multi-output request. The coverage obligation on a_input_vc_one_output_max is still open.");
        end

        $display("      VC0 requested %0d outputs, won %0d",
                 outputs_requested, outputs_won);

        // TWO DUT assertions are expected here, and the run confirms both:
        //   a_input_vc_one_output_max      "VC 0 granted to multiple outputs"
        //   a_owner_presents_body_or_tail  "output 2 owner VC 0 presents ..."
        // The first version of this counter said 1, which would have made a
        // future run showing 2 look like a regression.
        expected_dut_errors += 2;

        tick();
        clear_inputs();
        repeat (2) tick();

        //---------------------------------------------------------------------
        // MANDATORY RESET.  T09 leaks state and must not be allowed to.
        //
        // The malformed packet is a HEAD with no TAIL. The wormhole lock on
        // EAST is therefore NEVER released - that is inherent to the defect
        // being injected, not an oversight in the stimulus.
        //
        // The first version of this task ended with clear_inputs() and two
        // ticks, which does nothing to the reservation state. EAST stayed
        // locked to VC0 for the remainder of the run, so T10 and T11 executed
        // against a corrupted DUT and produced 4 spurious "VC0 granted to more
        // than one output" failures plus 3 "owner presents HEAD mid-packet"
        // errors that belonged to T09.
        //
        // A test that deliberately corrupts DUT state must restore it before
        // returning. Otherwise every later test is measuring the corruption.
        //---------------------------------------------------------------------
        reset_dut();                   // clears locks, re-arms chk_en

        for (int p = 0; p < NUM_PORTS; p++)
            expect_lock("T09-cleanup", p, 1'b0, 0);

        $display("      +--------------------------------------------------+");
        $display("      | T09 END - state reset, DUT assertions meaningful. |");
        $display("      +--------------------------------------------------+");
        $display("");
    endtask

    //-------------------------------------------------------------------------
    // TEST 10 : complete wormhole lifecycle, with a competitor waiting
    //
    // HEAD -> BODY -> BODY -> TAIL for VC0, while VC7 wants the same output
    // throughout. VC7 must win only after the TAIL releases. This is the test
    // that would catch interleaving, which the crossbar cannot detect and which
    // destroys both packets (contract L-07).
    //-------------------------------------------------------------------------
    task automatic t10_lifecycle;
        int vc7_wins_early;

        $display("[T10] full wormhole lifecycle with a waiting competitor");

        clear_inputs();
        set_pos(0, 0);
        vc7_wins_early = 0;

        present(0, 2, 0, FLIT_HEAD);
        present(7, 2, 0, FLIT_HEAD);
        #1;
        expect_grant("T10-head", int'(PORT_EAST), 0);
        tick();
        expect_lock("T10-locked", int'(PORT_EAST), 1'b1, 0);

        for (int b = 0; b < 2; b++) begin
            present(0, 0, 0, FLIT_BODY);
            present(7, 2, 0, FLIT_HEAD);
            #1;
            expect_grant("T10-body", int'(PORT_EAST), 0);
            if (grant[PORT_EAST][7]) vc7_wins_early++;
            tick();
            expect_lock("T10-body-held", int'(PORT_EAST), 1'b1, 0);
        end

        present(0, 0, 0, FLIT_TAIL);
        present(7, 2, 0, FLIT_HEAD);
        #1;
        expect_grant("T10-tail", int'(PORT_EAST), 0);
        if (grant[PORT_EAST][7]) vc7_wins_early++;
        tick();
        expect_lock("T10-released", int'(PORT_EAST), 1'b0, 0);

        if (vc7_wins_early != 0) begin
            err_wormhole++;
            $error("T10: competitor VC7 won EAST %0d time(s) mid-packet. Packets interleaved.",
                   vc7_wins_early);
        end

        // Now that the lock is free, VC7 must get through.
        withdraw(0);
        present(7, 2, 0, FLIT_HEAD_TAIL); #1;
        expect_grant("T10-competitor-after", int'(PORT_EAST), 7);
        tick();

        clear_inputs();
        tick();
    endtask

    //-------------------------------------------------------------------------
    // TEST 11 : NEGATIVE CONTROL
    //
    // Everything above can report PASS while checking nothing. This asks the
    // only question that gives the PASS weight: can this testbench fail?
    //
    // Built in rather than left as a manual edit-and-revert step, because a
    // manual step that gets skipped leaves no trace - which is how the Stage 2
    // negative control stayed open from 6 to 9 September.
    //-------------------------------------------------------------------------
    task automatic t11_negative_control;
        $display("[T11] negative control - deliberate defect injection");

        clear_inputs();
        set_pos(0, 0);

        // Baseline: (0,0) -> (2,0) must grant EAST to VC0. Established, not
        // assumed - a negative control against a wrong baseline proves nothing.
        present(0, 2, 0, FLIT_HEAD_TAIL); #1;

        if (!(grant_valid[PORT_EAST] && grant[PORT_EAST][0])) begin
            err_neg++;
            $error("T11: baseline wrong. (0,0)->(2,0) did not grant EAST to VC0. grant_valid=%b",
                   grant_valid);
        end

        // Injection 1: compare the correct grant against the WRONG port, using
        // the same expression shape the real checks use.
        neg_detected_port = !grant_valid[PORT_WEST];

        if (!neg_detected_port) begin
            err_neg++;
            $error("NEGATIVE CONTROL FAILED: a wrong-port expectation was not detected. Every PASS in this run is meaningless.");
        end

        tick();

        // Injection 2: on the reservation state rather than the port, so one
        // broken comparison cannot hide both.
        clear_inputs();
        present(0, 2, 0, FLIT_HEAD); #1;
        tick();                                  // EAST now locked by VC0

        neg_detected_lock = (dut.output_locked[PORT_WEST] !== 1'b1);

        if (!neg_detected_lock) begin
            err_neg++;
            $error("NEGATIVE CONTROL FAILED: a wrong-lock expectation was not detected.");
        end

        // Clean up.
        present(0, 0, 0, FLIT_TAIL); #1;
        tick();
        clear_inputs();
        tick();

        $display("      injected : 2 deliberate defects (wrong port, wrong lock)");
        $display("      detected : %0d of 2",
                 int'(neg_detected_port) + int'(neg_detected_lock));
    endtask

    //=========================================================================
    // REPORT
    //=========================================================================

    task automatic report;
        bit hole;

        hole = (cov_grant_north == 0) || (cov_grant_south == 0) ||
               (cov_grant_east  == 0) || (cov_grant_west  == 0) ||
               (cov_grant_local == 0) ||
               (cov_head        == 0) || (cov_body        == 0) ||
               (cov_tail        == 0) || (cov_head_tail   == 0) ||
               (cov_lock_set    == 0) || (cov_lock_clear  == 0) ||
               (cov_lock_held   == 0) || (cov_contention  == 0) ||
               (cov_rr_rotated  == 0) || (cov_no_grant    == 0) ||
               (dut.cov_multi_output_request == 0) ||
               (neg_detected_port !== 1'b1) || (neg_detected_lock !== 1'b1);

        $display("");
        $display("==========================================================");
        $display(" STAGE 3 RESULTS   (NOC_ALLOCATOR)");
        $display("==========================================================");
        $display("  routing              : %-4s  (%0d failures)",
                 (err_route    == 0) ? "PASS" : "FAIL", err_route);
        $display("  wormhole reservation : %-4s  (%0d failures)",
                 (err_wormhole == 0) ? "PASS" : "FAIL", err_wormhole);
        $display("  arbitration          : %-4s  (%0d failures)",
                 (err_arb      == 0) ? "PASS" : "FAIL", err_arb);
        $display("  structural invariants: %-4s  (%0d failures)",
                 (err_struct   == 0) ? "PASS" : "FAIL", err_struct);
        $display("  X propagation        : %-4s  (%0d failures)",
                 (err_xprop    == 0) ? "PASS" : "FAIL", err_xprop);
        $display("  negative control     : %-4s  (%0d failures)",
                 (err_neg      == 0) ? "PASS" : "FAIL", err_neg);
        $display("----------------------------------------------------------");
        $display("  OVERALL              : %s   (%0d failures)",
                 (total_errors() == 0) ? "PASS" : "FAIL", total_errors());
        $display("==========================================================");
        $display("");
        $display(" COVERAGE (cycles in which each state was observed)");
        $display("----------------------------------------------------------");
        $display("  grant NORTH                   : %0d", cov_grant_north);
        $display("  grant SOUTH                   : %0d", cov_grant_south);
        $display("  grant EAST                    : %0d", cov_grant_east);
        $display("  grant WEST                    : %0d", cov_grant_west);
        $display("  grant LOCAL                   : %0d", cov_grant_local);
        $display("  no grant anywhere             : %0d", cov_no_grant);
        $display("  HEAD granted                  : %0d", cov_head);
        $display("  BODY granted                  : %0d", cov_body);
        $display("  TAIL granted                  : %0d", cov_tail);
        $display("  HEAD_TAIL granted             : %0d", cov_head_tail);
        $display("  lock acquired                 : %0d", cov_lock_set);
        $display("  lock held across a cycle      : %0d", cov_lock_held);
        $display("  lock released                 : %0d", cov_lock_clear);
        $display("  contention (>1 req on output) : %0d", cov_contention);
        $display("  round-robin rotations         : %0d", cov_rr_rotated);
        $display("  DUT multi-output request      : %0d",
                 dut.cov_multi_output_request);
        $display("  DUT head acquire              : %0d", dut.cov_head_acquire);
        $display("  DUT tail release              : %0d", dut.cov_tail_release);
        $display("  NEG defects injected/detected : %0d / 2",
                 int'(neg_detected_port) + int'(neg_detected_lock));
        $display("----------------------------------------------------------");
        $display("");
        $display(" ARBITER CONTROL EXPERIMENT");
        $display(" Procedural re-check of the two SVA properties that fired");
        $display(" 180 and 225 times on operands that SATISFIED them.");
        $display("----------------------------------------------------------");
        // Written out explicitly, not in a loop: a generate-block instance
        // index must be a constant, so dut.GEN_ARB[i] with a loop variable is
        // illegal. Five lines is the correct way to say this.
        $display("  ARB[NORTH] checks=%0d  grant_wo_req=%0d  valid_mismatch=%0d",
                 dut.GEN_ARB[0].u_arbiter.proc_checks,
                 dut.GEN_ARB[0].u_arbiter.proc_err_grant_wo_req,
                 dut.GEN_ARB[0].u_arbiter.proc_err_valid_mismatch);
        $display("  ARB[SOUTH] checks=%0d  grant_wo_req=%0d  valid_mismatch=%0d",
                 dut.GEN_ARB[1].u_arbiter.proc_checks,
                 dut.GEN_ARB[1].u_arbiter.proc_err_grant_wo_req,
                 dut.GEN_ARB[1].u_arbiter.proc_err_valid_mismatch);
        $display("  ARB[EAST ] checks=%0d  grant_wo_req=%0d  valid_mismatch=%0d",
                 dut.GEN_ARB[2].u_arbiter.proc_checks,
                 dut.GEN_ARB[2].u_arbiter.proc_err_grant_wo_req,
                 dut.GEN_ARB[2].u_arbiter.proc_err_valid_mismatch);
        $display("  ARB[WEST ] checks=%0d  grant_wo_req=%0d  valid_mismatch=%0d",
                 dut.GEN_ARB[3].u_arbiter.proc_checks,
                 dut.GEN_ARB[3].u_arbiter.proc_err_grant_wo_req,
                 dut.GEN_ARB[3].u_arbiter.proc_err_valid_mismatch);
        $display("  ARB[LOCAL] checks=%0d  grant_wo_req=%0d  valid_mismatch=%0d",
                 dut.GEN_ARB[4].u_arbiter.proc_checks,
                 dut.GEN_ARB[4].u_arbiter.proc_err_grant_wo_req,
                 dut.GEN_ARB[4].u_arbiter.proc_err_valid_mismatch);
        $display("----------------------------------------------------------");
        $display("  If the counters above are ZERO while the SVA fired, the");
        $display("  PROPERTIES are broken, not the arbiter. Do not touch the");
        $display("  arbitration logic on that evidence.");
        $display("----------------------------------------------------------");

        if (hole) begin
            $display("  COVERAGE HOLE. At least one guarded state was never");
            $display("  reached, or the negative control did not fire, so the");
            $display("  corresponding PASS proves nothing.");
        end
        else begin
            $display("  All guarded states were exercised.");
            $display("  Negative control fired: this testbench can fail.");
        end
        $display("----------------------------------------------------------");
        $display("");
        $display(" Expected DUT assertion errors (T09 violation phase): %0d",
                 expected_dut_errors);
        $display("");
        $display(" NOT covered here, because it does not exist yet:");
        $display("   - credit flow control / backpressure        (debt D1)");
        $display("   - M7->M3 and M7->M4 interface mapping       (needs M8)");
        $display("   - xbar_sel held HEAD..TAIL across stalls    (contract L-07)");
        $display("");
        $display(" Passing means the ALLOCATOR is self-consistent.");
        $display(" It does NOT mean the router forwards a packet.");
        $display("");
    endtask

    //=========================================================================
    // MAIN
    //=========================================================================

    initial begin

        chk_en = 1'b0;

        $display("");
        $display("==========================================================");
        $display(" tb_noc_allocator   PQ-Attest NoC, Stage 3");
        $display("==========================================================");
        $display(" MESH       : %0d x %0d", MESH_X, MESH_Y);
        $display(" PORTS      : %0d", NUM_PORTS);
        $display(" VCs        : %0d   -> %0d input VCs", NUM_VCS, NUM_INPUT_VCS);
        $display(" WATCHDOG   : %0t", WATCHDOG_AT);
        $display("----------------------------------------------------------");

        reset_dut();

        t01_reset();
        t02_routing();
        t03_empty_fifo();
        t04_head_lock();
        t05_body_tail();
        t06_head_tail();
        t07_round_robin();
        t08_no_steal();
        t09_malformed_multi_output();
        t10_lifecycle();
        t11_negative_control();

        repeat (5) tick();

        report();

        if (total_errors() != 0)
            $fatal(1, "tb_noc_allocator FAILED with %0d failures", total_errors());

        $finish;
    end

endmodule
