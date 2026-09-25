`timescale 1ns/1ps
// V-10: every module in the design must carry a timescale, otherwise
// elaboration warns "at least one module in design doesn't" and the
// simulator silently applies a default that may differ from the testbench.
module NOC_ARBITER #(
    parameter int N = 15
) (
    input  logic                 clk,
    input  logic                 rst,

    // Request from each input VC
    input  logic [N-1:0]         req,

    // One-hot grant
    output logic [N-1:0]         grant,

    // Grant information
    output logic                 grant_valid,
    output logic [$clog2(N)-1:0] winner
);

    localparam int PTR_W = (N <= 1) ? 1 : $clog2(N);

    logic [PTR_W-1:0] rr_ptr;
    logic [PTR_W-1:0] winner_next;

    logic found;

    // ------------------------------------------------------------
    // Combinational Round-Robin Arbitration
    // ------------------------------------------------------------
    always_comb begin
        grant        = '0;
        grant_valid  = 1'b0;
        winner       = '0;
        winner_next  = rr_ptr;
        found        = 1'b0;

        // Search circularly starting from rr_ptr
        for (int offset = 0; offset < N; offset++) begin

            int index;

            index = rr_ptr + offset;

            // Circular wrap-around
            if (index >= N)
                index = index - N;

            // First active requester wins
            if (!found && req[index]) begin
                grant[index]   = 1'b1;
                grant_valid    = 1'b1;
                winner         = index[PTR_W-1:0];

                // Next arbitration starts after winner
                if (index == N-1)
                    winner_next = '0;
                else
                    winner_next = index + 1;

                found = 1'b1;
            end
        end

        // --------------------------------------------------------------------
        // IMMEDIATE ASSERTIONS, EVALUATED ON THE SAME ATOMIC SNAPSHOT
        //
        // WHY THESE ARE HERE AND NOT CONCURRENT SVA  (defect V-12)
        //
        //   The concurrent versions of these three properties fired 179,984
        //   times in the run of 2026-09-09 while the SAME design passed a
        //   491,520-vector EXHAUSTIVE comparison against an independent Python
        //   model with zero mismatches, and a 20,000-cycle cycle-accurate
        //   comparison with zero output and zero state mismatches.
        //
        //   $sampled() showed why:
        //
        //     SAMPLED : grant=00000000000000000xxxxxxxxxxxxxxx
        //     CURRENT : grant=010000000000000
        //
        //   The preponed region returns X for grant / grant_valid, because
        //   they are combinational outputs of THIS block and rr_ptr updates
        //   via NBA at the same clock edge, re-triggering it. Every failure
        //   was the checker reading a value that never existed on the wire.
        //
        //   Worse, a_onehot_grant never fired - not because it held, but
        //   because $onehot0(X) does not evaluate false. It was an assertion
        //   that COULD NOT FAIL, which per V-07 is worse than none.
        //
        //   This is V-09 again, one level up: in noc_xy_routing the fix was to
        //   collapse compute, qualify and check into a single always_comb so
        //   the checker sees one atomic snapshot. Same fix, same reason.
        //
        //   The guard on $isunknown(req) is required, not cosmetic: before the
        //   first reset req is X, the loop condition is then false, and grant
        //   is legitimately 0 against an undefined request. Flagging that is
        //   the V-01 class of false failure.
        // --------------------------------------------------------------------

`ifndef SYNTHESIS
        // Sim-only checker ($isunknown is not synthesizable - first
        // synthesis run, N-2.5 2026-09-23, Synth 8-280). Same guard
        // pattern as NOC_CROSSBAR.sv. XSim never defines SYNTHESIS, so
        // simulation sees this block exactly as before.
        if (!$isunknown(req)) begin

            a_onehot_grant_imm:
                assert ($onehot0(grant))
                else $error("NOC_ARBITER: grant not one-hot0. grant=%b req=%b rr_ptr=%0d",
                            grant, req, rr_ptr);

            a_grant_implies_request_imm:
                assert ((grant & ~req) == '0)
                else $error("NOC_ARBITER: grant without request. grant=%b req=%b rr_ptr=%0d",
                            grant, req, rr_ptr);

            a_valid_matches_grant_imm:
                assert (grant_valid == (|grant))
                else $error("NOC_ARBITER: grant_valid=%b but |grant=%b. grant=%b req=%b",
                            grant_valid, (|grant), grant, req);

            a_winner_is_granted_imm:
                assert (!grant_valid || grant[winner])
                else $error("NOC_ARBITER: winner=%0d not set in grant=%b",
                            winner, grant);

        end
`endif

    end

    // ------------------------------------------------------------
    // Round-Robin Pointer State
    // ------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            rr_ptr <= '0;
        end
        else begin
            if (grant_valid)
                rr_ptr <= winner_next;
        end
    end

    // ------------------------------------------------------------
    // SVA
    // ------------------------------------------------------------

    // -----------------------------------------------------------------------
    // V-12: THREE CONCURRENT ASSERTIONS WERE DELETED FROM HERE.
    //
    //   a_onehot_grant
    //   a_grant_implies_request
    //   a_valid_matches_grant
    //
    // They sampled grant / grant_valid in the preponed region. Those are
    // combinational outputs of the always_comb above, and rr_ptr updates by
    // NBA on the same clock edge and re-triggers it, so the preponed value is
    // X. $sampled() proved it directly:
    //
    //     SAMPLED : grant=00000000000000000xxxxxxxxxxxxxxx
    //     CURRENT : grant=010000000000000
    //
    // Consequences, both bad in opposite directions:
    //   - a_grant_implies_request and a_valid_matches_grant fired 179,984
    //     times on a design that is provably correct.
    //   - a_onehot_grant never fired, because $onehot0(X) does not evaluate
    //     false. It was an assertion that could not fail.
    //
    // Evidence that the DESIGN is correct, gathered before deleting anything:
    //   - 491,520 / 491,520 exhaustive arbiter vectors match the Python model
    //     exactly. That is the COMPLETE combinational input space: all 2^15
    //     request patterns against all 15 pointer values.
    //   - 20,000 cycles of cycle-accurate allocator comparison: zero output
    //     mismatches, zero reservation-state mismatches.
    //   - The golden testbench's own negative control fired 2 of 2, so those
    //     comparisons were live.
    //
    // The properties are restated as IMMEDIATE assertions inside the
    // always_comb, where they see the same atomic snapshot as the logic that
    // produced them. That is exactly the V-09 resolution in noc_xy_routing,
    // one level up.
    //
    // Kept below: a_pointer_stable_without_grant, which references rr_ptr, a
    // genuine register whose preponed value is well defined; and
    // a_req_not_unknown, which checks an input.
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // INDEPENDENT PROCEDURAL CHECK OF THE SAME TWO PROPERTIES
    //
    // Plain always_ff, no SVA. It samples in the Active region after the
    // clock edge, when the combinational outputs have settled, which is the
    // state a human reading a waveform would call "the value this cycle".
    //
    // This is the control experiment. If the SVA above fires hundreds of times
    // and these counters stay at zero, the properties are broken, not the
    // arbiter - and nobody should touch the arbitration logic. If both agree,
    // the arbiter has a real defect and these counters localise it.
    // -----------------------------------------------------------------------

    // synthesis translate_off
    int unsigned proc_err_grant_wo_req;
    int unsigned proc_err_valid_mismatch;
    int unsigned proc_checks;

    always_ff @(posedge clk) begin
        if (rst) begin
            proc_err_grant_wo_req   <= 0;
            proc_err_valid_mismatch <= 0;
            proc_checks             <= 0;
        end
        else begin
            proc_checks <= proc_checks + 1;

            if ((grant & ~req) != '0)
                proc_err_grant_wo_req <= proc_err_grant_wo_req + 1;

            if (grant_valid !== (|grant))
                proc_err_valid_mismatch <= proc_err_valid_mismatch + 1;
        end
    end
    // synthesis translate_on

    // -----------------------------------------------------------------------
    // Shadow copy of rr_ptr, for the failure message only.
    //
    // $past inside the PROPERTY is fine - it infers its clock from the
    // property's own @(posedge clk). Inside the else ACTION BLOCK there is no
    // clocking context to infer, and XSim rejects it outright:
    //
    //   ERROR: [XSIM 43-4463] Unable to infer clocking event for system
    //   function call "past".
    //
    // A plain shadow register is unambiguous and costs nothing: it feeds only
    // an assertion message, so synthesis optimises it away.
    // -----------------------------------------------------------------------

    logic [PTR_W-1:0] rr_ptr_prev;

    always_ff @(posedge clk) begin
        if (rst) rr_ptr_prev <= '0;
        else     rr_ptr_prev <= rr_ptr;
    end

    // If there is no grant, pointer must remain unchanged.
    a_pointer_stable_without_grant:
        assert property (@(posedge clk)
            disable iff (rst)
            (!grant_valid |=> rr_ptr == $past(rr_ptr))
        )
        else $error("NOC_ARBITER: rr_ptr moved without a grant. rr_ptr=%0d prev=%0d req=%b",
                    rr_ptr, rr_ptr_prev, req);

    // -----------------------------------------------------------------------
    // INPUT HYGIENE
    //
    // req is an INPUT. If it arrives X, the loop condition (!found && req[i])
    // evaluates false, so grant stays 0 and the three assertions above can
    // pass or fail depending on how the simulator reduces X - which reports
    // the arbiter as broken when the real defect is upstream. This separates
    // the two cases at the boundary.
    // -----------------------------------------------------------------------

    a_req_not_unknown:
        assert property (@(posedge clk)
            disable iff (rst)
            !$isunknown(req)
        )
        else $error("NOC_ARBITER: req has X/Z bits: req=%b. Defect is UPSTREAM of this arbiter, not in it.",
                    req);

endmodule