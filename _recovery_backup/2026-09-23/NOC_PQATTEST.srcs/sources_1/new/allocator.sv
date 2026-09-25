//=============================================================================
// Module : NOC_ALLOCATOR
// File   : allocator.sv
//
// Purpose:
//   Combines XY routing, round-robin arbitration and wormhole path
//   reservation into a single router allocation block.
//
// Flow:
//   Input VC
//      -> XY Routing
//      -> Request Matrix
//      -> Round-Robin Arbitration
//      -> Wormhole Reservation
//      -> Grant / XBAR Select / FIFO Read Enable
//
// Architecture:
//   3x2 mesh, 5 physical ports, 3 VCs per input port, 15 input VCs total.
//
// Wormhole protocol:
//   HEAD      : acquire output reservation
//   BODY      : retain reservation
//   TAIL      : release reservation
//   HEAD_TAIL : single-flit packet, no persistent reservation
//
// NOTE:
//   Credit-based flow control is NOT implemented here. fifo_rd_en represents
//   allocation permission only at this stage. It will be gated by downstream
//   credit / transfer permission in Stage 4.
//
// History:
//   A1  Instantiated NOC_XY_ROUTING; the module is noc_xy_routing.
//       SystemVerilog is case sensitive, so this was an unresolved reference
//       and the file could not elaborate.
//
//   A2  Connected four scalar ports (current_x/current_y/dest_x/dest_y).
//       noc_xy_routing takes two coord_t structs. The instantiation now packs
//       the coordinates. The module was deliberately NOT changed to scalar
//       ports, because TB1.sv and TB_GOLDEN.sv both drive coord_t and are
//       already signed off against it.
//
//   A3  Declared route_port as port_e; the module output is port_id_t (a raw
//       vector). Same port_id_t / port_e / port_id_e trap as L-01. The local
//       declaration is now port_id_t and every enum use casts explicitly.
//
//   A4  Added a_owner_presents_body_or_tail - catches the CAUSE of the
//       condition a_input_vc_one_output_max guards.
//
//   A5  Added coverage counters. XSim rejects 'cover property' (XSIM 43-4127).
//
//   A6  FILE RESTORED 2026-09-09. allocator.sv had been overwritten with the
//       contents of stage3_tb.sv, so module NOC_ALLOCATOR existed nowhere in
//       the project and both tb_noc_allocator and any router top level failed
//       to elaborate. It also created a duplicate tb_noc_allocator, since
//       stage3_tb.sv declares that module too.
//=============================================================================

`timescale 1ns/1ps

module NOC_ALLOCATOR #(
    parameter int NUM_PORTS     = noc_pkg::NUM_PORTS,
    parameter int NUM_VCS       = noc_pkg::NUM_VC,
    parameter int NUM_INPUT_VCS = NUM_PORTS * NUM_VCS,

    parameter int COORD_W       = noc_pkg::COORD_WIDTH,

    parameter int INPUT_VC_W =
        (NUM_INPUT_VCS <= 1) ? 1 : $clog2(NUM_INPUT_VCS),

    // A9: widths of the two arbitration stages.
    parameter int IN_ARB_W   = (NUM_VCS   <= 1) ? 1 : $clog2(NUM_VCS),    // 2
    parameter int PORT_SEL_W = (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS)   // 3
) (
    input  logic                         clk,
    input  logic                         rst,

    //-------------------------------------------------------------------------
    // Current router coordinate
    //-------------------------------------------------------------------------
    input  logic [COORD_W-1:0]           current_x,
    input  logic [COORD_W-1:0]           current_y,

    //-------------------------------------------------------------------------
    // Head flit from every input VC
    //-------------------------------------------------------------------------
    input  noc_pkg::flit_t               head_flit [NUM_INPUT_VCS],

    // FIFO status
    input  logic                         fifo_empty [NUM_INPUT_VCS],

    //-------------------------------------------------------------------------
    // Allocation result :  grant[output_port][input_vc]
    //-------------------------------------------------------------------------
    output logic [NUM_INPUT_VCS-1:0]     grant [NUM_PORTS],

    // One valid bit per output port
    output logic [NUM_PORTS-1:0]         grant_valid,

    // Crossbar input VC selected for every output
    output logic [INPUT_VC_W-1:0]        xbar_sel [NUM_PORTS],

    // FIFO read enable for every input VC
    output logic [NUM_INPUT_VCS-1:0]     fifo_rd_en,

    // M9: commit wormhole state only when credit permits an actual transfer.
    input logic [NUM_PORTS-1:0]          transfer_valid
);

    import noc_pkg::*;

    //=========================================================================
    // INTERNAL SIGNALS
    //=========================================================================

    // A3: port_id_t, NOT port_e. This must match the module output type
    //     exactly; an enum port connected to a raw-vector port is where the
    //     original L-01 defect came from.
    noc_pkg::port_id_t route_port  [NUM_INPUT_VCS];
    logic              route_valid [NUM_INPUT_VCS];

    // A2: coordinate packing for noc_xy_routing, which takes coord_t structs.
    //
    //     Header serialisation (noc_pkg):
    //       flit_data[31:29] -> dest_x
    //       flit_data[28:26] -> dest_y
    //
    //     COORD_WIDTH is 3, so both slices are exactly the right width. If
    //     COORD_WIDTH is ever changed this breaks loudly at elaboration rather
    //     than quietly truncating.
    noc_pkg::coord_t cur_coord;
    noc_pkg::coord_t dest_coord [NUM_INPUT_VCS];

    always_comb begin
        cur_coord.x = current_x;
        cur_coord.y = current_y;

        for (int i = 0; i < NUM_INPUT_VCS; i++) begin
            dest_coord[i].x = head_flit[i].flit_data[31:29];
            dest_coord[i].y = head_flit[i].flit_data[28:26];
        end
    end

    // request_matrix[output_port][input_vc]
    logic [NUM_INPUT_VCS-1:0] request_matrix [NUM_PORTS];

    // (A9: the old single-stage arb_grant / arb_winner / arb_valid signals
    //  were removed. Arbitration is now two-stage; see below.)

    // Wormhole reservation state
    logic [NUM_PORTS-1:0]  output_locked;      // 1 = output is reserved
    logic [INPUT_VC_W-1:0] output_owner [NUM_PORTS];

    //=========================================================================
    // M5 - XY ROUTING
    //=========================================================================

    generate

        for (genvar g_vc = 0; g_vc < NUM_INPUT_VCS; g_vc++) begin : GEN_XY

            // A1: module name is lowercase noc_xy_routing.
            noc_xy_routing u_xy_routing (
                .current_coord (cur_coord),
                .dest_coord    (dest_coord[g_vc]),
                .route_port    (route_port[g_vc]),
                .route_valid   (route_valid[g_vc])
            );

        end

    endgenerate

    //=========================================================================
    // REQUEST MATRIX GENERATION
    //
    // FREE OUTPUT   : HEAD / HEAD_TAIL may request the routed output.
    // LOCKED OUTPUT : only the owning input VC may request that output.
    //=========================================================================

    always_comb begin

        for (int p = 0; p < NUM_PORTS; p++) begin
            request_matrix[p] = '0;
        end

        for (int i = 0; i < NUM_INPUT_VCS; i++) begin

            if (!fifo_empty[i]) begin

                //-------------------------------------------------------------
                // Existing wormhole reservation. A locked output can only be
                // requested by its owner.
                //-------------------------------------------------------------
                for (int p = 0; p < NUM_PORTS; p++) begin

                    if (output_locked[p] &&
                        (output_owner[p] == INPUT_VC_W'(i))) begin
                        request_matrix[p][i] = 1'b1;
                    end

                end

                //-------------------------------------------------------------
                // New packet requesting a free output. Only a HEAD or
                // HEAD_TAIL can acquire a new path.
                //-------------------------------------------------------------
                if ((head_flit[i].flit_type == FLIT_HEAD) ||
                    (head_flit[i].flit_type == FLIT_HEAD_TAIL)) begin

                    if (route_valid[i]) begin

                        if (int'(route_port[i]) < NUM_PORTS) begin

                            if (!output_locked[int'(route_port[i])]) begin
                                request_matrix[int'(route_port[i])][i] = 1'b1;
                            end

                        end

                    end

                end

            end

        end

    end

    //=========================================================================
    // A9 : TWO-STAGE SEPARABLE INPUT-FIRST ALLOCATION
    //
    // WHY THIS REPLACED FIVE 15-WAY OUTPUT ARBITERS
    //
    //   noc_router_datapath gives each PHYSICAL INPUT one path to the
    //   crossbar. The previous design ran five independent 15-way arbiters
    //   over the flattened input-VC space, so it could grant
    //
    //       NORTH VC0 -> EAST     and     NORTH VC1 -> WEST
    //
    //   in the same cycle. Both grants are individually legal. The datapath
    //   cannot carry both: fifo_rd_en pops BOTH FIFOs, one flit reaches the
    //   crossbar and the other is destroyed. Silent packet corruption.
    //
    //   Neither stage3_tb nor the golden model could see it - the testbench
    //   used VCs on different ports, and the model modelled the allocator's
    //   decision rather than the datapath's structural limit. It became
    //   visible only when noc_router was written and a_onehot0_north in
    //   noc_router_datapath fired on legal traffic.
    //
    // STAGE 1  per physical input, a 3-way arbiter picks at most ONE VC
    //          AND that VC's single target output.
    // STAGE 2  per output, a 5-way arbiter picks at most ONE physical input.
    //
    //   The hazard is now impossible by construction, not asserted after the
    //   fact.
    //
    // A9-b : STAGE 1 MUST ALSO PICK THE TARGET OUTPUT.
    //
    //   Selecting only the VC is not sufficient, and the golden model caught
    //   this before any RTL was written. The five stage-2 arbiters are
    //   independent, so two different outputs could both select the same
    //   physical input - reintroducing the identical hazard one level up.
    //   Giving each candidate exactly ONE target output makes out_req have at
    //   most one bit per input by construction.
    //
    //   A well-formed VC requests exactly one output anyway (BODY/TAIL only
    //   its reservation, HEAD only its route), so this changes nothing for
    //   legal traffic. It makes the malformed case deterministic instead of
    //   destructive.
    //
    // AREA NOTE: 5 x N=3 plus 5 x N=5 replaces 5 x N=15. NOC_ARBITER is used
    //   UNMODIFIED at both widths - verified by exhaustive model check at
    //   n = 3, 5 and 15: no winner or pointer overflow, grant always one-hot0
    //   and always implies a request, for every reachable pointer value.
    //   Expect a large LUT reduction; do not quote a figure until Phase 2.5.
    //=========================================================================

    //-------------------------------------------------------------------------
    // STAGE 1 signals
    //-------------------------------------------------------------------------

    logic [NUM_VCS-1:0]     in_req      [NUM_PORTS];   // 3 VCs of each port
    logic [NUM_VCS-1:0]     in_grant    [NUM_PORTS];
    logic                   in_valid    [NUM_PORTS];
    logic [IN_ARB_W-1:0]    in_winner   [NUM_PORTS];

    logic                   cand_valid  [NUM_PORTS];
    logic [INPUT_VC_W-1:0]  cand_vc     [NUM_PORTS];   // global 0..14
    logic [PORT_SEL_W-1:0]  cand_out    [NUM_PORTS];   // its ONE target output

    //-------------------------------------------------------------------------
    // STAGE 2 signals
    //-------------------------------------------------------------------------

    logic [NUM_PORTS-1:0]   out_req     [NUM_PORTS];   // 5 physical inputs
    logic [NUM_PORTS-1:0]   out_grant   [NUM_PORTS];
    logic [NUM_PORTS-1:0]   out_valid;
    logic [PORT_SEL_W-1:0]  out_winner  [NUM_PORTS];

    //-------------------------------------------------------------------------
    // STAGE 1 : request per VC = "has a legitimate request on SOME output"
    //
    // Derived from request_matrix, so routing and wormhole rules are already
    // applied. A VC whose only options are locked by someone else has an
    // all-zero row and does not compete - which is what keeps a blocked VC
    // from stealing its port's slot from a VC that could actually move.
    //-------------------------------------------------------------------------

    always_comb begin

        for (int p = 0; p < NUM_PORTS; p++) begin

            in_req[p] = '0;

            for (int v = 0; v < NUM_VCS; v++) begin
                // No 'automatic' declaration here: XSim rejects automatic
                // declarations in unnamed procedural blocks, which already
                // cost a debug cycle in TB1.
                for (int o = 0; o < NUM_PORTS; o++) begin
                    if (request_matrix[o][p * NUM_VCS + v]) begin
                        in_req[p][v] = 1'b1;
                    end
                end
            end

        end

    end

    generate

        for (genvar g_in = 0; g_in < NUM_PORTS; g_in++) begin : GEN_IN_ARB

            NOC_ARBITER #(
                .N(NUM_VCS)
            ) u_in_arbiter (
                .clk         (clk),
                .rst         (rst),
                .req         (in_req[g_in]),
                .grant       (in_grant[g_in]),
                .grant_valid (in_valid[g_in]),
                .winner      (in_winner[g_in])
            );

        end

    endgenerate

    //-------------------------------------------------------------------------
    // STAGE 1 result : candidate VC and its single target output
    //-------------------------------------------------------------------------

    always_comb begin

        for (int p = 0; p < NUM_PORTS; p++) begin

            cand_valid[p] = in_valid[p];
            cand_vc[p]    = INPUT_VC_W'(p * NUM_VCS + int'(in_winner[p]));
            cand_out[p]   = '0;

            if (in_valid[p]) begin
                // Lowest-index output. Unique for well-formed traffic; a
                // deterministic tie-break for malformed traffic.
                for (int o = NUM_PORTS - 1; o >= 0; o--) begin
                    if (request_matrix[o][p * NUM_VCS + int'(in_winner[p])]) begin
                        cand_out[p] = PORT_SEL_W'(o);
                    end
                end
            end

        end

    end

    //-------------------------------------------------------------------------
    // STAGE 2 : at most one bit per input, by construction
    //-------------------------------------------------------------------------

    always_comb begin

        for (int o = 0; o < NUM_PORTS; o++) begin
            out_req[o] = '0;
        end

        for (int p = 0; p < NUM_PORTS; p++) begin
            if (cand_valid[p]) begin
                out_req[int'(cand_out[p])][p] = 1'b1;
            end
        end

    end

    generate

        for (genvar g_out = 0; g_out < NUM_PORTS; g_out++) begin : GEN_ARB

            NOC_ARBITER #(
                .N(NUM_PORTS)
            ) u_arbiter (
                .clk         (clk),
                .rst         (rst),
                .req         (out_req[g_out]),
                .grant       (out_grant[g_out]),
                .grant_valid (out_valid[g_out]),
                .winner      (out_winner[g_out])
            );

        end

    endgenerate

    //=========================================================================
    // WORMHOLE RESERVATION STATE
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            output_locked <= '0;

            for (int p = 0; p < NUM_PORTS; p++) begin
                output_owner[p] <= '0;
            end

        end
        else begin

            for (int p = 0; p < NUM_PORTS; p++) begin

                // M9: raw arbitration is not sufficient to change
                // reservation state; credit-qualified transfer is required.
                if (transfer_valid[p]) begin

                    //-----------------------------------------------------
                    // A10 TRAP. out_winner[p] is a PHYSICAL PORT index
                    // (0..4), NOT a global input-VC index. Indexing
                    // head_flit[] with it reads the wrong flit and silently
                    // corrupts the reservation. The flit type must be looked
                    // up through that port's candidate VC.
                    //-----------------------------------------------------
                    case (head_flit[cand_vc[out_winner[p]]].flit_type)

                        //-----------------------------------------------------
                        // HEAD : acquire and lock the output to the winner.
                        //-----------------------------------------------------
                        FLIT_HEAD: begin
                            if (!output_locked[p]) begin
                                output_locked[p] <= 1'b1;
                                // owner is the GLOBAL input VC, because
                                // BODY/TAIL matching is per-VC.
                                output_owner[p]  <= cand_vc[out_winner[p]];
                            end
                        end

                        //-----------------------------------------------------
                        // BODY : reservation must already belong to this VC.
                        //-----------------------------------------------------
                        FLIT_BODY: begin
                            if (output_locked[p] &&
                                (output_owner[p] == cand_vc[out_winner[p]])) begin
                                output_locked[p] <= 1'b1;
                            end
                        end

                        //-----------------------------------------------------
                        // TAIL : final flit releases the output.
                        //-----------------------------------------------------
                        FLIT_TAIL: begin
                            if (output_locked[p] &&
                                (output_owner[p] == cand_vc[out_winner[p]])) begin
                                output_locked[p] <= 1'b0;
                                output_owner[p]  <= '0;
                            end
                        end

                        //-----------------------------------------------------
                        // HEAD_TAIL : complete packet in one flit, no
                        // persistent reservation. Intentionally a no-op on a
                        // free output; kept explicit so the case is exhaustive
                        // and the intent is readable.
                        //-----------------------------------------------------
                        FLIT_HEAD_TAIL: begin
                            if (!output_locked[p]) begin
                                output_locked[p] <= 1'b0;
                                output_owner[p]  <= '0;
                            end
                        end

                        //-----------------------------------------------------
                        // Illegal encoding protection.
                        //-----------------------------------------------------
                        default: begin
                            output_locked[p] <= output_locked[p];
                            output_owner[p]  <= output_owner[p];
                        end

                    endcase

                end

            end

        end

    end

    //=========================================================================
    // FINAL ALLOCATION CONTROL
    //=========================================================================

    always_comb begin

        grant       = '{default:'0};
        grant_valid = '0;
        xbar_sel    = '{default:'0};
        fifo_rd_en  = '0;

        for (int p = 0; p < NUM_PORTS; p++) begin

            if (out_valid[p]) begin

                //-------------------------------------------------------------
                // The external interface is UNCHANGED: grant[] is still a
                // 15-bit mask over global input VCs and xbar_sel is still a
                // global input-VC index. Only the internal arbitration
                // structure changed, so noc_router and every existing
                // testbench keep working.
                //-------------------------------------------------------------
                grant[p][cand_vc[out_winner[p]]] = 1'b1;
                grant_valid[p]                   = 1'b1;
                xbar_sel[p]                      = cand_vc[out_winner[p]];

                fifo_rd_en[cand_vc[out_winner[p]]] = 1'b1;

            end

        end

    end

    //=========================================================================
    // SVA - OUTPUT MUTUAL EXCLUSION
    //=========================================================================

    generate

        for (genvar s = 0; s < NUM_PORTS; s++) begin : GEN_OUTPUT_SVA

            a_one_winner_per_output:
                assert property (
                    @(posedge clk) disable iff (rst)
                    $onehot0(grant[s])
                )
                else $error("NOC_ALLOCATOR: multiple winners on output %0d, grant=%b",
                            s, grant[s]);

            a_grant_implies_request:
                assert property (
                    @(posedge clk) disable iff (rst)
                    ((grant[s] & ~request_matrix[s]) == '0)
                )
                else $error("NOC_ALLOCATOR: grant without request on output %0d, grant=%b req=%b",
                            s, grant[s], request_matrix[s]);

            a_valid_matches_grant:
                assert property (
                    @(posedge clk) disable iff (rst)
                    (grant_valid[s] == (|grant[s]))
                )
                else $error("NOC_ALLOCATOR: grant_valid mismatch on output %0d, valid=%b grant=%b",
                            s, grant_valid[s], grant[s]);

        end

    endgenerate

    //=========================================================================
    // SVA - ONE INPUT VC CANNOT WIN TWO OUTPUTS
    //=========================================================================

    generate

        for (genvar v = 0; v < NUM_INPUT_VCS; v++) begin : GEN_INPUT_SVA

            a_input_vc_one_output_max:
                assert property (
                    @(posedge clk) disable iff (rst)
                    $countones({grant[0][v], grant[1][v], grant[2][v],
                                grant[3][v], grant[4][v]}) <= 1
                )
                else $error("NOC_ALLOCATOR: VC %0d granted to multiple outputs", v);

        end

    endgenerate

    //=========================================================================
    // SVA - EMPTY FIFO NEVER REQUESTS
    //=========================================================================

    generate

        for (genvar e = 0; e < NUM_INPUT_VCS; e++) begin : GEN_EMPTY_SVA

            a_empty_vc_no_request:
                assert property (
                    @(posedge clk) disable iff (rst)
                    fifo_empty[e] |-> !(
                        request_matrix[0][e] | request_matrix[1][e] |
                        request_matrix[2][e] | request_matrix[3][e] |
                        request_matrix[4][e]
                    )
                )
                else $error("NOC_ALLOCATOR: empty VC %0d generated request", e);

        end

    endgenerate

    //=========================================================================
    // SVA - FIFO READ MUST MATCH GRANT
    //=========================================================================

    generate

        for (genvar r = 0; r < NUM_INPUT_VCS; r++) begin : GEN_READ_SVA

            a_read_only_if_granted:
                assert property (
                    @(posedge clk) disable iff (rst)
                    fifo_rd_en[r] ==
                    (grant[0][r] | grant[1][r] | grant[2][r] |
                     grant[3][r] | grant[4][r])
                )
                else $error("NOC_ALLOCATOR: FIFO read mismatch for VC %0d", r);

        end

    endgenerate

    //=========================================================================
    // SVA - LOCKED OUTPUT MUST HAVE VALID OWNER
    //=========================================================================

    generate

        for (genvar l = 0; l < NUM_PORTS; l++) begin : GEN_LOCK_SVA

            a_locked_output_has_valid_owner:
                assert property (
                    @(posedge clk) disable iff (rst)
                    output_locked[l] |-> (output_owner[l] < NUM_INPUT_VCS)
                )
                else $error("NOC_ALLOCATOR: output %0d locked with invalid owner %0d",
                            l, output_owner[l]);

        end

    endgenerate

    //=========================================================================
    // A9 : ONE PHYSICAL INPUT -> AT MOST ONE OUTPUT
    //
    // THE reason this module was restructured. noc_router_datapath gives each
    // physical input ONE path to the crossbar, so granting two outputs from
    // one input dequeues two flits and delivers one. Silent corruption.
    //
    // Under the two-stage architecture this is impossible by construction:
    // stage 1 emits one candidate per input with ONE target output, so
    // out_req has at most one bit per input. The assertion is kept because a
    // structural argument that is never checked is a structural assumption.
    //=========================================================================

    generate

        for (genvar ip = 0; ip < NUM_PORTS; ip++) begin : GEN_PHYS_INPUT_SVA

            a_one_output_per_physical_input:
                assert property (
                    @(posedge clk) disable iff (rst)
                    $countones({
                        (grant_valid[0] && (xbar_sel[0] / NUM_VCS == ip)),
                        (grant_valid[1] && (xbar_sel[1] / NUM_VCS == ip)),
                        (grant_valid[2] && (xbar_sel[2] / NUM_VCS == ip)),
                        (grant_valid[3] && (xbar_sel[3] / NUM_VCS == ip)),
                        (grant_valid[4] && (xbar_sel[4] / NUM_VCS == ip))
                    }) <= 1
                )
                else $error("NOC_ALLOCATOR: physical input %0d granted to more than one output - datapath cannot carry this", ip);

        end

    endgenerate

    //=========================================================================
    // A4 : A LOCKED OUTPUT'S OWNER MUST BE PRESENTING BODY OR TAIL
    //
    // The request matrix lets the owner of a locked output request that output
    // regardless of flit type. For a well-formed packet the owner's head flit
    // is always BODY or TAIL between the HEAD and the TAIL, so that is safe.
    // If a HEAD ever appears at the owner's head, the packet has no TAIL, the
    // lock will never be released, and the VC can request TWO outputs in the
    // same cycle - the exact condition a_input_vc_one_output_max guards.
    //
    // This assertion catches the cause; that one catches the symptom.
    // stage3_tb T09 drives this deliberately, and expects it to fire.
    //=========================================================================

    generate

        for (genvar w = 0; w < NUM_PORTS; w++) begin : GEN_OWNER_TYPE_SVA

            a_owner_presents_body_or_tail:
                assert property (
                    @(posedge clk) disable iff (rst)
                    (output_locked[w] && !fifo_empty[output_owner[w]]) |->
                    (
                        (head_flit[output_owner[w]].flit_type == FLIT_BODY) ||
                        (head_flit[output_owner[w]].flit_type == FLIT_TAIL)
                    )
                )
                else $error(
                    "NOC_ALLOCATOR: output %0d owner VC %0d presents flit_type %0d mid-packet (expect BODY=1 or TAIL=2)",
                    w, output_owner[w], head_flit[output_owner[w]].flit_type
                );

        end

    endgenerate

    //=========================================================================
    // A5 : COVERAGE COUNTERS
    //
    // XSim does not support 'cover property' (XSIM 43-4127), so coverage is
    // counted in plain RTL and reported by the testbench.
    //
    // WHY THIS EXISTS (V-07):
    //   a_input_vc_one_output_max is the strongest assertion in this file and
    //   it had never been observed to evaluate a non-trivial case. An
    //   assertion whose guarded state is never reached is indistinguishable
    //   from one that is broken. cov_multi_output_request must be driven
    //   non-zero by the directed malformed-packet test (stage3_tb T09) before
    //   this module can be signed off.
    //=========================================================================

    // synthesis translate_off

    //-------------------------------------------------------------------------
    // A7: COVERAGE COUNTERS ARE NOT CLEARED BY RESET.
    //
    // They were, and it destroyed the evidence they exist to provide.
    //
    // stage3_tb T09 reaches the multi-output-request state, prints
    // "VC0 requested 2 outputs, won 2", and the DUT assertion fires - then T09
    // calls reset_dut() to clean up the deliberate corruption it injected.
    // That reset zeroed cov_multi_output_request, so the report printed 0 and
    // declared a COVERAGE HOLE on a run that had demonstrably reached the
    // state one microsecond earlier.
    //
    // Coverage records whether a state was EVER reached across the whole run.
    // Reset is a normal mid-run event here, so tying coverage to it makes the
    // counter measure "reached since the last reset", which is not the
    // question being asked. Initialised at declaration instead.
    //-------------------------------------------------------------------------

    int unsigned cov_multi_output_request = 0;
    int unsigned cov_head_acquire         = 0;
    int unsigned cov_tail_release         = 0;
    int unsigned cov_headtail_no_lock     = 0;
    int unsigned cov_all_outputs_busy     = 0;

    always_ff @(posedge clk) begin

        if (!rst) begin

            for (int i = 0; i < NUM_INPUT_VCS; i++) begin
                if ($countones({request_matrix[0][i], request_matrix[1][i],
                                request_matrix[2][i], request_matrix[3][i],
                                request_matrix[4][i]}) > 1) begin
                    cov_multi_output_request <= cov_multi_output_request + 1;
                end
            end

            for (int p = 0; p < NUM_PORTS; p++) begin
                if (out_valid[p]) begin
                    // A10: out_winner is a PORT index; go through cand_vc.
                    case (head_flit[cand_vc[out_winner[p]]].flit_type)
                        FLIT_HEAD:
                            if (!output_locked[p])
                                cov_head_acquire <= cov_head_acquire + 1;
                        FLIT_TAIL:
                            if (output_locked[p])
                                cov_tail_release <= cov_tail_release + 1;
                        FLIT_HEAD_TAIL:
                            cov_headtail_no_lock <= cov_headtail_no_lock + 1;
                        default: ;
                    endcase
                end
            end

            if (&output_locked) begin
                cov_all_outputs_busy <= cov_all_outputs_busy + 1;
            end

        end

    end
    // synthesis translate_on

endmodule



