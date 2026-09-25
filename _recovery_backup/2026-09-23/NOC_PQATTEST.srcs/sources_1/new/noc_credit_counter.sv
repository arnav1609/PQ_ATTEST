//=============================================================================
// File        : noc_credit_control.sv
// Project     : PQ-Attest NoC
// Module      : M9 - Credit Flow Control
//
// Purpose:
//     Sender-side credit accounting for wormhole, credit-based flow control.
//
// Responsibilities:
//     1. Maintain one credit counter per output-port x VC.
//     2. Initialize every counter to the corresponding downstream FIFO depth.
//     3. Permit transmission only when credit > 0.
//     4. Decrement credit on an actual transmitted flit.
//     5. Increment credit when downstream returns a credit.
//     6. Correctly handle simultaneous send + credit return.
//     7. Never allow credit to underflow or exceed FIFO depth.
//
// Does NOT:
//     - perform arbitration
//     - perform routing
//     - store flits
//     - generate the downstream credit pulse
//
// M7 -> M9 -> M4:
//
//     M7 grant
//          |
//          v
//     M9 credit qualification
//          |
//          +---- grant_valid_qualified
//          |
//          +---- fifo_rd_en
//          |
//          v
//     M4 FIFO dequeue
//
// Downstream M4 credit_valid -> credit_return -> M9
//=============================================================================

module noc_credit_control #(
    parameter int unsigned NUM_PORTS = noc_pkg::NUM_PORTS,
    parameter int unsigned NUM_VC    = noc_pkg::NUM_VC,

    parameter int unsigned VC0_DEPTH = noc_pkg::VC0_DEPTH,
    parameter int unsigned VC1_DEPTH = noc_pkg::VC1_DEPTH,
    parameter int unsigned VC2_DEPTH = noc_pkg::VC2_DEPTH
)(
    input  logic clk,
    input  logic rst,

    //=========================================================================
    // M7 ALLOCATOR OUTPUT
    //
    // grant[p][i] = output p is granted to input VC i
    //=========================================================================
    input logic [NUM_PORTS*NUM_VC-1:0] grant [NUM_PORTS],

    input logic [NUM_PORTS-1:0] grant_valid,

    // xbar_sel[p] = global input-VC index selected for output p
    input logic [((NUM_PORTS*NUM_VC <= 1) ? 1 :
                  $clog2(NUM_PORTS*NUM_VC))-1:0] xbar_sel [NUM_PORTS],

    //=========================================================================
    // CREDIT RETURN
    //
    // credit_return[p][v] means that one slot has become free in the
    // downstream FIFO associated with output p / VC v.
    //
    // The physical link mapping is performed by M8/M12 integration.
    //=========================================================================
    input logic [NUM_VC-1:0] credit_return [NUM_PORTS],

    //=========================================================================
    // CREDIT STATUS
    //=========================================================================
    output logic [NUM_PORTS-1:0] credit_ok,

    // M7 grant after credit qualification.
    output logic [NUM_PORTS-1:0] grant_valid_qualified,

    //=========================================================================
    // ACTUAL FIFO READ ENABLE
    //
    // This replaces the raw M7 fifo_rd_en at M8 integration.
    //=========================================================================
    output logic [NUM_PORTS*NUM_VC-1:0] fifo_rd_en
);

    //=========================================================================
    // CONSTANTS
    //=========================================================================

    localparam int unsigned NUM_INPUT_VCS = NUM_PORTS * NUM_VC;

    localparam int unsigned INPUT_VC_W =
        (NUM_INPUT_VCS <= 1) ? 1 : $clog2(NUM_INPUT_VCS);

    localparam int unsigned MAX_DEPTH =
        (VC0_DEPTH > VC1_DEPTH) ?
            ((VC0_DEPTH > VC2_DEPTH) ? VC0_DEPTH : VC2_DEPTH) :
            ((VC1_DEPTH > VC2_DEPTH) ? VC1_DEPTH : VC2_DEPTH);

    localparam int unsigned CREDIT_W =
        (MAX_DEPTH <= 1) ? 1 : $clog2(MAX_DEPTH + 1);

    //=========================================================================
    // CREDIT COUNTERS
    //
    // credit_count[p][v] = number of free slots available downstream.
    //=========================================================================

    logic [CREDIT_W-1:0] credit_count [NUM_PORTS][NUM_VC];

    // Actual selected VC for every output.
    logic [1:0] selected_vc [NUM_PORTS];

    // Actual send event for every output.
    logic send_event [NUM_PORTS];

    //=========================================================================
    // DEPTH FUNCTION
    //=========================================================================

    function automatic int unsigned vc_depth(input int unsigned vc);
        begin
            case (vc)
                0:       vc_depth = VC0_DEPTH;
                1:       vc_depth = VC1_DEPTH;
                2:       vc_depth = VC2_DEPTH;
                default: vc_depth = 0;
            endcase
        end
    endfunction

    //=========================================================================
    // CREDIT / GRANT QUALIFICATION
    //
    // Combinational:
    //
    //     M7 grant
    //          +
    //     current credit
    //          |
    //          v
    //     actual transfer permission
    //=========================================================================

    always_comb begin

        credit_ok            = '0;
        grant_valid_qualified = '0;
        fifo_rd_en           = '0;

        for (int p = 0; p < NUM_PORTS; p++) begin

            selected_vc[p] = '0;
            send_event[p]  = 1'b0;

            //-----------------------------------------------------------------
            // Only a valid M7 grant can cause a transfer.
            //-----------------------------------------------------------------

            if (grant_valid[p]) begin

                if (int'(xbar_sel[p]) < NUM_INPUT_VCS) begin

                    //-----------------------------------------------------------------
                    // Global input VC -> VC number
                    //
                    // 0,1,2   -> VC0,VC1,VC2
                    // 3,4,5   -> VC0,VC1,VC2
                    // ...
                    //-----------------------------------------------------------------

                    selected_vc[p] = xbar_sel[p] % NUM_VC;

                    //-----------------------------------------------------------------
                    // Credit availability
                    //-----------------------------------------------------------------

                    if (credit_count[p][selected_vc[p]] != '0) begin

                        credit_ok[p]             = 1'b1;
                        grant_valid_qualified[p] = 1'b1;
                        send_event[p]            = 1'b1;

                        //-----------------------------------------------------------------
                        // The selected global input VC actually dequeues.
                        //-----------------------------------------------------------------

                        fifo_rd_en[xbar_sel[p]] = 1'b1;

                    end

                end

            end

        end

    end

    //=========================================================================
    // CREDIT COUNTER UPDATE
    //
    // next = current - send + return
    //
    // Four cases:
    //
    // 00 -> unchanged
    // 01 -> +1
    // 10 -> -1
    // 11 -> unchanged
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            for (int p = 0; p < NUM_PORTS; p++) begin

                for (int v = 0; v < NUM_VC; v++) begin

                    credit_count[p][v] <= CREDIT_W'(vc_depth(v));

                end

            end

        end
        else begin

            for (int p = 0; p < NUM_PORTS; p++) begin

                for (int v = 0; v < NUM_VC; v++) begin

                    //-----------------------------------------------------------------
                    // A send can only occur for the VC selected by this output.
                    //-----------------------------------------------------------------

                    logic local_send;

                    local_send = send_event[p] &&
                                 (selected_vc[p] == v);

                    case ({local_send, credit_return[p][v]})

                        //-----------------------------------------------------------------
                        // SEND ONLY
                        //-----------------------------------------------------------------

                        2'b10: begin

                            credit_count[p][v] <=
                                credit_count[p][v] - CREDIT_W'(1);

                        end

                        //-----------------------------------------------------------------
                        // CREDIT RETURN ONLY
                        //-----------------------------------------------------------------

                        2'b01: begin

                            // A credit return at a full counter is a protocol
                            // violation. Do not wrap the counter; hold at the
                            // configured FIFO depth and let the assertion below
                            // report the illegal return.
                            if (credit_count[p][v] < CREDIT_W'(vc_depth(v)))
                                credit_count[p][v] <=
                                    credit_count[p][v] + CREDIT_W'(1);
                            else
                                credit_count[p][v] <= credit_count[p][v];

                        end

                        //-----------------------------------------------------------------
                        // SEND + RETURN
                        //
                        // Net change = 0.
                        //-----------------------------------------------------------------

                        2'b11: begin

                            credit_count[p][v] <=
                                credit_count[p][v];

                        end

                        //-----------------------------------------------------------------
                        // NOTHING
                        //-----------------------------------------------------------------

                        default: begin

                            credit_count[p][v] <=
                                credit_count[p][v];

                        end

                    endcase

                end

            end

        end

    end

    //=========================================================================
    // SVA
    //
    // Simulation-only. Keep these assertions in RTL because M9's invariants
    // are part of the module contract.
    //=========================================================================

    //-------------------------------------------------------------------------
    // A credit return while already full is illegal. The counter is held at
    // depth rather than allowed to wrap; this assertion catches the upstream
    // protocol violation without corrupting the state machine.
    //-------------------------------------------------------------------------

    generate
        for (genvar fp = 0; fp < NUM_PORTS; fp++) begin : GEN_FULL_RETURN
            for (genvar fv = 0; fv < NUM_VC; fv++) begin : GEN_FULL_RETURN_VC
                property p_no_return_when_full;
                    @(posedge clk) disable iff (rst)
                        (credit_return[fp][fv] &&
                         (credit_count[fp][fv] == CREDIT_W'(vc_depth(fv))) &&
                         !(send_event[fp] && (selected_vc[fp] == fv))) |-> 1'b0;
                endproperty

                a_no_return_when_full:
                    assert property (p_no_return_when_full)
                    else $error(
                        "M9: illegal credit return while full P=%0d VC=%0d",
                        fp, fv
                    );
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // A credit counter can never exceed its configured FIFO depth.
    //-------------------------------------------------------------------------

    generate

        for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : GEN_PORT_SVA

            for (genvar gv = 0; gv < NUM_VC; gv++) begin : GEN_VC_SVA

                property p_credit_upper_bound;
                    @(posedge clk) disable iff (rst)
                        credit_count[gp][gv] <= CREDIT_W'(vc_depth(gv));
                endproperty

                a_credit_upper_bound:
                    assert property (p_credit_upper_bound)
                    else $error(
                        "M9: credit overflow P=%0d VC=%0d credit=%0d depth=%0d",
                        gp, gv,
                        credit_count[gp][gv],
                        vc_depth(gv)
                    );

            end

        end

    endgenerate

    //-------------------------------------------------------------------------
    // ZERO CREDIT MUST BLOCK TRANSMISSION.
    //-------------------------------------------------------------------------

    generate

        for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : GEN_ZERO_CREDIT

            property p_zero_credit_blocks;
                @(posedge clk) disable iff (rst)
                    grant_valid[gp] &&
                    (int'(xbar_sel[gp]) < NUM_INPUT_VCS) &&
                    (credit_count[gp][xbar_sel[gp] % NUM_VC] == '0)
                    |-> !grant_valid_qualified[gp];
            endproperty

            a_zero_credit_blocks:
                assert property (p_zero_credit_blocks)
                else $error(
                    "M9: transfer allowed with ZERO credit on output %0d",
                    gp
                );

        end

    endgenerate

    //-------------------------------------------------------------------------
    // QUALIFIED GRANT REQUIRES ORIGINAL GRANT.
    //-------------------------------------------------------------------------

    generate

        for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : GEN_GRANT_SVA

            property p_qualified_implies_grant;
                @(posedge clk) disable iff (rst)
                    grant_valid_qualified[gp] |-> grant_valid[gp];
            endproperty

            a_qualified_implies_grant:
                assert property (p_qualified_implies_grant)
                else $error(
                    "M9: qualified grant without M7 grant P=%0d", gp
                );

        end

    endgenerate

    //-------------------------------------------------------------------------
    // FIFO READ REQUIRES A CREDIT-QUALIFIED GRANT.
    //-------------------------------------------------------------------------

    generate

        for (genvar gi = 0; gi < NUM_INPUT_VCS; gi++) begin : GEN_RD_SVA

            property p_rd_has_qualified_grant;
                @(posedge clk) disable iff (rst)
                    fifo_rd_en[gi] |->
                        (|({
                            grant_valid_qualified[0] &&
                            (xbar_sel[0] == INPUT_VC_W'(gi)),

                            grant_valid_qualified[1] &&
                            (xbar_sel[1] == INPUT_VC_W'(gi)),

                            grant_valid_qualified[2] &&
                            (xbar_sel[2] == INPUT_VC_W'(gi)),

                            grant_valid_qualified[3] &&
                            (xbar_sel[3] == INPUT_VC_W'(gi)),

                            grant_valid_qualified[4] &&
                            (xbar_sel[4] == INPUT_VC_W'(gi))
                        }));
            endproperty

            a_rd_has_qualified_grant:
                assert property (p_rd_has_qualified_grant)
                else $error(
                    "M9: FIFO read without qualified grant VC=%0d", gi
                );

        end

    endgenerate

    //-------------------------------------------------------------------------
    // ONLY ONE INPUT VC MAY BE READ PER OUTPUT.
    //
    // This should already be guaranteed by M7, but M9 preserves the invariant.
    //-------------------------------------------------------------------------

    generate

        for (genvar gp = 0; gp < NUM_PORTS; gp++) begin : GEN_ONE_GRANT

            property p_one_hot_grant;
                @(posedge clk) disable iff (rst)
                    $onehot0(grant[gp]);
            endproperty

            a_one_hot_grant:
                assert property (p_one_hot_grant)
                else $error(
                    "M9: multiple input VCs granted to output %0d",
                    gp
                );

        end

    endgenerate

endmodule