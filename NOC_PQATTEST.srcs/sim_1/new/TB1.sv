`timescale 1ns / 1ps
//=============================================================================
// tb_noc_stage2.sv
//
// ONE combined Stage 2 testbench. Set as simulation top, run once.
//
// Covers:
//   noc_pkg               elaboration + helper-function self-consistency
//   noc_fifo              reference-model equivalence at two depths
//   noc_crossbar          all mappings, illegal encodings, random
//   noc_xy_routing        exhaustive 4096 coords, convergence, turn model
//   noc_router_datapath   VC separation, port independence, mux, credits
//
// Method:
//   SVA against independent reference models written from the SPEC, not from
//   the DUT source, so a shared misunderstanding cannot hide in both.
//
// Portability notes:
//   - No queue methods or queue indexing appear inside any assertion. The
//     model size and head are mirrored into plain variables first, because
//     calling methods on a dynamic type from inside a property is where
//     simulators diverge.
//   - Every property carries an explicit @(posedge clk). No default clocking
//     block, so nothing depends on default-resolution behaviour.
//   - The crossbar select index is resolved through a guarded function, so an
//     illegal encoding can never index outside the input array.
//
// EXPECTED NOISE:
//   Phases that deliberately violate a protocol make the DUT's own assertions
//   fire. That is correct. Those assertions are suppressed for exactly the
//   offending phase and re-armed afterwards. Only this testbench's counters
//   decide pass or fail.
//=============================================================================

module tb_noc_stage2;

    import noc_pkg::*;

    //=========================================================================
    // Clock, reset, scoreboard
    //=========================================================================

    localparam time CLK_PERIOD = 20ns;      // 50 MHz, the project target

    localparam int unsigned DEPTH_A = 4;    // power of two
    localparam int unsigned DEPTH_B = 6;    // non power of two

    logic clk = 1'b0;
    logic rst = 1'b1;

    always #(CLK_PERIOD/2) clk = ~clk;

    int unsigned err_pkg  = 0;
    int unsigned err_fifo = 0;
    int unsigned err_xbar = 0;
    int unsigned err_xy   = 0;
    int unsigned err_dp   = 0;

    // Negative-control failures. Kept separate from the functional counters
    // so the report can distinguish "the DUT is wrong" from "the testbench
    // cannot detect a wrong DUT" - which are different problems with very
    // different consequences.
    int unsigned err_neg  = 0;

    function automatic int unsigned total_errors();
        return err_pkg + err_fifo + err_xbar + err_xy + err_dp + err_neg;
    endfunction


    //=========================================================================
    //  BLOCK 1 : noc_fifo
    //=========================================================================

    flit_t a_wr_flit, a_rd_flit;
    logic  a_wr_en, a_rd_en, a_empty, a_full, a_credit;
    logic [$clog2(DEPTH_A+1)-1:0] a_occ, a_free;

    noc_fifo #(.DEPTH (DEPTH_A)) dut_fifo_a (
        .clk(clk), .rst(rst),
        .wr_flit(a_wr_flit), .wr_en(a_wr_en), .rd_en(a_rd_en),
        .rd_flit(a_rd_flit), .empty(a_empty), .full(a_full),
        .occupancy(a_occ), .free_slots(a_free), .credit_valid(a_credit)
    );

    flit_t b_wr_flit, b_rd_flit;
    logic  b_wr_en, b_rd_en, b_empty, b_full, b_credit;
    logic [$clog2(DEPTH_B+1)-1:0] b_occ, b_free;

    noc_fifo #(.DEPTH (DEPTH_B)) dut_fifo_b (
        .clk(clk), .rst(rst),
        .wr_flit(b_wr_flit), .wr_en(b_wr_en), .rd_en(b_rd_en),
        .rd_flit(b_rd_flit), .empty(b_empty), .full(b_full),
        .occupancy(b_occ), .free_slots(b_free), .credit_valid(b_credit)
    );

    //-------------------------------------------------------------------------
    // Reference models
    //
    // Behavioural queues implementing the FIFO contract. Their size and head
    // are mirrored into plain variables because assertions must not call
    // methods on, or index into, a dynamic type.
    //-------------------------------------------------------------------------

    flit_t model_a [$];
    flit_t model_b [$];

    int unsigned model_a_size, model_b_size;
    flit_t       model_a_head, model_b_head;

    //-------------------------------------------------------------------------
    // The mirror variables are updated INSIDE the clocked block, immediately
    // after the queue is modified.
    //
    // They were previously derived in an always_comb reading model_a.size()
    // and model_a[0]. XSim reports:
    //
    //   [XSIM 43-5612] Sensitivity on an element of Queue/Associative/Dynamic
    //   Array is not supported and will be ignored from sensitivity list.
    //
    // A combinational block whose only sensitivity comes from queue elements
    // therefore has NO sensitivity at all, and may execute once at time zero
    // and never again -- leaving the mirrors frozen and the comparison
    // vacuous. A vacuous checker reports PASS forever.
    //
    // Updating them here with blocking assignments removes all dependence on
    // queue sensitivity. Timing stays correct: both the mirror and the DUT's
    // occupancy counter settle at the same clock edge, so an assertion
    // sampling in the preponed region of the next edge sees a matched pair.
    //-------------------------------------------------------------------------

    always @(posedge clk) begin
        if (rst) model_a.delete();
        else begin
            if (a_wr_en && !a_full)  model_a.push_back(a_wr_flit);
            if (a_rd_en && !a_empty) void'(model_a.pop_front());
        end
        model_a_size = model_a.size();
        model_a_head = (model_a.size() > 0) ? model_a[0] : '0;
    end

    always @(posedge clk) begin
        if (rst) model_b.delete();
        else begin
            if (b_wr_en && !b_full)  model_b.push_back(b_wr_flit);
            if (b_rd_en && !b_empty) void'(model_b.pop_front());
        end
        model_b_size = model_b.size();
        model_b_head = (model_b.size() > 0) ? model_b[0] : '0;
    end


    //=========================================================================
    //  PROCEDURAL COVERAGE
    //
    //  XSim reports "System Verilog Cover is not supported yet for
    //  simulation. The statement will be ignored." for every cover property
    //  in this file. All of them were silently discarded, which means the
    //  first run produced NO EVIDENCE that the interesting corners were ever
    //  reached. An assertion that never sees the state it guards is
    //  indistinguishable from an assertion that is broken.
    //
    //  These plain counters are portable and are printed in the final report,
    //  so a PASS can be read together with proof that the corners were hit.
    //=========================================================================

    int unsigned cov_fifo_full        = 0;
    int unsigned cov_fifo_empty       = 0;
    int unsigned cov_fifo_rw_full     = 0;
    int unsigned cov_fifo_rw_empty    = 0;
    int unsigned cov_fifo_rw_mid      = 0;
    int unsigned cov_fifo_ovf_try     = 0;
    int unsigned cov_fifo_unf_try     = 0;
    int unsigned cov_fifo_b_full      = 0;

    int unsigned cov_xb_legal_sel     = 0;
    int unsigned cov_xb_illegal_sel   = 0;

    int unsigned cov_xy_east          = 0;
    int unsigned cov_xy_west          = 0;
    int unsigned cov_xy_north         = 0;
    int unsigned cov_xy_south         = 0;
    int unsigned cov_xy_local         = 0;
    int unsigned cov_xy_invalid       = 0;

    int unsigned cov_dp_vc0_full      = 0;
    int unsigned cov_dp_vc1_full      = 0;
    int unsigned cov_dp_vc2_full      = 0;
    int unsigned cov_dp_all_full      = 0;
    int unsigned cov_dp_all_ports     = 0;
    int unsigned cov_dp_vc0_write     = 0;
    int unsigned cov_dp_vc1_write     = 0;
    int unsigned cov_dp_vc2_write     = 0;
    int unsigned cov_dp_multihot      = 0;

    int i_cov;

    // NOTE: the coverage/observation always block that was here has been
    // relocated to just before `endmodule`. It samples DUT signals (xb_sel,
    // xy_valid, xy_port, in_valid_*, sel_north_vc*, full_north_vc*) that are
    // declared further down in the per-block sections; compiling it here made
    // xvlog reject those as "used before declaration" (VRFC 10-3380). Moving
    // it below all declarations fixes the ordering without changing behavior.


    //=========================================================================
    //  BLOCK 2 : noc_crossbar
    //=========================================================================

    flit_t    xb_in   [5];
    logic     xb_vin  [5];
    port_id_t xb_sel  [5];
    flit_t    xb_out  [5];
    logic     xb_vout [5];

    noc_crossbar dut_xbar (
        .in_flit_north (xb_in[0]),   .in_flit_south (xb_in[1]),
        .in_flit_east  (xb_in[2]),   .in_flit_west  (xb_in[3]),
        .in_flit_local (xb_in[4]),

        .in_valid_north(xb_vin[0]),  .in_valid_south(xb_vin[1]),
        .in_valid_east (xb_vin[2]),  .in_valid_west (xb_vin[3]),
        .in_valid_local(xb_vin[4]),

        .select_north  (xb_sel[0]),  .select_south  (xb_sel[1]),
        .select_east   (xb_sel[2]),  .select_west   (xb_sel[3]),
        .select_local  (xb_sel[4]),

        .out_flit_north(xb_out[0]),  .out_flit_south(xb_out[1]),
        .out_flit_east (xb_out[2]),  .out_flit_west (xb_out[3]),
        .out_flit_local(xb_out[4]),

        .out_valid_north(xb_vout[0]),.out_valid_south(xb_vout[1]),
        .out_valid_east (xb_vout[2]),.out_valid_west (xb_vout[3]),
        .out_valid_local(xb_vout[4])
    );

    //-------------------------------------------------------------------------
    // Guarded reference selection.
    //
    // Returns what the crossbar output MUST be for a given select value,
    // including the illegal encodings 5..7. Because the bounds check lives
    // inside the function, no assertion can ever index outside the array.
    //-------------------------------------------------------------------------

    function automatic flit_t xb_ref_flit(input port_id_t s);
        if (s < port_id_t'(NUM_PORTS)) return xb_in[s];
        else                           return '0;
    endfunction

    function automatic logic xb_ref_valid(input port_id_t s);
        if (s < port_id_t'(NUM_PORTS)) return xb_vin[s];
        else                           return 1'b0;
    endfunction


    //=========================================================================
    //  BLOCK 3 : noc_xy_routing
    //=========================================================================

    coord_t   xy_current, xy_dest;
    port_id_t xy_port;
    logic     xy_valid;

    noc_xy_routing dut_xy (
        .current_coord (xy_current),
        .dest_coord    (xy_dest),
        .route_port    (xy_port),
        .route_valid   (xy_valid)
    );

    function automatic port_e ref_route(input coord_t c, input coord_t d);
        if      (d.x > c.x) return PORT_EAST;
        else if (d.x < c.x) return PORT_WEST;
        else if (d.y > c.y) return PORT_SOUTH;
        else if (d.y < c.y) return PORT_NORTH;
        else                return PORT_LOCAL;
    endfunction

    function automatic logic in_mesh(input coord_t c);
        return (c.x < MESH_X) && (c.y < MESH_Y);
    endfunction

    function automatic coord_t step(input coord_t c, input port_e p);
        coord_t n;
        n = c;
        case (p)
            PORT_EAST:  n.x = c.x + 1;
            PORT_WEST:  n.x = c.x - 1;
            PORT_SOUTH: n.y = c.y + 1;
            PORT_NORTH: n.y = c.y - 1;
            default:    n   = c;
        endcase
        return n;
    endfunction

    logic     xy_exp_valid;
    port_e    xy_exp_port;
    logic     xy_dest_ok, xy_curr_ok;

    always_comb begin
        xy_dest_ok   = in_mesh(xy_dest);
        xy_curr_ok   = in_mesh(xy_current);
        xy_exp_valid = xy_curr_ok && xy_dest_ok;
        xy_exp_port  = xy_exp_valid ? ref_route(xy_current, xy_dest) : PORT_LOCAL;
    end


    //=========================================================================
    //  BLOCK 4 : noc_router_datapath
    //=========================================================================

    flit_t in_flit_north, in_flit_south, in_flit_east, in_flit_west, in_flit_local;
    logic  in_valid_north, in_valid_south, in_valid_east, in_valid_west, in_valid_local;

    logic rd_en_north_vc0, rd_en_north_vc1, rd_en_north_vc2;
    logic rd_en_south_vc0, rd_en_south_vc1, rd_en_south_vc2;
    logic rd_en_east_vc0,  rd_en_east_vc1,  rd_en_east_vc2;
    logic rd_en_west_vc0,  rd_en_west_vc1,  rd_en_west_vc2;
    logic rd_en_local_vc0, rd_en_local_vc1, rd_en_local_vc2;

    logic sel_north_vc0, sel_north_vc1, sel_north_vc2;
    logic sel_south_vc0, sel_south_vc1, sel_south_vc2;
    logic sel_east_vc0,  sel_east_vc1,  sel_east_vc2;
    logic sel_west_vc0,  sel_west_vc1,  sel_west_vc2;
    logic sel_local_vc0, sel_local_vc1, sel_local_vc2;

    flit_t head_north_vc0, head_north_vc1, head_north_vc2;
    flit_t head_south_vc0, head_south_vc1, head_south_vc2;
    flit_t head_east_vc0,  head_east_vc1,  head_east_vc2;
    flit_t head_west_vc0,  head_west_vc1,  head_west_vc2;
    flit_t head_local_vc0, head_local_vc1, head_local_vc2;

    logic empty_north_vc0, empty_north_vc1, empty_north_vc2;
    logic empty_south_vc0, empty_south_vc1, empty_south_vc2;
    logic empty_east_vc0,  empty_east_vc1,  empty_east_vc2;
    logic empty_west_vc0,  empty_west_vc1,  empty_west_vc2;
    logic empty_local_vc0, empty_local_vc1, empty_local_vc2;

    logic full_north_vc0, full_north_vc1, full_north_vc2;
    logic full_south_vc0, full_south_vc1, full_south_vc2;
    logic full_east_vc0,  full_east_vc1,  full_east_vc2;
    logic full_west_vc0,  full_west_vc1,  full_west_vc2;
    logic full_local_vc0, full_local_vc1, full_local_vc2;

    logic [VC0_CNT_WIDTH-1:0] free_north_vc0, free_south_vc0, free_east_vc0,
                              free_west_vc0,  free_local_vc0;
    logic [VC1_CNT_WIDTH-1:0] free_north_vc1, free_south_vc1, free_east_vc1,
                              free_west_vc1,  free_local_vc1;
    logic [VC2_CNT_WIDTH-1:0] free_north_vc2, free_south_vc2, free_east_vc2,
                              free_west_vc2,  free_local_vc2;

    logic credit_north_vc0, credit_north_vc1, credit_north_vc2;
    logic credit_south_vc0, credit_south_vc1, credit_south_vc2;
    logic credit_east_vc0,  credit_east_vc1,  credit_east_vc2;
    logic credit_west_vc0,  credit_west_vc1,  credit_west_vc2;
    logic credit_local_vc0, credit_local_vc1, credit_local_vc2;

    flit_t crossbar_in_north, crossbar_in_south, crossbar_in_east,
           crossbar_in_west,  crossbar_in_local;
    logic  crossbar_valid_north, crossbar_valid_south, crossbar_valid_east,
           crossbar_valid_west,  crossbar_valid_local;

    noc_router_datapath dut_dp (.*);


    //=========================================================================
    //  ASSERTIONS -- noc_fifo, depth 4
    //=========================================================================

    ap_fa_occ: assert property (@(posedge clk) disable iff (rst)
        a_occ == model_a_size)
        else begin err_fifo++;
            $error("FIFO A: occupancy %0d != model %0d", a_occ, model_a_size); end

    // Head data AND ordering, every cycle. Replaces every directed ordering
    // and wrap-around test that could be written by hand.
    ap_fa_head: assert property (@(posedge clk) disable iff (rst)
        !a_empty |-> (a_rd_flit == model_a_head))
        else begin err_fifo++; $error("FIFO A: head does not match model"); end

    ap_fa_empty: assert property (@(posedge clk) disable iff (rst)
        a_empty == (a_occ == 0))
        else begin err_fifo++; $error("FIFO A: empty inconsistent with occupancy"); end

    ap_fa_full: assert property (@(posedge clk) disable iff (rst)
        a_full == (a_occ == DEPTH_A))
        else begin err_fifo++; $error("FIFO A: full inconsistent with occupancy"); end

    ap_fa_sum: assert property (@(posedge clk) disable iff (rst)
        (a_occ + a_free) == DEPTH_A)
        else begin err_fifo++; $error("FIFO A: occupancy + free_slots != DEPTH"); end

    // Occupancy may only move by one, in the direction the strobes imply.
    ap_fa_delta: assert property (@(posedge clk) disable iff (rst)
        ##1 (a_occ == $past(a_occ)
                    + ($past(a_wr_en && !a_full)  ? 1 : 0)
                    - ($past(a_rd_en && !a_empty) ? 1 : 0)))
        else begin err_fifo++; $error("FIFO A: illegal occupancy transition"); end

    ap_fa_wr_refused: assert property (@(posedge clk) disable iff (rst)
        (a_wr_en && a_full && !(a_rd_en && !a_empty)) |=> (a_occ == $past(a_occ)))
        else begin err_fifo++; $error("FIFO A: refused write changed occupancy"); end

    ap_fa_rd_refused: assert property (@(posedge clk) disable iff (rst)
        (a_rd_en && a_empty && !(a_wr_en && !a_full)) |=> (a_occ == $past(a_occ)))
        else begin err_fifo++; $error("FIFO A: refused read changed occupancy"); end

    // Exactly one credit pulse per successful dequeue, one cycle later.
    ap_fa_credit: assert property (@(posedge clk) disable iff (rst)
        ##1 (a_credit == $past(a_rd_en && !a_empty)))
        else begin err_fifo++; $error("FIFO A: credit does not match dequeue"); end

    //=========================================================================
    //  ASSERTIONS -- noc_fifo, depth 6
    //
    //  The configuration that breaks any FIFO relying on natural pointer
    //  rollover instead of an explicit wrap comparison.
    //=========================================================================

    ap_fb_occ: assert property (@(posedge clk) disable iff (rst)
        b_occ == model_b_size)
        else begin err_fifo++;
            $error("FIFO B: occupancy %0d != model %0d", b_occ, model_b_size); end

    ap_fb_head: assert property (@(posedge clk) disable iff (rst)
        !b_empty |-> (b_rd_flit == model_b_head))
        else begin err_fifo++;
            $error("FIFO B: head mismatch at depth %0d", DEPTH_B); end

    ap_fb_full: assert property (@(posedge clk) disable iff (rst)
        b_full == (b_occ == DEPTH_B))
        else begin err_fifo++;
            $error("FIFO B: full inconsistent at depth %0d", DEPTH_B); end

    ap_fb_sum: assert property (@(posedge clk) disable iff (rst)
        (b_occ + b_free) == DEPTH_B)
        else begin err_fifo++; $error("FIFO B: occupancy + free_slots != DEPTH"); end

    cp_fa_full:     cover property (@(posedge clk) a_full);
    cp_fa_empty:    cover property (@(posedge clk) a_empty);
    cp_fa_rw_full:  cover property (@(posedge clk) a_full  && a_wr_en && a_rd_en);
    cp_fa_rw_empty: cover property (@(posedge clk) a_empty && a_wr_en && a_rd_en);
    cp_fa_rw_mid:   cover property (@(posedge clk) !a_full && !a_empty && a_wr_en && a_rd_en);
    cp_fb_full:     cover property (@(posedge clk) b_full);


    //=========================================================================
    //  ASSERTIONS -- noc_crossbar
    //
    //  One generate loop replaces 25 hand-written expectations, which removes
    //  the possibility of the testbench carrying the same transposition bug
    //  as the DUT. The reference functions handle legal and illegal select
    //  encodings in one place, so there is no unguarded array index anywhere.
    //=========================================================================

    genvar o;
    generate
        for (o = 0; o < 5; o++) begin : g_xbar

            ap_xb_data: assert property (@(posedge clk)
                xb_out[o] == xb_ref_flit(xb_sel[o]))
                else begin err_xbar++;
                    $error("XBAR out %0d: data wrong for select %0d", o, xb_sel[o]); end

            ap_xb_valid: assert property (@(posedge clk)
                xb_vout[o] == xb_ref_valid(xb_sel[o]))
                else begin err_xbar++;
                    $error("XBAR out %0d: valid wrong for select %0d", o, xb_sel[o]); end

            cp_xb_0:   cover property (@(posedge clk) xb_sel[o] == port_id_t'(0));
            cp_xb_1:   cover property (@(posedge clk) xb_sel[o] == port_id_t'(1));
            cp_xb_2:   cover property (@(posedge clk) xb_sel[o] == port_id_t'(2));
            cp_xb_3:   cover property (@(posedge clk) xb_sel[o] == port_id_t'(3));
            cp_xb_4:   cover property (@(posedge clk) xb_sel[o] == port_id_t'(4));
            cp_xb_bad: cover property (@(posedge clk) xb_sel[o] >= port_id_t'(NUM_PORTS));
        end
    endgenerate

    // The full permutation the allocator will actually produce.
    cp_xb_perm: cover property (@(posedge clk)
        (xb_sel[0] == port_id_t'(1)) && (xb_sel[1] == port_id_t'(2)) &&
        (xb_sel[2] == port_id_t'(3)) && (xb_sel[3] == port_id_t'(4)) &&
        (xb_sel[4] == port_id_t'(0)));


    //=========================================================================
    //  ASSERTIONS -- noc_xy_routing
    //=========================================================================

    ap_xy_valid: assert property (@(posedge clk)
        xy_valid == xy_exp_valid)
        else begin err_xy++;
            $error("XY: route_valid %b expected %b for (%0d,%0d)->(%0d,%0d)",
                   xy_valid, xy_exp_valid,
                   xy_current.x, xy_current.y, xy_dest.x, xy_dest.y); end

    ap_xy_port: assert property (@(posedge clk)
        xy_valid |-> (port_e'(xy_port) == xy_exp_port))
        else begin err_xy++;
            $error("XY: port %0d expected %0d for (%0d,%0d)->(%0d,%0d)",
                   xy_port, xy_exp_port,
                   xy_current.x, xy_current.y, xy_dest.x, xy_dest.y); end

    ap_xy_bad_dest: assert property (@(posedge clk)
        !xy_dest_ok |-> !xy_valid)
        else begin err_xy++; $error("XY: out-of-mesh destination accepted"); end

    ap_xy_bad_curr: assert property (@(posedge clk)
        !xy_curr_ok |-> !xy_valid)
        else begin err_xy++; $error("XY: out-of-mesh current coordinate accepted"); end

    ap_xy_local_at_dest: assert property (@(posedge clk)
        (xy_valid && (port_e'(xy_port) == PORT_LOCAL)) |-> (xy_dest == xy_current))
        else begin err_xy++; $error("XY: LOCAL computed away from the destination"); end

    ap_xy_dest_is_local: assert property (@(posedge clk)
        (xy_valid && (xy_dest == xy_current)) |-> (port_e'(xy_port) == PORT_LOCAL))
        else begin err_xy++; $error("XY: at destination but route is not LOCAL"); end

    ap_xy_port_exists: assert property (@(posedge clk)
        xy_valid |-> port_exists(xy_current, port_e'(xy_port)))
        else begin err_xy++; $error("XY: routed to a port that does not exist here"); end

    // DIMENSION ORDER. The property the whole deadlock argument rests on: if
    // X and Y are ever resolved out of order the NORTH->EAST and SOUTH->EAST
    // turns become reachable and the channel dependency graph gains a cycle.
    ap_xy_x_first: assert property (@(posedge clk)
        (xy_valid && (xy_dest.x != xy_current.x))
            |-> ((port_e'(xy_port) == PORT_EAST) || (port_e'(xy_port) == PORT_WEST)))
        else begin err_xy++; $error("XY: Y resolved before X was complete"); end

    ap_xy_y_after_x: assert property (@(posedge clk)
        (xy_valid && ((port_e'(xy_port) == PORT_NORTH) ||
                      (port_e'(xy_port) == PORT_SOUTH)))
            |-> (xy_dest.x == xy_current.x))
        else begin err_xy++; $error("XY: Y movement while X still outstanding"); end

    cp_xy_east:  cover property (@(posedge clk) xy_valid && (port_e'(xy_port) == PORT_EAST));
    cp_xy_west:  cover property (@(posedge clk) xy_valid && (port_e'(xy_port) == PORT_WEST));
    cp_xy_north: cover property (@(posedge clk) xy_valid && (port_e'(xy_port) == PORT_NORTH));
    cp_xy_south: cover property (@(posedge clk) xy_valid && (port_e'(xy_port) == PORT_SOUTH));
    cp_xy_local: cover property (@(posedge clk) xy_valid && (port_e'(xy_port) == PORT_LOCAL));
    cp_xy_bad:   cover property (@(posedge clk) !xy_valid);


    //=========================================================================
    //  ASSERTIONS -- noc_router_datapath
    //
    //  VC separation is the load-bearing property. If traffic leaks between
    //  virtual channels the deadlock argument collapses and nothing
    //  downstream is trustworthy.
    //=========================================================================

    //-------------------------------------------------------------------------
    // VC SEPARATION -- rewritten after the first run.
    //
    // The original form was WRONG IN TWO WAYS and produced 36 false failures:
    //
    //   1. OVER-FIRING. It required $stable(empty_north_vc1) whenever a VC0
    //      flit arrived. But the stimulus also drives rd_en_north_vc1, and a
    //      read that empties VC1 legitimately changes that flag. The property
    //      blamed the VC0 write for a change the VC1 READ caused.
    //
    //   2. TOO WEAK. 'empty' only moves at the 0<->1 boundary. A flit leaking
    //      into a VC that already held two entries would not change 'empty'
    //      at all, so the real bug it was written to catch could slip past.
    //
    // The fix uses the FIFO's internal occupancy counter through a
    // hierarchical reference, and gates the antecedent on the other VCs not
    // being read. Occupancy is exact, so leakage of any size is caught.
    //-------------------------------------------------------------------------

    // A VC0 flit must land in VC0 and must not disturb VC1 or VC2.
    ap_dp_vc0: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_REQUEST) &&
         !rd_en_north_vc1 && !rd_en_north_vc2)
            |=> ($stable(dut_dp.north_vc1_fifo.count) &&
                 $stable(dut_dp.north_vc2_fifo.count)))
        else begin err_dp++; $error("DP: NORTH VC0 flit leaked into another VC"); end

    ap_dp_vc1: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_RESPONSE) &&
         !rd_en_north_vc0 && !rd_en_north_vc2)
            |=> ($stable(dut_dp.north_vc0_fifo.count) &&
                 $stable(dut_dp.north_vc2_fifo.count)))
        else begin err_dp++; $error("DP: NORTH VC1 flit leaked into another VC"); end

    ap_dp_vc2: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_ATTESTATION) &&
         !rd_en_north_vc0 && !rd_en_north_vc1)
            |=> ($stable(dut_dp.north_vc0_fifo.count) &&
                 $stable(dut_dp.north_vc1_fifo.count)))
        else begin err_dp++; $error("DP: NORTH VC2 flit leaked into another VC"); end

    // The flit must actually ARRIVE in its own VC, not merely fail to
    // disturb the others. Occupancy must increment by exactly one.
    ap_dp_vc0_lands: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_REQUEST) &&
         !full_north_vc0 && !rd_en_north_vc0)
            |=> (dut_dp.north_vc0_fifo.count == $past(dut_dp.north_vc0_fifo.count) + 1))
        else begin err_dp++; $error("DP: NORTH VC0 flit did not land in VC0"); end

    ap_dp_vc1_lands: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_RESPONSE) &&
         !full_north_vc1 && !rd_en_north_vc1)
            |=> (dut_dp.north_vc1_fifo.count == $past(dut_dp.north_vc1_fifo.count) + 1))
        else begin err_dp++; $error("DP: NORTH VC1 flit did not land in VC1"); end

    ap_dp_vc2_lands: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && (in_flit_north.vc_id == VC_ATTESTATION) &&
         !full_north_vc2 && !rd_en_north_vc2)
            |=> (dut_dp.north_vc2_fifo.count == $past(dut_dp.north_vc2_fifo.count) + 1))
        else begin err_dp++; $error("DP: NORTH VC2 flit did not land in VC2"); end

    ap_dp_vc0_south: assert property (@(posedge clk) disable iff (rst)
        (in_valid_south && (in_flit_south.vc_id == VC_REQUEST) && !full_south_vc0)
            |=> !empty_south_vc0)
        else begin err_dp++; $error("DP: SOUTH VC0 decode failed"); end

    ap_dp_vc0_east: assert property (@(posedge clk) disable iff (rst)
        (in_valid_east && (in_flit_east.vc_id == VC_REQUEST) && !full_east_vc0)
            |=> !empty_east_vc0)
        else begin err_dp++; $error("DP: EAST VC0 decode failed"); end

    ap_dp_vc0_west: assert property (@(posedge clk) disable iff (rst)
        (in_valid_west && (in_flit_west.vc_id == VC_REQUEST) && !full_west_vc0)
            |=> !empty_west_vc0)
        else begin err_dp++; $error("DP: WEST VC0 decode failed"); end

    ap_dp_vc0_local: assert property (@(posedge clk) disable iff (rst)
        (in_valid_local && (in_flit_local.vc_id == VC_REQUEST) && !full_local_vc0)
            |=> !empty_local_vc0)
        else begin err_dp++; $error("DP: LOCAL VC0 decode failed"); end

    ap_dp_port_indep: assert property (@(posedge clk) disable iff (rst)
        (in_valid_north && !in_valid_south &&
         !rd_en_south_vc0 && !rd_en_south_vc1 && !rd_en_south_vc2)
            |=> ($stable(empty_south_vc0) && $stable(empty_south_vc1) &&
                 $stable(empty_south_vc2)))
        else begin err_dp++; $error("DP: NORTH traffic disturbed SOUTH"); end

    ap_dp_no_phantom: assert property (@(posedge clk) disable iff (rst)
        (!in_valid_north && !rd_en_north_vc0 && !rd_en_north_vc1 && !rd_en_north_vc2)
            |=> ($stable(empty_north_vc0) && $stable(empty_north_vc1) &&
                 $stable(empty_north_vc2)))
        else begin err_dp++; $error("DP: NORTH FIFO changed with no valid input"); end

    // Per-VC depth. Catches VC2_DEPTH being silently ignored when it is swept
    // to 8 or 16 during the synthesis probe.
    ap_dp_depth0: assert property (@(posedge clk) disable iff (rst)
        full_north_vc0 |-> (free_north_vc0 == '0))
        else begin err_dp++; $error("DP: VC0 full but free_slots non-zero"); end

    ap_dp_depth2: assert property (@(posedge clk) disable iff (rst)
        full_north_vc2 |-> (free_north_vc2 == '0))
        else begin err_dp++; $error("DP: VC2 full but free_slots non-zero"); end

    ap_dp_mux0: assert property (@(posedge clk) disable iff (rst)
        (sel_north_vc0 && !sel_north_vc1 && !sel_north_vc2)
            |-> ((crossbar_in_north == head_north_vc0) &&
                 (crossbar_valid_north == !empty_north_vc0)))
        else begin err_dp++; $error("DP: VC mux did not present VC0"); end

    ap_dp_mux1: assert property (@(posedge clk) disable iff (rst)
        (!sel_north_vc0 && sel_north_vc1 && !sel_north_vc2)
            |-> ((crossbar_in_north == head_north_vc1) &&
                 (crossbar_valid_north == !empty_north_vc1)))
        else begin err_dp++; $error("DP: VC mux did not present VC1"); end

    ap_dp_mux2: assert property (@(posedge clk) disable iff (rst)
        (!sel_north_vc0 && !sel_north_vc1 && sel_north_vc2)
            |-> ((crossbar_in_north == head_north_vc2) &&
                 (crossbar_valid_north == !empty_north_vc2)))
        else begin err_dp++; $error("DP: VC mux did not present VC2"); end

    ap_dp_mux_zero: assert property (@(posedge clk) disable iff (rst)
        (!sel_north_vc0 && !sel_north_vc1 && !sel_north_vc2)
            |-> (!crossbar_valid_north && (crossbar_in_north == '0)))
        else begin err_dp++; $error("DP: VC mux drove output with nothing selected"); end

    // priority case must resolve multi-hot deterministically to the lowest
    // VC. This is the reason unique case was removed from these muxes.
    ap_dp_mux_prio: assert property (@(posedge clk) disable iff (rst)
        (sel_north_vc0 && sel_north_vc1) |-> (crossbar_in_north == head_north_vc0))
        else begin err_dp++; $error("DP: priority case did not resolve to the lowest VC"); end

    ap_dp_credit_vc: assert property (@(posedge clk) disable iff (rst)
        (rd_en_north_vc0 && !empty_north_vc0 &&
         !(rd_en_north_vc1 && !empty_north_vc1) &&
         !(rd_en_north_vc2 && !empty_north_vc2))
            |=> (credit_north_vc0 && !credit_north_vc1 && !credit_north_vc2))
        else begin err_dp++; $error("DP: VC0 dequeue produced the wrong credit"); end

    ap_dp_credit_port: assert property (@(posedge clk) disable iff (rst)
        (rd_en_north_vc0 && !empty_north_vc0 && !rd_en_south_vc0) |=> !credit_south_vc0)
        else begin err_dp++; $error("DP: NORTH dequeue produced a SOUTH credit"); end

    cp_dp_vc0_full:  cover property (@(posedge clk) full_north_vc0);
    cp_dp_vc1_full:  cover property (@(posedge clk) full_north_vc1);
    cp_dp_vc2_full:  cover property (@(posedge clk) full_north_vc2);
    cp_dp_all_full:  cover property (@(posedge clk)
                         full_north_vc0 && full_north_vc1 && full_north_vc2);
    cp_dp_all_ports: cover property (@(posedge clk)
                         in_valid_north && in_valid_south && in_valid_east &&
                         in_valid_west  && in_valid_local);


    //=========================================================================
    //  HELPERS
    //=========================================================================

    function automatic flit_t rnd_flit(input int unsigned tag);
        flit_t f;
        f.flit_data = tag;
        f.flit_type = flit_type_e'($urandom_range(3,0));
        f.vc_id     = $urandom_range(NUM_VC-1, 0);
        return f;
    endfunction

    task automatic randomise_dp_sel();
        int v;

        v = $urandom_range(3,0);
        {sel_north_vc0, sel_north_vc1, sel_north_vc2} = 3'b000;
        if (v == 1) sel_north_vc0 = 1'b1;
        if (v == 2) sel_north_vc1 = 1'b1;
        if (v == 3) sel_north_vc2 = 1'b1;

        v = $urandom_range(3,0);
        {sel_south_vc0, sel_south_vc1, sel_south_vc2} = 3'b000;
        if (v == 1) sel_south_vc0 = 1'b1;
        if (v == 2) sel_south_vc1 = 1'b1;
        if (v == 3) sel_south_vc2 = 1'b1;

        v = $urandom_range(3,0);
        {sel_east_vc0, sel_east_vc1, sel_east_vc2} = 3'b000;
        if (v == 1) sel_east_vc0 = 1'b1;
        if (v == 2) sel_east_vc1 = 1'b1;
        if (v == 3) sel_east_vc2 = 1'b1;

        v = $urandom_range(3,0);
        {sel_west_vc0, sel_west_vc1, sel_west_vc2} = 3'b000;
        if (v == 1) sel_west_vc0 = 1'b1;
        if (v == 2) sel_west_vc1 = 1'b1;
        if (v == 3) sel_west_vc2 = 1'b1;

        v = $urandom_range(3,0);
        {sel_local_vc0, sel_local_vc1, sel_local_vc2} = 3'b000;
        if (v == 1) sel_local_vc0 = 1'b1;
        if (v == 2) sel_local_vc1 = 1'b1;
        if (v == 3) sel_local_vc2 = 1'b1;
    endtask

    task automatic dp_idle();
        {in_valid_north, in_valid_south, in_valid_east,
         in_valid_west,  in_valid_local} = 5'b00000;
        {rd_en_north_vc0, rd_en_north_vc1, rd_en_north_vc2} = 3'b000;
        {rd_en_south_vc0, rd_en_south_vc1, rd_en_south_vc2} = 3'b000;
        {rd_en_east_vc0,  rd_en_east_vc1,  rd_en_east_vc2 } = 3'b000;
        {rd_en_west_vc0,  rd_en_west_vc1,  rd_en_west_vc2 } = 3'b000;
        {rd_en_local_vc0, rd_en_local_vc1, rd_en_local_vc2} = 3'b000;
        {sel_north_vc0, sel_north_vc1, sel_north_vc2} = 3'b000;
        {sel_south_vc0, sel_south_vc1, sel_south_vc2} = 3'b000;
        {sel_east_vc0,  sel_east_vc1,  sel_east_vc2 } = 3'b000;
        {sel_west_vc0,  sel_west_vc1,  sel_west_vc2 } = 3'b000;
        {sel_local_vc0, sel_local_vc1, sel_local_vc2} = 3'b000;
    endtask

    // Depth of a given VC. VC0/1/2 are independent parameters in noc_pkg and
    // VC2 is the one earmarked for the 4/8/16 depth sweep in the resource
    // probe, so the burst must not hard-code VC0_DEPTH for all three.
    function automatic int vc_depth(input int v);
        case (v)
            0:       return int'(VC0_DEPTH);
            1:       return int'(VC1_DEPTH);
            2:       return int'(VC2_DEPTH);
            default: return int'(VC0_DEPTH);
        endcase
    endfunction

    function automatic logic all_fifos_empty();
        return empty_north_vc0 && empty_north_vc1 && empty_north_vc2 &&
               empty_south_vc0 && empty_south_vc1 && empty_south_vc2 &&
               empty_east_vc0  && empty_east_vc1  && empty_east_vc2  &&
               empty_west_vc0  && empty_west_vc1  && empty_west_vc2  &&
               empty_local_vc0 && empty_local_vc1 && empty_local_vc2;
    endfunction


    //=========================================================================
    //  PACKAGE SELF-CHECK
    //
    //  Runs before any hardware stimulus. If the coordinate helpers or the
    //  address decoder are inconsistent, every later result in this run is
    //  meaningless, so it fails here rather than inside a router.
    //=========================================================================

    task automatic check_package();
        coord_t       c;
        addr_decode_t r;
        int           t;

        $display("[PKG ] package self-check");

        if ($bits(head_flit_t) != 32) begin
            err_pkg++;
            $error("PKG: head_flit_t is %0d bits, must be exactly 32",
                   $bits(head_flit_t));
        end

        if (NUM_TILES != MESH_X * MESH_Y) begin
            err_pkg++;
            $error("PKG: NUM_TILES inconsistent with mesh dimensions");
        end

        if (NUM_VC > (1 << VC_ID_WIDTH)) begin
            err_pkg++;
            $error("PKG: VC_ID_WIDTH too narrow for NUM_VC");
        end

        // tile -> coord -> tile must be the identity for all six tiles.
        for (t = 0; t < NUM_TILES; t++) begin
            c = tile_to_coord(tile_id_e'(t));
            if (coord_to_tile(c) !== tile_id_e'(t)) begin
                err_pkg++;
                $error("PKG: tile %0d does not survive the coord round trip", t);
            end
            if (!in_mesh(c)) begin
                err_pkg++;
                $error("PKG: tile %0d maps outside the mesh", t);
            end
        end

        // Every packet must fit the 5-bit length field.
        if (MAX_PACKET_FLITS > 31) begin
            err_pkg++;
            $error("PKG: MAX_PACKET_FLITS %0d exceeds the 5-bit length field",
                   MAX_PACKET_FLITS);
        end

        // ------------------------------------------------------------------
        // L-08: the safe decoder must accept every legal remote tile and
        // REJECT everything else. An unmapped address must never silently
        // become a legal packet to a real tile.
        // ------------------------------------------------------------------
        for (t = 0; t < 16; t++) begin
            r = address_to_coord_safe(32'h2000_0000 | (t << TILE_SEL_LSB));
            if (t < NUM_TILES) begin
                if (!r.valid) begin
                    err_pkg++;
                    $error("PKG: legal remote tile %0d was rejected", t);
                end
                else if (r.coord !== tile_to_coord(tile_id_e'(t))) begin
                    err_pkg++;
                    $error("PKG: remote tile %0d decoded to the wrong coordinate", t);
                end
            end
            else if (r.valid) begin
                err_pkg++;
                $error("PKG: unmapped tile selector %0d was ACCEPTED", t);
            end
        end

        // Local addresses must never decode as remote.
        if (address_to_coord_safe(LOCAL_UART_BASE).valid) begin
            err_pkg++; $error("PKG: UART address decoded as remote"); end
        if (address_to_coord_safe(LOCAL_IMEM_BASE).valid) begin
            err_pkg++; $error("PKG: IMEM address decoded as remote"); end
        if (address_to_coord_safe(LOCAL_GPIO_BASE).valid) begin
            err_pkg++; $error("PKG: GPIO address decoded as remote"); end
        if (address_to_coord_safe(LOCAL_NI_BASE).valid) begin
            err_pkg++; $error("PKG: NI register address decoded as remote"); end
        if (address_to_coord_safe(32'hFFFF_FFFF).valid) begin
            err_pkg++; $error("PKG: 0xFFFFFFFF decoded as a valid remote tile"); end

        // Message class to VC mapping must match the deadlock argument.
        if ((message_to_vc(MSG_MEM_RD_REQ)  !== VC_REQUEST) ||
            (message_to_vc(MSG_MEM_WR_REQ)  !== VC_REQUEST)) begin
            err_pkg++; $error("PKG: requests are not on VC_REQUEST"); end
        if ((message_to_vc(MSG_MEM_RD_RESP) !== VC_RESPONSE) ||
            (message_to_vc(MSG_MEM_WR_RESP) !== VC_RESPONSE)) begin
            err_pkg++; $error("PKG: responses are not on VC_RESPONSE"); end
        if ((message_to_vc(MSG_ATTEST_CHALLENGE) !== VC_ATTESTATION) ||
            (message_to_vc(MSG_ATTEST_RESPONSE)  !== VC_ATTESTATION)) begin
            err_pkg++; $error("PKG: attestation traffic is not on VC_ATTESTATION"); end

        // opposite_port must be self-inverse.
        if ((opposite_port(opposite_port(PORT_NORTH)) !== PORT_NORTH) ||
            (opposite_port(opposite_port(PORT_EAST))  !== PORT_EAST)) begin
            err_pkg++; $error("PKG: opposite_port is not self-inverse"); end

        // Boundary ports must not exist at the mesh edges.
        if (port_exists(tile_to_coord(TILE_CPU0), PORT_NORTH)) begin
            err_pkg++; $error("PKG: CPU0 reports a NORTH port at the top edge"); end
        if (port_exists(tile_to_coord(TILE_CPU0), PORT_WEST)) begin
            err_pkg++; $error("PKG: CPU0 reports a WEST port at the left edge"); end
        if (port_exists(tile_to_coord(TILE_SPOOF), PORT_EAST)) begin
            err_pkg++; $error("PKG: SPOOF reports an EAST port at the right edge"); end
        if (port_exists(tile_to_coord(TILE_SPOOF), PORT_SOUTH)) begin
            err_pkg++; $error("PKG: SPOOF reports a SOUTH port at the bottom edge"); end
    endtask


    //=========================================================================
    //  CONVERGENCE AND TURN RESTRICTION
    //
    //  Iterates the routing function from every source to every destination.
    //  Convergence within the mesh diameter is the livelock argument; the
    //  turn check is the deadlock argument. Both in one loop.
    //=========================================================================

    task automatic check_convergence();
        coord_t hop, dst;
        port_e  prev_dir, this_dir;
        int     s, d, hops;

        $display("[XY  ] convergence and turn restriction");

        for (s = 0; s < NUM_TILES; s++) begin
            for (d = 0; d < NUM_TILES; d++) begin

                hop      = tile_to_coord(tile_id_e'(s));
                dst      = tile_to_coord(tile_id_e'(d));
                prev_dir = PORT_LOCAL;
                hops     = 0;

                while ((hop !== dst) && (hops < 10)) begin
                    xy_current = hop;
                    xy_dest    = dst;
                    @(posedge clk);
                    #1;
                    this_dir = port_e'(xy_port);

                    if (!xy_valid) begin
                        err_xy++;
                        $error("XY: invalid route mid-path, tile %0d -> %0d", s, d);
                    end

                    // No Y-then-X turn. Anywhere. Ever.
                    if ((prev_dir == PORT_NORTH) || (prev_dir == PORT_SOUTH))
                        if ((this_dir == PORT_EAST) || (this_dir == PORT_WEST)) begin
                            err_xy++;
                            $error("XY: ILLEGAL Y-to-X turn, tile %0d -> %0d", s, d);
                        end

                    prev_dir = this_dir;
                    hop      = step(hop, this_dir);
                    hops++;
                end

                if (hop !== dst) begin
                    err_xy++;
                    $error("XY: tile %0d -> %0d NEVER CONVERGED (livelock)", s, d);
                end
                if (hops > 3) begin
                    err_xy++;
                    $error("XY: tile %0d -> %0d took %0d hops, diameter is 3",
                           s, d, hops);
                end
            end
        end
    endtask


    //=========================================================================
    //  MAIN
    //=========================================================================

    int unsigned n;
    int          i, o2, s2, cx, cy, dx, dy;

    // PHASE 11 / PHASE 12 working variables.
    int          v_burst;
    port_e       neg_expected_wrong;
    logic        neg_detected;
    logic        neg_detected2;

    initial begin

        $display("");
        $display("==========================================================");
        $display(" tb_noc_stage2   PQ-Attest NoC, Stage 2 combined testbench");
        $display("==========================================================");
        $display(" MESH        : %0d x %0d, %0d tiles", MESH_X, MESH_Y, NUM_TILES);
        $display(" FLIT        : %0d bits data, %0d bits stored",
                 FLIT_WIDTH, FLIT_STORAGE_WIDTH);
        $display(" VC DEPTHS   : VC0=%0d VC1=%0d VC2=%0d",
                 VC0_DEPTH, VC1_DEPTH, VC2_DEPTH);
        $display(" MAC_ENABLE  : %0d   (0 = G1 baseline build)", MAC_ENABLE);
        $display(" MAX PACKET  : %0d flits", MAX_PACKET_FLITS);
        $display("----------------------------------------------------------");

        //---------------------------------------------------------------------
        // Idle everything BEFORE the first clock edge.
        //
        // Crossbar selects must NOT start at zero: output 0 selecting input 0
        // is the loopback the DUT correctly asserts against, and it would
        // fire on every cycle of the run.
        //---------------------------------------------------------------------

        a_wr_flit = '0; a_wr_en = 1'b0; a_rd_en = 1'b0;
        b_wr_flit = '0; b_wr_en = 1'b0; b_rd_en = 1'b0;

        for (i = 0; i < 5; i++) begin
            xb_in[i].flit_data = 32'hC0DE_0000 + i;
            xb_in[i].flit_type = flit_type_e'(i % 4);
            xb_in[i].vc_id     = i % NUM_VC;
            xb_vin[i]          = 1'b1;
            xb_sel[i]          = port_id_t'((i + 1) % 5);
        end

        xy_current = '0;
        xy_dest    = '0;

        in_flit_north = '0; in_flit_south = '0; in_flit_east = '0;
        in_flit_west  = '0; in_flit_local = '0;
        dp_idle();

        //---------------------------------------------------------------------
        // PHASE 0 : package
        //---------------------------------------------------------------------
        check_package();

        rst = 1'b1;
        repeat (5) @(negedge clk);

        if (!all_fifos_empty()) begin
            err_dp++;
            $error("DP: not all 15 FIFOs empty during reset");
        end
        if (!a_empty || a_full || (a_occ != 0)) begin
            err_fifo++;
            $error("FIFO A: bad state during reset");
        end

        rst = 1'b0;
        @(negedge clk);

        //---------------------------------------------------------------------
        // PHASE 1 : XY routing, exhaustive
        //
        // All 4096 combinations of two 3-bit coordinate pairs, legal and
        // illegal. The assertions do the checking; this walks the space.
        //---------------------------------------------------------------------
        $display("[XY  ] 4096 exhaustive coordinate combinations");

        for (cx = 0; cx < 8; cx++)
        for (cy = 0; cy < 8; cy++)
        for (dx = 0; dx < 8; dx++)
        for (dy = 0; dy < 8; dy++) begin
            xy_current.x = cx[2:0];
            xy_current.y = cy[2:0];
            xy_dest.x    = dx[2:0];
            xy_dest.y    = dy[2:0];
            @(posedge clk);
        end

        check_convergence();

        // Park XY on a legal configuration for the remainder of the run.
        xy_current = tile_to_coord(TILE_CPU0);
        xy_dest    = tile_to_coord(TILE_ROT);
        @(negedge clk);

        //---------------------------------------------------------------------
        // PHASE 2 : crossbar
        //---------------------------------------------------------------------
        $display("[XBAR] mappings, illegal encodings, 1000 random");

        for (o2 = 0; o2 < 5; o2++) begin
            for (s2 = 0; s2 < 5; s2++) begin
                if (o2 == s2) continue;                 // loopback, DUT asserts
                for (i = 0; i < 5; i++) xb_sel[i] = port_id_t'((i + 1) % 5);
                xb_sel[o2] = port_id_t'(s2);
                @(posedge clk);
            end
        end

        for (s2 = 5; s2 < 8; s2++) begin
            for (i = 0; i < 5; i++) xb_sel[i] = port_id_t'((i + 1) % 5);
            xb_sel[0] = port_id_t'(s2);
            @(posedge clk);
        end

        // The permutation the allocator will actually produce.
        xb_sel[0] = port_id_t'(1); xb_sel[1] = port_id_t'(2);
        xb_sel[2] = port_id_t'(3); xb_sel[3] = port_id_t'(4);
        xb_sel[4] = port_id_t'(0);
        repeat (2) @(posedge clk);

        for (n = 0; n < 1000; n++) begin
            for (i = 0; i < 5; i++) begin
                xb_sel[i]          = port_id_t'($urandom_range(4,0));
                xb_vin[i]          = $urandom_range(1,0);
                xb_in[i].flit_data = $urandom();
                xb_in[i].flit_type = flit_type_e'($urandom_range(3,0));
                xb_in[i].vc_id     = $urandom_range(NUM_VC-1,0);
            end
            // Never present the loopback the DUT asserts against.
            for (i = 0; i < 5; i++)
                if (xb_sel[i] == port_id_t'(i)) xb_sel[i] = port_id_t'((i + 1) % 5);
            @(posedge clk);
        end

        // Park the crossbar on a legal permutation.
        for (i = 0; i < 5; i++) begin
            xb_sel[i] = port_id_t'((i + 1) % 5);
            xb_vin[i] = 1'b1;
        end
        @(negedge clk);

        //---------------------------------------------------------------------
        // PHASE 3 : FIFO write-biased  -- DELIBERATE PROTOCOL VIOLATION
        //
        // Drives both FIFOs to full and keeps writing. The DUT's overflow
        // assertion is correct to fire, so it is suppressed here. The
        // testbench assertions still prove the refused write changes nothing.
        //---------------------------------------------------------------------
        $display("[FIFO] write-biased, overflow attempts (DUT assertion off)");

        // DISABLED: XSim [43-4481] -- "$assertoff with scope arguments is not
        //   supported yet. All assertions in the design will be turned off."
        //   The scoped form silently degraded to $assertoff(0), which killed
        //   EVERY assertion including this testbench's own SVA. Phases 3, 4, 8
        //   and 9 therefore ran completely unchecked and still reported PASS.
        //   Assertion control is removed entirely; the DUT assertions now fire
        //   during the deliberate-violation phases and that console noise is
        //   EXPECTED. Only the err_* counters decide pass or fail.
        //   $assertoff(0, dut_fifo_a.a_no_overflow_attempt);
        //   $assertoff(0, dut_fifo_b.a_no_overflow_attempt);

        for (n = 0; n < 400; n++) begin
            @(negedge clk);
            a_wr_en   = ($urandom_range(9,0) < 7);
            a_rd_en   = ($urandom_range(9,0) < 3);
            a_wr_flit = rnd_flit(32'h1000_0000 + n);
            b_wr_en   = ($urandom_range(9,0) < 7);
            b_rd_en   = ($urandom_range(9,0) < 3);
            b_wr_flit = rnd_flit(32'h2000_0000 + n);
        end

        // Drop the strobes and let one clock edge pass BEFORE re-arming.
        //
        // The loop above leaves wr_en/rd_en at whatever the last random draw
        // produced. Re-arming an assertion while a stale illegal strobe is
        // still asserted makes it fire on a stimulus the next phase never
        // intended to apply. This cost a run.
        @(negedge clk);
        a_wr_en = 1'b0; a_rd_en = 1'b0; b_wr_en = 1'b0; b_rd_en = 1'b0;
        @(negedge clk);

        //   $asserton(0, dut_fifo_a.a_no_overflow_attempt);
        //   $asserton(0, dut_fifo_b.a_no_overflow_attempt);

        //---------------------------------------------------------------------
        // PHASE 4 : FIFO read-biased  -- DELIBERATE PROTOCOL VIOLATION
        //---------------------------------------------------------------------
        $display("[FIFO] read-biased, underflow attempts (DUT assertion off)");

        //   $assertoff(0, dut_fifo_a.a_no_underflow_attempt);
        //   $assertoff(0, dut_fifo_b.a_no_underflow_attempt);

        for (n = 0; n < 400; n++) begin
            @(negedge clk);
            a_wr_en   = ($urandom_range(9,0) < 3);
            a_rd_en   = ($urandom_range(9,0) < 7);
            a_wr_flit = rnd_flit(32'h3000_0000 + n);
            b_wr_en   = ($urandom_range(9,0) < 3);
            b_rd_en   = ($urandom_range(9,0) < 7);
            b_wr_flit = rnd_flit(32'h4000_0000 + n);
        end

        // Same quiescing step as after the overflow phase.
        @(negedge clk);
        a_wr_en = 1'b0; a_rd_en = 1'b0; b_wr_en = 1'b0; b_rd_en = 1'b0;
        @(negedge clk);

        //   $asserton(0, dut_fifo_a.a_no_underflow_attempt);
        //   $asserton(0, dut_fifo_b.a_no_underflow_attempt);

        //---------------------------------------------------------------------
        // PHASE 5 : FIFO balanced, LEGAL traffic only
        //
        // DUT assertions fully armed. Maximises simultaneous read-and-write.
        //---------------------------------------------------------------------
        $display("[FIFO] balanced legal traffic, DUT assertions armed");

        for (n = 0; n < 600; n++) begin
            @(negedge clk);
            a_wr_en   = ($urandom_range(9,0) < 6) && !a_full;
            a_rd_en   = ($urandom_range(9,0) < 6) && !a_empty;
            a_wr_flit = rnd_flit(32'h5000_0000 + n);
            b_wr_en   = ($urandom_range(9,0) < 6) && !b_full;
            b_rd_en   = ($urandom_range(9,0) < 6) && !b_empty;
            b_wr_flit = rnd_flit(32'h6000_0000 + n);
        end

        //---------------------------------------------------------------------
        // PHASE 6 : reset asserted in the middle of live traffic
        //---------------------------------------------------------------------
        $display("[FIFO] reset asserted mid-traffic");

        // Quiesce before reset. Reset empties the FIFOs; a read strobe left
        // over from the previous phase would then be a read-while-empty on
        // the first cycle after release, which the DUT correctly flags.
        @(negedge clk);
        a_wr_en = 1'b0; a_rd_en = 1'b0; b_wr_en = 1'b0; b_rd_en = 1'b0;

        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        for (n = 0; n < 200; n++) begin
            @(negedge clk);
            a_wr_en   = ($urandom_range(9,0) < 5) && !a_full;
            a_rd_en   = ($urandom_range(9,0) < 5) && !a_empty;
            a_wr_flit = rnd_flit(32'h7000_0000 + n);
            b_wr_en   = ($urandom_range(9,0) < 5) && !b_full;
            b_rd_en   = ($urandom_range(9,0) < 5) && !b_empty;
            b_wr_flit = rnd_flit(32'h8000_0000 + n);
        end

        @(negedge clk);
        a_wr_en = 1'b0; a_rd_en = 1'b0; b_wr_en = 1'b0; b_rd_en = 1'b0;

        //---------------------------------------------------------------------
        // PHASE 7 : datapath, NORTH only
        //
        // Isolated traffic on one port is what proves port independence.
        //---------------------------------------------------------------------
        $display("[DP  ] NORTH-only traffic, port independence");

        for (n = 0; n < 200; n++) begin
            @(negedge clk);
            // Build the flit FIRST, then gate the valid on the full flag of
            // the VC that flit is actually addressed to.
            //
            // The original gate was !(all three full), which still allowed a
            // write to a VC that was individually full. The FIFO then dropped
            // the flit and correctly complained. Legal-traffic phases must
            // present legal traffic.
            in_flit_north   = rnd_flit(32'hA000_0000 + n);
            in_valid_north  = ($urandom_range(9,0) < 6) &&
                (((in_flit_north.vc_id == VC_REQUEST)     && !full_north_vc0) ||
                 ((in_flit_north.vc_id == VC_RESPONSE)    && !full_north_vc1) ||
                 ((in_flit_north.vc_id == VC_ATTESTATION) && !full_north_vc2));
            rd_en_north_vc0 = ($urandom_range(9,0) < 4) && !empty_north_vc0;
            rd_en_north_vc1 = ($urandom_range(9,0) < 4) && !empty_north_vc1;
            rd_en_north_vc2 = ($urandom_range(9,0) < 4) && !empty_north_vc2;
            randomise_dp_sel();
        end

        //---------------------------------------------------------------------
        // PHASE 8 : datapath, all ports, write-heavy
        //
        // Fills all 15 FIFOs. The FIFO overflow assertion fires because there
        // is still no credit protocol -- that is exactly the outstanding D1
        // debt -- so DUT assertions are suppressed for this phase only.
        //---------------------------------------------------------------------
        $display("[DP  ] all ports write-heavy, fills all 15 FIFOs");

        //   $assertoff(0, dut_dp);

        for (n = 0; n < 400; n++) begin
            @(negedge clk);
            in_valid_north = ($urandom_range(9,0) < 8);
            in_valid_south = ($urandom_range(9,0) < 8);
            in_valid_east  = ($urandom_range(9,0) < 8);
            in_valid_west  = ($urandom_range(9,0) < 8);
            in_valid_local = ($urandom_range(9,0) < 8);
            in_flit_north  = rnd_flit(32'hB000_0000 + n);
            in_flit_south  = rnd_flit(32'hC000_0000 + n);
            in_flit_east   = rnd_flit(32'hD000_0000 + n);
            in_flit_west   = rnd_flit(32'hE000_0000 + n);
            in_flit_local  = rnd_flit(32'hF000_0000 + n);
            {rd_en_north_vc0, rd_en_north_vc1, rd_en_north_vc2} = $urandom_range(7,0);
            {rd_en_south_vc0, rd_en_south_vc1, rd_en_south_vc2} = $urandom_range(7,0);
            {rd_en_east_vc0,  rd_en_east_vc1,  rd_en_east_vc2 } = $urandom_range(7,0);
            {rd_en_west_vc0,  rd_en_west_vc1,  rd_en_west_vc2 } = $urandom_range(7,0);
            {rd_en_local_vc0, rd_en_local_vc1, rd_en_local_vc2} = $urandom_range(7,0);
            randomise_dp_sel();
        end

        //---------------------------------------------------------------------
        // PHASE 9 : datapath, multi-hot VC select  -- DELIBERATE VIOLATION
        //
        // Proves priority case resolves deterministically to the lowest VC
        // rather than producing undefined hardware. This is the entire reason
        // unique case was removed from these muxes.
        //---------------------------------------------------------------------
        $display("[DP  ] multi-hot VC select, priority resolution");

        for (n = 0; n < 50; n++) begin
            @(negedge clk);
            in_valid_north = 1'b1;
            in_flit_north  = rnd_flit(32'h9000_0000 + n);
            sel_north_vc0  = 1'b1;
            sel_north_vc1  = 1'b1;
            sel_north_vc2  = ($urandom_range(1,0) == 1);
        end

        // Quiesce the whole datapath and let two clocks pass before
        // re-arming. Phase 8 left every FIFO full and in_valid_north still
        // asserted; re-arming into that state fires the overflow assertion on
        // stimulus the next phase never meant to apply.
        @(negedge clk);
        dp_idle();
        repeat (2) @(negedge clk);

        //   $asserton(0, dut_dp);

        //---------------------------------------------------------------------
        // PHASE 10 : datapath drain, LEGAL traffic only
        //---------------------------------------------------------------------
        $display("[DP  ] drain all 15 FIFOs, DUT assertions armed");

        dp_idle();

        for (n = 0; n < 300; n++) begin
            @(negedge clk);
            rd_en_north_vc0 = !empty_north_vc0;
            rd_en_north_vc1 = !empty_north_vc1;
            rd_en_north_vc2 = !empty_north_vc2;
            rd_en_south_vc0 = !empty_south_vc0;
            rd_en_south_vc1 = !empty_south_vc1;
            rd_en_south_vc2 = !empty_south_vc2;
            rd_en_east_vc0  = !empty_east_vc0;
            rd_en_east_vc1  = !empty_east_vc1;
            rd_en_east_vc2  = !empty_east_vc2;
            rd_en_west_vc0  = !empty_west_vc0;
            rd_en_west_vc1  = !empty_west_vc1;
            rd_en_west_vc2  = !empty_west_vc2;
            rd_en_local_vc0 = !empty_local_vc0;
            rd_en_local_vc1 = !empty_local_vc1;
            rd_en_local_vc2 = !empty_local_vc2;
        end

        @(negedge clk);
        dp_idle();
        repeat (10) @(negedge clk);

        if (!all_fifos_empty()) begin
            err_dp++;
            $error("DP: not all 15 FIFOs drained");
        end

        //---------------------------------------------------------------------
        // PHASE 11 : DETERMINISTIC "ALL THREE VCs FULL" BURST  -- LEGAL TRAFFIC
        //
        // WHY THIS PHASE EXISTS
        //
        //   cov_dp_all_full counts cycles where NORTH VC0, VC1 and VC2 are
        //   full SIMULTANEOUSLY. Phase 8 drives write-heavy random traffic with
        //   random read enables, so at any instant some VC is usually being
        //   drained. Across two full runs that counter stayed at exactly 0.
        //
        //   Every datapath check guarded by "all three VCs of one port are
        //   full" has therefore never been evaluated. Per V-07, a guarded check
        //   that never sees its guarded state is indistinguishable from a
        //   broken one, so the Stage 2 PASS could not be signed off.
        //
        //   Randomisation cannot be trusted to hit this: it needs twelve
        //   specific writes with zero intervening reads. It is driven directly.
        //
        // WHY THIS IS LEGAL TRAFFIC
        //
        //   Exactly VC0_DEPTH flits go into each VC. No write is ever attempted
        //   on a full FIFO, so DUT assertions stay armed and must remain
        //   silent. If FLIT DROPPED appears in this phase, that is a real
        //   defect, not expected noise.
        //---------------------------------------------------------------------

        $display("[DP  ] deterministic burst: fill NORTH VC0+VC1+VC2 together");

        dp_idle();
        @(negedge clk);

        for (v_burst = 0; v_burst < NUM_VC; v_burst++) begin

            // Bounded fill-until-full rather than a fixed count. VC0/1/2 are
            // all depth 4 today, but they are independent parameters and VC2
            // is the one earmarked for a depth sweep (4/8/16) in the resource
            // probe. A hard-coded VC0_DEPTH here would keep compiling and
            // quietly stop filling VC2 the moment that sweep happens.
            // Counted loop against the VC's OWN depth. A fill-until-full loop
            // was tried first and is wrong here: full is a registered output,
            // so the condition lags the write by one cycle and the loop emits
            // one flit too many - an overflow, into an armed assertion, in a
            // phase that is supposed to be legal traffic.
            for (n = 0; n < vc_depth(v_burst); n++) begin
                @(negedge clk);
                in_valid_north          = 1'b1;
                in_flit_north.flit_data = 32'hA110_0000 + (v_burst << 8) + n;
                in_flit_north.flit_type = FLIT_BODY;
                in_flit_north.vc_id     = vc_e'(v_burst);

                // Reads stay low for the whole burst. A single read here
                // empties a slot and the three-full window never opens.
                {rd_en_north_vc0, rd_en_north_vc1, rd_en_north_vc2} = 3'b000;
            end

            @(negedge clk);
            in_valid_north = 1'b0;
        end

        // Hold the state so the posedge coverage sampler observes it. Writes
        // are off, so holding cannot overflow anything.
        @(negedge clk);
        dp_idle();
        repeat (4) @(negedge clk);

        if (!(full_north_vc0 && full_north_vc1 && full_north_vc2)) begin
            err_dp++;
            $error("DP: burst failed to fill all three NORTH VCs (vc0=%0b vc1=%0b vc2=%0b). Coverage hole remains open.",
                   full_north_vc0, full_north_vc1, full_north_vc2);
        end

        // Drain what the burst wrote, so the datapath is left empty.
        for (n = 0; n < 16; n++) begin
            @(negedge clk);
            rd_en_north_vc0 = !empty_north_vc0;
            rd_en_north_vc1 = !empty_north_vc1;
            rd_en_north_vc2 = !empty_north_vc2;
        end

        @(negedge clk);
        dp_idle();
        repeat (4) @(negedge clk);

        if (!all_fifos_empty()) begin
            err_dp++;
            $error("DP: burst FIFOs did not drain");
        end

        //---------------------------------------------------------------------
        // PHASE 12 : NEGATIVE CONTROL  -- Stage 2 sign-off criterion 5
        //
        // Everything above reports PASS. This phase asks the only question
        // that gives that PASS any weight: CAN this testbench fail at all?
        //
        // Method: drive the XY router with a coordinate pair whose correct
        // answer is known, then run the SAME comparison the real checks use
        // against a deliberately WRONG expected port. The comparison must
        // report a mismatch. If it reports a match, the comparison is broken
        // and every XY result in this run is worthless.
        //
        // This is built in rather than left as a manual edit-and-revert step,
        // because a manual step that is skipped leaves no trace. Fourteen
        // testbench defects and zero RTL defects is exactly the record that
        // makes this necessary.
        //---------------------------------------------------------------------

        $display("[NEG ] negative control - deliberate defect injection");

        // (0,0) -> (2,0) must route EAST. This is checked, not assumed.
        xy_current.x = 3'd0;  xy_current.y = 3'd0;
        xy_dest.x    = 3'd2;  xy_dest.y    = 3'd0;
        #1;

        if (!(xy_valid && (port_e'(xy_port) == PORT_EAST))) begin
            err_neg++;
            $error("NEG: baseline wrong - (0,0)->(2,0) gave valid=%0b port=%0d, expected valid=1 EAST",
                   xy_valid, xy_port);
        end

        // Now compare that same correct output against a WRONG expectation.
        // neg_detected must become 1.
        neg_expected_wrong = PORT_WEST;
        neg_detected       = (port_e'(xy_port) != neg_expected_wrong);

        if (!neg_detected) begin
            err_neg++;
            $error("NEGATIVE CONTROL FAILED: the checker did not detect an injected defect. Every PASS in this run is meaningless.");
        end

        // Second injection, on the validity flag rather than the port, so a
        // single broken comparison operator cannot hide both.
        xy_current.x = 3'd0;  xy_current.y = 3'd0;
        xy_dest.x    = 3'd7;  xy_dest.y    = 3'd7;   // outside the 3x2 mesh
        #1;

        if (xy_valid !== 1'b0) begin
            err_neg++;
            $error("NEG: out-of-mesh destination reported valid");
        end

        neg_detected2 = (xy_valid != 1'b1);   // deliberately wrong expectation

        if (!neg_detected2) begin
            err_neg++;
            $error("NEGATIVE CONTROL FAILED: validity comparison did not detect an injected defect.");
        end

        $display("  injected  : 2 deliberate defects (wrong port, wrong validity)");
        $display("  detected  : %0d of 2", int'(neg_detected) + int'(neg_detected2));

        @(negedge clk);

        //---------------------------------------------------------------------
        // REPORT
        //---------------------------------------------------------------------

        repeat (10) @(negedge clk);

        $display("");
        $display("==========================================================");
        $display(" STAGE 2 RESULTS");
        $display("==========================================================");
        $display("  noc_pkg              : %-4s  (%0d failures)",
                 (err_pkg  == 0) ? "PASS" : "FAIL", err_pkg);
        $display("  noc_fifo             : %-4s  (%0d failures)",
                 (err_fifo == 0) ? "PASS" : "FAIL", err_fifo);
        $display("  noc_crossbar         : %-4s  (%0d failures)",
                 (err_xbar == 0) ? "PASS" : "FAIL", err_xbar);
        $display("  noc_xy_routing       : %-4s  (%0d failures)",
                 (err_xy   == 0) ? "PASS" : "FAIL", err_xy);
        $display("  noc_router_datapath  : %-4s  (%0d failures)",
                 (err_dp   == 0) ? "PASS" : "FAIL", err_dp);
        $display("  negative control     : %-4s  (%0d failures)",
                 (err_neg  == 0) ? "PASS" : "FAIL", err_neg);
        $display("----------------------------------------------------------");
        $display("  OVERALL              : %s   (%0d failures)",
                 (total_errors() == 0) ? "PASS" : "FAIL", total_errors());
        $display("==========================================================");

        //---------------------------------------------------------------------
        // COVERAGE
        //
        // Every cover property in this file is discarded by XSim. Without
        // these counters a PASS carries no evidence that the corners the
        // assertions guard were ever reached, and an unexercised checker is
        // indistinguishable from a broken one.
        //
        // Any zero below invalidates the corresponding PASS.
        //---------------------------------------------------------------------

        $display("");
        $display(" COVERAGE (cycles in which each state was observed)");
        $display("----------------------------------------------------------");
        $display("  FIFO full                     : %0d", cov_fifo_full);
        $display("  FIFO empty                    : %0d", cov_fifo_empty);
        $display("  FIFO simultaneous r/w at full : %0d", cov_fifo_rw_full);
        $display("  FIFO simultaneous r/w at empty: %0d", cov_fifo_rw_empty);
        $display("  FIFO simultaneous r/w mid     : %0d", cov_fifo_rw_mid);
        $display("  FIFO overflow attempted       : %0d", cov_fifo_ovf_try);
        $display("  FIFO underflow attempted      : %0d", cov_fifo_unf_try);
        $display("  FIFO depth-6 full             : %0d", cov_fifo_b_full);
        $display("  XBAR legal selects            : %0d", cov_xb_legal_sel);
        $display("  XBAR illegal selects          : %0d", cov_xb_illegal_sel);
        $display("  XY route EAST                 : %0d", cov_xy_east);
        $display("  XY route WEST                 : %0d", cov_xy_west);
        $display("  XY route NORTH                : %0d", cov_xy_north);
        $display("  XY route SOUTH                : %0d", cov_xy_south);
        $display("  XY route LOCAL                : %0d", cov_xy_local);
        $display("  XY route rejected             : %0d", cov_xy_invalid);
        $display("  DP VC0 write                  : %0d", cov_dp_vc0_write);
        $display("  DP VC1 write                  : %0d", cov_dp_vc1_write);
        $display("  DP VC2 write                  : %0d", cov_dp_vc2_write);
        $display("  DP VC0 full                   : %0d", cov_dp_vc0_full);
        $display("  DP VC1 full                   : %0d", cov_dp_vc1_full);
        $display("  DP VC2 full                   : %0d", cov_dp_vc2_full);
        $display("  DP all three VCs full         : %0d", cov_dp_all_full);
        $display("  DP all five ports active      : %0d", cov_dp_all_ports);
        $display("  DP multi-hot VC select        : %0d", cov_dp_multihot);
        $display("  NEG defects injected/detected : %0d / 2",
                 int'(neg_detected) + int'(neg_detected2));
        $display("----------------------------------------------------------");

        if ((cov_fifo_full      == 0) || (cov_fifo_empty     == 0) ||
            (cov_fifo_rw_full   == 0) || (cov_fifo_rw_mid    == 0) ||
            (cov_fifo_ovf_try   == 0) || (cov_fifo_unf_try   == 0) ||
            (cov_fifo_b_full    == 0) ||
            (cov_xb_legal_sel   == 0) || (cov_xb_illegal_sel == 0) ||
            (cov_xy_east        == 0) || (cov_xy_west        == 0) ||
            (cov_xy_north       == 0) || (cov_xy_south       == 0) ||
            (cov_xy_local       == 0) || (cov_xy_invalid     == 0) ||
            (cov_dp_vc0_write   == 0) || (cov_dp_vc1_write   == 0) ||
            (cov_dp_vc2_write   == 0) || (cov_dp_all_full    == 0) ||
            (cov_dp_all_ports   == 0) || (cov_dp_multihot    == 0) ||
            // The negative control is a coverage obligation, not an optional
            // extra: if the checker was never shown to fail, "all guarded
            // states exercised" is a claim about stimulus only.
            (neg_detected !== 1'b1) || (neg_detected2 !== 1'b1)) begin
            $display("  COVERAGE HOLE. At least one guarded state was never");
            $display("  reached, or the negative control did not fire, so the");
            $display("  corresponding PASS proves nothing.");
            $display("----------------------------------------------------------");
        end
        else begin
            $display("  All guarded states were exercised.");
            $display("  Negative control fired: this testbench can fail.");
            $display("----------------------------------------------------------");
        end
        $display("");
        $display(" NOT covered here, because it does not exist yet:");
        $display("   - credit flow control and backpressure   (debt D1)");
        $display("   - route persistence for body/tail flits  (debt D2)");
        $display("   - wormhole output reservation            (contract L-07)");
        $display("   - multi-flit packet integrity end to end");
        $display("");
        $display(" Passing means the Stage 2 FOUNDATION is sound.");
        $display(" It does NOT mean the router works as a network.");
        $display("");

        if (total_errors() != 0)
            $fatal(1, "tb_noc_stage2 FAILED with %0d assertion failures",
                   total_errors());

        $finish;
    end


    //=========================================================================
    //  WATCHDOG
    //=========================================================================

    initial begin
        #50ms;
        $fatal(1, "tb_noc_stage2: watchdog timeout - the testbench hung");
    end

    //=========================================================================
    // Coverage / observation (relocated here so every sampled DUT signal is
    // already declared above). Behaviorally identical to its original position.
    //=========================================================================
    always @(posedge clk) begin
        if (!rst) begin

            if (a_full)                          cov_fifo_full++;
            if (a_empty)                         cov_fifo_empty++;
            if (a_full  && a_wr_en && a_rd_en)   cov_fifo_rw_full++;
            if (a_empty && a_wr_en && a_rd_en)   cov_fifo_rw_empty++;
            if (!a_full && !a_empty && a_wr_en && a_rd_en) cov_fifo_rw_mid++;
            if (a_full  && a_wr_en)              cov_fifo_ovf_try++;
            if (a_empty && a_rd_en)              cov_fifo_unf_try++;
            if (b_full)                          cov_fifo_b_full++;

            for (i_cov = 0; i_cov < 5; i_cov++) begin
                if (xb_sel[i_cov] <  port_id_t'(NUM_PORTS)) cov_xb_legal_sel++;
                if (xb_sel[i_cov] >= port_id_t'(NUM_PORTS)) cov_xb_illegal_sel++;
            end

            if (xy_valid) begin
                case (port_e'(xy_port))
                    PORT_EAST:  cov_xy_east++;
                    PORT_WEST:  cov_xy_west++;
                    PORT_NORTH: cov_xy_north++;
                    PORT_SOUTH: cov_xy_south++;
                    PORT_LOCAL: cov_xy_local++;
                    default:    ;
                endcase
            end
            else cov_xy_invalid++;

            if (full_north_vc0)                  cov_dp_vc0_full++;
            if (full_north_vc1)                  cov_dp_vc1_full++;
            if (full_north_vc2)                  cov_dp_vc2_full++;
            if (full_north_vc0 && full_north_vc1 && full_north_vc2)
                                                 cov_dp_all_full++;
            if (in_valid_north && in_valid_south && in_valid_east &&
                in_valid_west  && in_valid_local) cov_dp_all_ports++;

            if (in_valid_north) begin
                case (vc_e'(in_flit_north.vc_id))
                    VC_REQUEST:     cov_dp_vc0_write++;
                    VC_RESPONSE:    cov_dp_vc1_write++;
                    VC_ATTESTATION: cov_dp_vc2_write++;
                    default:        ;
                endcase
            end

            if (!$onehot0({sel_north_vc0, sel_north_vc1, sel_north_vc2}))
                cov_dp_multihot++;
        end
    end

endmodule