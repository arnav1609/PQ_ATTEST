`timescale 1ns / 1ps
//=============================================================================
// tb_noc_golden.sv
//
// GOLDEN-MODEL EXHAUSTIVE VERIFICATION.
//
// Replays vector files produced by golden/golden_model.py -- an independent
// Python model written from the SPECIFICATION that has never read the RTL.
// Every expected value in this run came from that model, not from an
// expectation embedded in this file, so a shared misunderstanding between
// designer and verifier cannot hide the way it can in a hand-written test.
//
// VECTOR FILES (absolute paths, edit VEC_DIR if the project moves):
//
//   gv_xy.txt      4096 lines   cx cy dx dy  exp_valid exp_port
//                  COMPLETE over both 3-bit coordinate pairs, legal and not.
//
//   gv_xbar.txt   16807 lines   sel0..4  expsrc0..4  expval0..4
//                  COMPLETE over the 8^5 select space, loopback excluded.
//                  expsrc = index of the input that must appear, -1 = zero.
//
//   gv_fifo4.txt     89 lines   w r  count empty full free credit
//                                    pre_empty pre_full do_w do_r
//   gv_fifo6.txt    183 lines   same
//                  COMPLETE TRANSITION COVERAGE. The walk visits every
//                  reachable (count, wr_ptr, rd_ptr) state crossed with every
//                  (wr_en, rd_en) input -- 80 transitions at depth 4, 168 at
//                  depth 6, zero uncovered. Exhaustive over sequences is
//                  infinite; exhaustive over transitions is finite and is the
//                  stronger practical claim.
//
//   gv_vc.txt         8 lines   valid vc_id  w0 w1 w2
//                  COMPLETE, including the unused fourth vc_id encoding.
//
// This testbench uses NO $assertoff and NO cover property. Both are
// unsupported or silently degraded in XSim -- see VERIFICATION_LOG.md V-06
// and V-07. Every check here is procedural and therefore portable.
//=============================================================================

module tb_noc_golden;

    import noc_pkg::*;

    localparam string VEC_DIR = "C:/vivado_verilog_proj/NOC_PQATTEST/golden/";

    localparam time CLK_PERIOD = 20ns;
    localparam int unsigned DEPTH_A = 4;
    localparam int unsigned DEPTH_B = 6;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #(CLK_PERIOD/2) clk = ~clk;

    int unsigned err_xy   = 0, chk_xy   = 0;
    int unsigned err_xbar = 0, chk_xbar = 0;
    int unsigned err_fifo = 0, chk_fifo = 0;
    int unsigned err_vc   = 0, chk_vc   = 0;

    function automatic int unsigned total_errors();
        return err_xy + err_xbar + err_fifo + err_vc;
    endfunction


    //=========================================================================
    //  DUT 1 : noc_xy_routing
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


    //=========================================================================
    //  DUT 2 : noc_crossbar
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


    //=========================================================================
    //  DUT 3 and 4 : noc_fifo at two depths
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


    //=========================================================================
    //  DUT 5 : noc_router_datapath  (VC decode only)
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
    //  HELPERS
    //=========================================================================

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


    //=========================================================================
    //  TEST 1 : XY ROUTING  -- exhaustive, 4096 vectors
    //=========================================================================

    task automatic run_xy();
        int fd, code;
        int cx, cy, dx, dy, ev, ep;

        $display("[GOLD] XY routing   -- replaying gv_xy.txt");

        fd = $fopen({VEC_DIR, "gv_xy.txt"}, "r");
        if (fd == 0) begin
            err_xy++;
            $error("cannot open %sgv_xy.txt", VEC_DIR);
            return;
        end

        forever begin
            code = $fscanf(fd, "%d %d %d %d %d %d\n", cx, cy, dx, dy, ev, ep);
            if (code != 6) break;

            xy_current.x = cx[2:0];
            xy_current.y = cy[2:0];
            xy_dest.x    = dx[2:0];
            xy_dest.y    = dy[2:0];
            #1;
            chk_xy++;

            if (xy_valid !== ev[0]) begin
                err_xy++;
                if (err_xy <= 10)
                    $error("XY (%0d,%0d)->(%0d,%0d): route_valid got %b, golden %0d",
                           cx, cy, dx, dy, xy_valid, ev);
            end
            else if (ev == 1 && (xy_port !== port_id_t'(ep))) begin
                err_xy++;
                if (err_xy <= 10)
                    $error("XY (%0d,%0d)->(%0d,%0d): route_port got %0d, golden %0d",
                           cx, cy, dx, dy, xy_port, ep);
            end
        end
        $fclose(fd);

        // Park on a legal configuration.
        xy_current = tile_to_coord(TILE_CPU0);
        xy_dest    = tile_to_coord(TILE_ROT);
        #1;
    endtask


    //=========================================================================
    //  TEST 2 : CROSSBAR  -- exhaustive over the 8^5 select space
    //=========================================================================

    task automatic run_xbar();
        int fd, code, o;
        int s [5];
        int es[5];
        int ev[5];
        flit_t expected;

        $display("[GOLD] Crossbar     -- replaying gv_xbar.txt");

        for (o = 0; o < 5; o++) begin
            xb_in[o].flit_data = 32'hC0DE_0000 + o;
            xb_in[o].flit_type = flit_type_e'(o % 4);
            xb_in[o].vc_id     = o % NUM_VC;
            xb_vin[o]          = 1'b1;
        end

        fd = $fopen({VEC_DIR, "gv_xbar.txt"}, "r");
        if (fd == 0) begin
            err_xbar++;
            $error("cannot open %sgv_xbar.txt", VEC_DIR);
            return;
        end

        forever begin
            code = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                           s[0],  s[1],  s[2],  s[3],  s[4],
                           es[0], es[1], es[2], es[3], es[4],
                           ev[0], ev[1], ev[2], ev[3], ev[4]);
            if (code != 15) break;

            for (o = 0; o < 5; o++) xb_sel[o] = port_id_t'(s[o]);
            #1;
            chk_xbar++;

            for (o = 0; o < 5; o++) begin
                if (es[o] < 0) expected = '0;
                else           expected = xb_in[es[o]];

                if (xb_out[o] !== expected) begin
                    err_xbar++;
                    if (err_xbar <= 10)
                        $error("XBAR out %0d sel %0d: data 0x%0h, golden 0x%0h",
                               o, s[o], xb_out[o], expected);
                end
                if (xb_vout[o] !== ev[o][0]) begin
                    err_xbar++;
                    if (err_xbar <= 10)
                        $error("XBAR out %0d sel %0d: valid %b, golden %0d",
                               o, s[o], xb_vout[o], ev[o]);
                end
            end
        end
        $fclose(fd);

        // Park on a legal non-loopback permutation.
        for (o = 0; o < 5; o++) xb_sel[o] = port_id_t'((o + 1) % 5);
        #1;
    endtask


    //=========================================================================
    //  TEST 3 : FIFO  -- complete transition coverage of the control FSM
    //
    //  The golden walk drives every reachable state with every input, legal
    //  and illegal. Illegal inputs are the point: the model predicts that a
    //  refused write and a refused read leave state untouched, and this
    //  checks the DUT agrees.
    //
    //  The DUT's own assertions WILL fire during the illegal transitions.
    //  That is correct behaviour and is expected console noise. No assertion
    //  control is used here, because XSim's scoped $assertoff silently
    //  disables every assertion in the design (VERIFICATION_LOG V-06).
    //=========================================================================

    task automatic run_fifo(input string fname,
                            input int unsigned depth,
                            input bit is_a);
        int fd, code;
        int w, r, e_count, e_empty, e_full, e_free, e_credit;
        int e_pre_empty, e_pre_full, e_do_w, e_do_r;
        int unsigned tag;
        int unsigned got_count, got_free;
        flit_t exp_q [$];
        flit_t got_head;
        flit_t new_f;

        $display("[GOLD] FIFO depth %0d -- replaying %s", depth, fname);

        fd = $fopen({VEC_DIR, fname}, "r");
        if (fd == 0) begin
            err_fifo++;
            $error("cannot open %s%s", VEC_DIR, fname);
            return;
        end

        // Reset this FIFO to a known state.
        rst = 1'b1;
        if (is_a) begin a_wr_en = 0; a_rd_en = 0; end
        else      begin b_wr_en = 0; b_rd_en = 0; end
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        exp_q.delete();

        tag = 32'h5EED_0000;

        forever begin
            code = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d\n",
                           w, r, e_count, e_empty, e_full, e_free, e_credit,
                           e_pre_empty, e_pre_full, e_do_w, e_do_r);
            if (code != 11) break;

            // ---- check the PRE-state the golden model expects -------------
            chk_fifo++;
            if (is_a) begin
                if (a_empty !== e_pre_empty[0]) begin
                    err_fifo++;
                    if (err_fifo <= 10)
                        $error("FIFO%0d pre-state empty %b, golden %0d",
                               depth, a_empty, e_pre_empty);
                end
                if (a_full !== e_pre_full[0]) begin
                    err_fifo++;
                    if (err_fifo <= 10)
                        $error("FIFO%0d pre-state full %b, golden %0d",
                               depth, a_full, e_pre_full);
                end
            end
            else begin
                if (b_empty !== e_pre_empty[0]) begin
                    err_fifo++;
                    if (err_fifo <= 10)
                        $error("FIFO%0d pre-state empty %b, golden %0d",
                               depth, b_empty, e_pre_empty);
                end
                if (b_full !== e_pre_full[0]) begin
                    err_fifo++;
                    if (err_fifo <= 10)
                        $error("FIFO%0d pre-state full %b, golden %0d",
                               depth, b_full, e_pre_full);
                end
            end

            // ---- ordering check on the head before the transition ---------
            if (e_pre_empty == 0) begin
                got_head = is_a ? a_rd_flit : b_rd_flit;
                if (got_head !== exp_q[0]) begin
                    err_fifo++;
                    if (err_fifo <= 10)
                        $error("FIFO%0d head 0x%0h, golden 0x%0h -- ORDERING",
                               depth, got_head.flit_data, exp_q[0].flit_data);
                end
            end

            // ---- apply the transition -------------------------------------
            tag = tag + 1;
            if (is_a) begin
                a_wr_flit.flit_data = tag;
                a_wr_flit.flit_type = FLIT_BODY;
                a_wr_flit.vc_id     = VC_REQUEST;
                a_wr_en = w[0];
                a_rd_en = r[0];
            end
            else begin
                b_wr_flit.flit_data = tag;
                b_wr_flit.flit_type = FLIT_BODY;
                b_wr_flit.vc_id     = VC_REQUEST;
                b_wr_en = w[0];
                b_rd_en = r[0];
            end

            // Mirror the transition in the expected-data queue, using the
            // golden model's own accept decisions.
            if (e_do_r) void'(exp_q.pop_front());
            if (e_do_w) begin
                new_f.flit_data = tag;
                new_f.flit_type = FLIT_BODY;
                new_f.vc_id     = VC_REQUEST;
                exp_q.push_back(new_f);
            end

            @(posedge clk);
            #1;

            // ---- check the POST-state -------------------------------------
            got_count = is_a ? a_occ  : b_occ;
            got_free  = is_a ? a_free : b_free;
            chk_fifo++;

            if (int'(got_count) !== e_count) begin
                err_fifo++;
                if (err_fifo <= 10)
                    $error("FIFO%0d occupancy %0d, golden %0d (w=%0d r=%0d)",
                           depth, got_count, e_count, w, r);
            end
            if (int'(got_free) !== e_free) begin
                err_fifo++;
                if (err_fifo <= 10)
                    $error("FIFO%0d free_slots %0d, golden %0d",
                           depth, got_free, e_free);
            end
            if ((is_a ? a_empty : b_empty) !== e_empty[0]) begin
                err_fifo++;
                if (err_fifo <= 10)
                    $error("FIFO%0d empty %b, golden %0d",
                           depth, (is_a ? a_empty : b_empty), e_empty);
            end
            if ((is_a ? a_full : b_full) !== e_full[0]) begin
                err_fifo++;
                if (err_fifo <= 10)
                    $error("FIFO%0d full %b, golden %0d",
                           depth, (is_a ? a_full : b_full), e_full);
            end
            if ((is_a ? a_credit : b_credit) !== e_credit[0]) begin
                err_fifo++;
                if (err_fifo <= 10)
                    $error("FIFO%0d credit %b, golden %0d",
                           depth, (is_a ? a_credit : b_credit), e_credit);
            end

            @(negedge clk);
        end
        $fclose(fd);

        if (is_a) begin a_wr_en = 0; a_rd_en = 0; end
        else      begin b_wr_en = 0; b_rd_en = 0; end
        @(negedge clk);
    endtask


    //=========================================================================
    //  TEST 4 : VC DECODE  -- exhaustive over valid x vc_id
    //
    //  Checks against the DUT's internal occupancy counters, because 'empty'
    //  only moves at the 0<->1 boundary and would miss leakage into a VC that
    //  already holds data (VERIFICATION_LOG V-01).
    //=========================================================================

    task automatic run_vc();
        int fd, code;
        int valid, vc, e0, e1, e2;
        int unsigned c0, c1, c2, n0, n1, n2;
        int unsigned tag;

        $display("[GOLD] VC decode    -- replaying gv_vc.txt");

        fd = $fopen({VEC_DIR, "gv_vc.txt"}, "r");
        if (fd == 0) begin
            err_vc++;
            $error("cannot open %sgv_vc.txt", VEC_DIR);
            return;
        end

        rst = 1'b1;
        dp_idle();
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        tag = 32'h0BAD_0000;

        forever begin
            code = $fscanf(fd, "%d %d %d %d %d\n", valid, vc, e0, e1, e2);
            if (code != 5) break;

            c0 = dut_dp.north_vc0_fifo.count;
            c1 = dut_dp.north_vc1_fifo.count;
            c2 = dut_dp.north_vc2_fifo.count;

            tag = tag + 1;
            in_flit_north.flit_data = tag;
            in_flit_north.flit_type = FLIT_BODY;
            in_flit_north.vc_id     = vc[VC_ID_WIDTH-1:0];
            in_valid_north          = valid[0];

            @(posedge clk);
            #1;

            n0 = dut_dp.north_vc0_fifo.count;
            n1 = dut_dp.north_vc1_fifo.count;
            n2 = dut_dp.north_vc2_fifo.count;

            chk_vc++;

            if (int'(n0) - int'(c0) !== e0) begin
                err_vc++;
                $error("VC decode valid=%0d vc_id=%0d: VC0 delta %0d, golden %0d",
                       valid, vc, int'(n0) - int'(c0), e0);
            end
            if (int'(n1) - int'(c1) !== e1) begin
                err_vc++;
                $error("VC decode valid=%0d vc_id=%0d: VC1 delta %0d, golden %0d",
                       valid, vc, int'(n1) - int'(c1), e1);
            end
            if (int'(n2) - int'(c2) !== e2) begin
                err_vc++;
                $error("VC decode valid=%0d vc_id=%0d: VC2 delta %0d, golden %0d",
                       valid, vc, int'(n2) - int'(c2), e2);
            end

            in_valid_north = 1'b0;
            @(negedge clk);
        end
        $fclose(fd);

        dp_idle();
        @(negedge clk);
    endtask


    //=========================================================================
    //  MAIN
    //=========================================================================

    initial begin
        int o;

        $display("");
        $display("==========================================================");
        $display(" tb_noc_golden   GOLDEN-MODEL EXHAUSTIVE VERIFICATION");
        $display("==========================================================");
        $display(" Expected values come from golden/golden_model.py, an");
        $display(" independent model written from the specification.");
        $display(" Vector directory: %s", VEC_DIR);
        $display("----------------------------------------------------------");

        xy_current = '0;
        xy_dest    = '0;
        for (o = 0; o < 5; o++) begin
            xb_in[o]  = '0;
            xb_vin[o] = 1'b1;
            xb_sel[o] = port_id_t'((o + 1) % 5);
        end
        a_wr_flit = '0; a_wr_en = 0; a_rd_en = 0;
        b_wr_flit = '0; b_wr_en = 0; b_rd_en = 0;
        in_flit_north = '0; in_flit_south = '0; in_flit_east = '0;
        in_flit_west  = '0; in_flit_local = '0;
        dp_idle();

        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        run_xy();
        run_xbar();
        run_fifo("gv_fifo4.txt", DEPTH_A, 1'b1);
        run_fifo("gv_fifo6.txt", DEPTH_B, 1'b0);
        run_vc();

        repeat (5) @(negedge clk);

        $display("");
        $display("==========================================================");
        $display(" GOLDEN-MODEL RESULTS");
        $display("==========================================================");
        $display("  XY routing      : %-4s  %0d checks, %0d mismatches",
                 (err_xy   == 0) ? "PASS" : "FAIL", chk_xy,   err_xy);
        $display("  Crossbar        : %-4s  %0d checks, %0d mismatches",
                 (err_xbar == 0) ? "PASS" : "FAIL", chk_xbar, err_xbar);
        $display("  FIFO            : %-4s  %0d checks, %0d mismatches",
                 (err_fifo == 0) ? "PASS" : "FAIL", chk_fifo, err_fifo);
        $display("  VC decode       : %-4s  %0d checks, %0d mismatches",
                 (err_vc   == 0) ? "PASS" : "FAIL", chk_vc,   err_vc);
        $display("----------------------------------------------------------");
        $display("  OVERALL         : %s   (%0d mismatches)",
                 (total_errors() == 0) ? "PASS" : "FAIL", total_errors());
        $display("==========================================================");
        $display("");
        $display(" A zero check count means a vector file failed to open.");
        $display(" Expected counts: XY 4096, XBAR 16807 x 10, FIFO 544, VC 8.");
        $display("");

        if ((chk_xy == 0) || (chk_xbar == 0) || (chk_fifo == 0) || (chk_vc == 0))
            $fatal(1, "tb_noc_golden: a vector file did not load. Check VEC_DIR.");

        if (total_errors() != 0)
            $fatal(1, "tb_noc_golden FAILED with %0d mismatches", total_errors());

        $finish;
    end

    initial begin
        #500ms;
        $fatal(1, "tb_noc_golden: watchdog timeout");
    end

endmodule