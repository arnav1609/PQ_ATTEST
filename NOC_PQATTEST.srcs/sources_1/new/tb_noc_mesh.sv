`timescale 1ns/1ps

// ============================================================================
// N-7 RIGOROUS 3x2 MESH REGRESSION
//
// Purpose
//   Validate the 3x2 mesh. Since the path-to-N-8 step 1 the DUT is the
//   synthesizable noc_mesh_3x2 (wiring lifted from this harness); the TB
//   observes its internal link nets hierarchically for the link checks.
//   (Historical note below kept for provenance.)
//   Originally: validate the EXISTING noc_router (M8/M9) instances.
//   The submitted NOC_PQATTEST(3).zip contains no noc_mesh.sv and no N-7 TB,
//   so this TB is deliberately a router-level mesh harness rather than a
//   fabricated RTL wrapper.
//
// Frozen topology
//        0 CPU0 ---- 1 CPU1 ---- 2 MEMORY
//         |           |           |
//        3 CRYPTO --- 4 RoT ---- 5 SPOOF
//
// Critical fixes versus the failed N-7 harness
//   1. Local endpoint credit is returned ONE CLOCK after LOCAL consumption.
//      LOCAL is a downstream consumer; otherwise the router's LOCAL credit
//      counter drains permanently at depth 4.
//   2. wait_quiet checks ALL 30 physical router outputs, not LOCAL only.
//      LOCAL-idle is not proof that intermediate wormhole traffic is gone.
//   3. Mesh data links and inter-router credit links are explicit continuous
//      connections. No procedural hierarchical wiring block is used.
//   4. Reset is asserted for exactly two active edges, then released. The
//      post-reset check is after the release edge. This avoids repeatedly
//      exercising a reset assertion across an extended reset interval.
//   5. Every valid inter-router flit is checked for legal VC encoding at the
//      mesh boundary. A bad VC cannot be hidden by the scoreboard.
//   6. Tests use simultaneous injection for actual contention cases.
//   7. Every test has a bounded drain timeout; a deadlock cannot hang the TB.
//   8. Scoreboard keys are source/destination/VC, and LOCAL delivery checks
//      both source and destination coordinates.
//
// This TB does NOT claim that the RTL reset SVA is fixed. If the existing
// noc_router assertion still fires after this reset sequence, that is an RTL
// assertion/state issue and must be fixed in noc_router.sv rather than masked
// in this TB.
// ============================================================================

// TB_LINK_PIPE selects noc_mesh_3x2.LINK_PIPE (D7). Default 1 = synthesized config.
module tb_noc_mesh_n7 #(parameter bit TB_LINK_PIPE = 1'b1);

    import noc_pkg::*;

    localparam int N = 6;
    localparam int SB_KEYS = N*N*NUM_VC;

    localparam tile_id_e TILES [0:N-1] = '{
        TILE_CPU0, TILE_CPU1, TILE_MEMORY,
        TILE_CRYPTO, TILE_ROT, TILE_SPOOF
    };

    coord_t C [0:N-1];

    logic clk;
    logic rst;

    // Local injection into each router.
    flit_t inj_flit  [0:N-1];
    logic  inj_valid [0:N-1];

    // Router outputs.
    flit_t out_n [0:N-1], out_s [0:N-1];
    flit_t out_e [0:N-1], out_w [0:N-1], out_l [0:N-1];
    logic  out_v_n [0:N-1], out_v_s [0:N-1];
    logic  out_v_e [0:N-1], out_v_w [0:N-1], out_v_l [0:N-1];

    // Router physical inputs.
    flit_t in_n [0:N-1], in_s [0:N-1];
    flit_t in_e [0:N-1], in_w [0:N-1];
    logic  in_v_n [0:N-1], in_v_s [0:N-1];
    logic  in_v_e [0:N-1], in_v_w [0:N-1];


    // (credit wiring and LOCAL credit now live inside noc_mesh_3x2)
    logic              inj_ready [0:N-1];
    integer            inj_blocked;

    integer expected [0:SB_KEYS-1];
    integer observed [0:SB_KEYS-1];
    integer checks;
    integer errors;
    integer protocol_errors;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Generic checker
    // ------------------------------------------------------------------------
    task automatic check(input logic condition, input string message);
        begin
            checks++;
            if (condition)
                $display("[PASS] %s", message);
            else begin
                errors++;
                $display("[FAIL] %s", message);
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------
    function automatic integer key_of(input integer src,
                                       input integer dst,
                                       input integer vc);
        key_of = src*18 + dst*3 + vc;
    endfunction

    function automatic integer tile_from_coord(input coord_t cc);
        integer k;
        begin
            tile_from_coord = -1;
            for (k=0; k<N; k=k+1)
                if ((C[k].x == cc.x) && (C[k].y == cc.y))
                    tile_from_coord = k;
        end
    endfunction

    function automatic logic legal_vc(input logic [VC_ID_WIDTH-1:0] vc);
        legal_vc = (int'(vc) < NUM_VC);
    endfunction

    function automatic logic legal_flit_type(input flit_type_e ft);
        legal_flit_type =
            (ft == FLIT_HEAD) || (ft == FLIT_BODY) ||
            (ft == FLIT_TAIL) || (ft == FLIT_HEAD_TAIL);
    endfunction

    function automatic flit_t make_flit(input integer src,
                                         input integer dst,
                                         input integer vc,
                                         input flit_type_e ft,
                                         input integer tag);
        flit_t f;
        head_flit_t h;
        begin
            f = '0;
            h = '0;

            h.dest_x = C[dst].x;
            h.dest_y = C[dst].y;
            h.src_x  = C[src].x;
            h.src_y  = C[src].y;
            h.length = 5'd1;
            h.control = '0;
            h.control.raw[0] = tag[0];

            case (vc)
                VC_REQUEST:     h.msg_type = MSG_MEM_RD_REQ;
                VC_RESPONSE:    h.msg_type = MSG_MEM_RD_RESP;
                VC_ATTESTATION: h.msg_type = MSG_ATTEST_CHALLENGE;
                default:        h.msg_type = MSG_MEM_RD_REQ;
            endcase

            f.flit_data = h;
            f.flit_type = ft;
            f.vc_id     = vc;
            make_flit   = f;
        end
    endfunction

    task automatic clear_injection;
        integer i;
        begin
            for (i=0; i<N; i=i+1) begin
                inj_flit[i]  = '0;
                inj_valid[i] = 1'b0;
            end
        end
    endtask

    task automatic clear_scoreboard;
        integer i;
        begin
            for (i=0; i<SB_KEYS; i=i+1) begin
                expected[i] = 0;
                observed[i] = 0;
            end
        end
    endtask

    task automatic reset_mesh;
        begin
            clear_injection();
            rst = 1'b1;

            // Exactly two reset sampling edges.
            @(posedge clk);
            #1;
            @(posedge clk);
            #1;

            // Release reset before the next active edge.
            rst = 1'b0;

            // Verify the first post-reset state, not the pre-edge reset state.
            @(posedge clk);
            #1;

            check(!(out_v_n[0]||out_v_s[0]||out_v_e[0]||out_v_w[0]||out_v_l[0]),
                  "reset: router 0 quiet after release");
            check(!(out_v_n[1]||out_v_s[1]||out_v_e[1]||out_v_w[1]||out_v_l[1]),
                  "reset: router 1 quiet after release");
            check(!(out_v_n[2]||out_v_s[2]||out_v_e[2]||out_v_w[2]||out_v_l[2]),
                  "reset: router 2 quiet after release");
            check(!(out_v_n[3]||out_v_s[3]||out_v_e[3]||out_v_w[3]||out_v_l[3]),
                  "reset: router 3 quiet after release");
            check(!(out_v_n[4]||out_v_s[4]||out_v_e[4]||out_v_w[4]||out_v_l[4]),
                  "reset: router 4 quiet after release");
            check(!(out_v_n[5]||out_v_s[5]||out_v_e[5]||out_v_w[5]||out_v_l[5]),
                  "reset: router 5 quiet after release");
        end
    endtask

    task automatic inject_one(input integer src,
                              input integer dst,
                              input integer vc,
                              input integer tag);
        begin
            check((src >= 0) && (src < N), "inject source index legal");
            check((dst >= 0) && (dst < N), "inject destination index legal");
            check((vc >= 0) && (vc < NUM_VC), "inject VC legal");

            @(negedge clk);
            clear_injection();
            inj_flit[src]  = make_flit(src,dst,vc,FLIT_HEAD_TAIL,tag);
            inj_valid[src] = 1'b1;

            @(posedge clk);
            #1;
            clear_injection();

            expected[key_of(src,dst,vc)]++;
        end
    endtask

    task automatic inject_simultaneous6(input integer base_tag);
        integer s, d, v;
        begin
            clear_injection();

            for (s=0; s<N; s=s+1) begin
                d = (s+2)%N;
                v = s%NUM_VC;
                inj_flit[s]  = make_flit(s,d,v,FLIT_HEAD_TAIL,base_tag+s);
                inj_valid[s] = 1'b1;
                expected[key_of(s,d,v)]++;
            end

            // All six local injections are held through one common edge.
            @(posedge clk);
            #1;
            clear_injection();
        end
    endtask

    task automatic inject_many_to_one_simultaneous(input integer dst,
                                                    input integer base_tag);
        integer s;
        integer v;
        begin
            clear_injection();
            for (s=0; s<N; s=s+1) begin
                if (s != dst) begin
                    v = s % NUM_VC;
                    inj_flit[s]  = make_flit(s,dst,v,FLIT_HEAD_TAIL,base_tag+s);
                    inj_valid[s] = 1'b1;
                    expected[key_of(s,dst,v)]++;
                end
            end

            @(posedge clk);
            #1;
            clear_injection();
        end
    endtask

    task automatic inject_head_on_simultaneous;
        begin
            clear_injection();

            // Two opposite horizontal flows and two opposite vertical flows.
            inj_flit[0]  = make_flit(0,2,VC_REQUEST,FLIT_HEAD_TAIL,16'h510);
            inj_valid[0] = 1'b1;
            expected[key_of(0,2,VC_REQUEST)]++;

            inj_flit[2]  = make_flit(2,0,VC_RESPONSE,FLIT_HEAD_TAIL,16'h511);
            inj_valid[2] = 1'b1;
            expected[key_of(2,0,VC_RESPONSE)]++;

            inj_flit[1]  = make_flit(1,4,VC_ATTESTATION,FLIT_HEAD_TAIL,16'h512);
            inj_valid[1] = 1'b1;
            expected[key_of(1,4,VC_ATTESTATION)]++;

            inj_flit[4]  = make_flit(4,1,VC_REQUEST,FLIT_HEAD_TAIL,16'h513);
            inj_valid[4] = 1'b1;
            expected[key_of(4,1,VC_REQUEST)]++;

            @(posedge clk);
            #1;
            clear_injection();
        end
    endtask

    // ------------------------------------------------------------------------
    // Drain detector.
    // ALL router outputs are included. LOCAL-only observation was a false
    // drain criterion in the previous harness.
    // ------------------------------------------------------------------------
    // D7 (LINK_PIPE): a flit can sit in a link register while every router
    // output is idle, so the link-stage outputs (in_v_*) are included too.
    function automatic logic mesh_outputs_idle;
        mesh_outputs_idle = 1'b1;
        for (int i=0; i<N; i=i+1) begin
            if (out_v_n[i] || out_v_s[i] || out_v_e[i] ||
                out_v_w[i] || out_v_l[i] ||
                in_v_n[i]  || in_v_s[i]  || in_v_e[i]  || in_v_w[i])
                mesh_outputs_idle = 1'b0;
        end
    endfunction

    task automatic wait_mesh_quiet;
        integer quiet_cycles;
        integer timeout_cycles;
        begin
            quiet_cycles   = 0;
            timeout_cycles = 0;

            while ((quiet_cycles < 5) && (timeout_cycles < 200)) begin
                @(negedge clk);
                #1;

                if (mesh_outputs_idle())
                    quiet_cycles++;
                else
                    quiet_cycles = 0;

                timeout_cycles++;
            end

            check(quiet_cycles >= 5,
                  $sformatf("mesh drain completed within %0d cycles", timeout_cycles));
        end
    endtask

    task automatic check_scoreboard(input string phase);
        integer i;
        begin
            for (i=0; i<SB_KEYS; i=i+1) begin
                check(observed[i] == expected[i],
                      $sformatf("%s key=%0d exp=%0d obs=%0d",
                                phase,i,expected[i],observed[i]));
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // DUT: synthesizable noc_mesh_3x2 (step 1 of the path to N-8).
    // The six routers and all link/credit wiring now live in the RTL module,
    // lifted verbatim from this harness. LOCAL credit_return is tied 0 inside
    // the mesh (7c: ignored by the router), which replaces the old
    // local_credit_return generator. The TB keeps its own names for the
    // internal link nets and OBSERVES them hierarchically (no driving).
    // ------------------------------------------------------------------------
    flit_t [N-1:0] m_in_flit, m_out_flit;
    logic  [N-1:0] m_in_valid, m_in_ready, m_out_valid;

    noc_mesh_3x2 #(.LINK_PIPE(TB_LINK_PIPE)) u_mesh (
        .clk           (clk),
        .rst           (rst),
        .tile_in_flit  (m_in_flit),
        .tile_in_valid (m_in_valid),
        .tile_in_ready (m_in_ready),
        .tile_out_flit (m_out_flit),
        .tile_out_valid(m_out_valid),
        .tile_out_ready({N{1'b1}})      // TB sink always accepts
    );

    genvar g;
    generate
        for (g=0; g<N; g=g+1) begin : GEN_OBS
            assign m_in_flit[g]  = inj_flit[g];
            assign m_in_valid[g] = inj_valid[g];
            assign inj_ready[g]  = m_in_ready[g];

            assign out_n[g] = u_mesh.out_n[g];   assign out_v_n[g] = u_mesh.out_v_n[g];
            assign out_s[g] = u_mesh.out_s[g];   assign out_v_s[g] = u_mesh.out_v_s[g];
            assign out_e[g] = u_mesh.out_e[g];   assign out_v_e[g] = u_mesh.out_v_e[g];
            assign out_w[g] = u_mesh.out_w[g];   assign out_v_w[g] = u_mesh.out_v_w[g];
            assign out_l[g] = u_mesh.out_l[g];   assign out_v_l[g] = u_mesh.out_v_l[g];

            assign in_n[g] = u_mesh.in_n[g];     assign in_v_n[g] = u_mesh.in_v_n[g];
            assign in_s[g] = u_mesh.in_s[g];     assign in_v_s[g] = u_mesh.in_v_s[g];
            assign in_e[g] = u_mesh.in_e[g];     assign in_v_e[g] = u_mesh.in_v_e[g];
            assign in_w[g] = u_mesh.in_w[g];     assign in_v_w[g] = u_mesh.in_v_w[g];
        end
    endgenerate

    // Cross-check: the mesh's LOCAL port IS router g's LOCAL output.
    // (tile_out_* must equal the observed out_l / out_v_l.)
    // Never cleared (T7 applies a mid-run reset): counts over the whole run.
    integer port_mismatch = 0;
    always @(posedge clk) begin
        if (!rst) begin
            for (int k=0; k<N; k++)
                if ((m_out_valid[k] !== out_v_l[k]) ||
                    (m_out_valid[k] && (m_out_flit[k] !== out_l[k])))
                    port_mismatch <= port_mismatch + 1;
        end
    end

    // ------------------------------------------------------------------------
    // 7c: an injection presented while the router is not ready is NOT
    // accepted. This TB injects single-cycle pulses, so any such cycle is a
    // lost flit and must be counted as an error, never silently absorbed.
    // ------------------------------------------------------------------------
    integer ib;
    always @(negedge clk) begin
        if (!rst) begin
            for (ib=0; ib<N; ib=ib+1) begin
                if (inj_valid[ib] && !inj_ready[ib]) begin
                    inj_blocked++;
                    errors++;
                    $display("[FAIL] router %0d LOCAL injection while in_ready_local=0", ib);
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // End-to-end LOCAL sink scoreboard.
    // Sample at negedge, before the following dequeue edge.
    // ------------------------------------------------------------------------
    integer mi;
    always @(negedge clk) begin
        head_flit_t h;
        coord_t sc;
        integer src;
        integer vc;

        for (mi=0; mi<N; mi=mi+1) begin
            if (out_v_l[mi]) begin
                h = head_flit_t'(out_l[mi].flit_data);
                sc.x = h.src_x;
                sc.y = h.src_y;
                src  = tile_from_coord(sc);
                vc   = int'(out_l[mi].vc_id);

                check(legal_vc(out_l[mi].vc_id),
                      $sformatf("LOCAL router %0d VC encoding legal",mi));
                check(legal_flit_type(out_l[mi].flit_type),
                      $sformatf("LOCAL router %0d flit type legal",mi));

                if ((src >= 0) && (src < N) && (vc >= 0) && (vc < NUM_VC)) begin
                    observed[key_of(src,mi,vc)]++;
                    check((h.dest_x == C[mi].x) && (h.dest_y == C[mi].y),
                          $sformatf("LOCAL delivery destination src=%0d dst=%0d vc=%0d",
                                    src,mi,vc));
                end
                else begin
                    protocol_errors++;
                    errors++;
                    $display("[FAIL] malformed LOCAL packet at dst=%0d src=%0d vc=%0d",
                             mi,src,vc);
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Mesh-link protocol monitor.
    // ------------------------------------------------------------------------
    task automatic check_link(input logic v,
                              input flit_t f,
                              input string link_name);
        begin
            if (v) begin
                check(legal_vc(f.vc_id),
                      $sformatf("%s valid flit has legal VC",link_name));
                check(legal_flit_type(f.flit_type),
                      $sformatf("%s valid flit has legal type",link_name));
            end
        end
    endtask

    always @(negedge clk) begin
        check_link(in_v_w[1],in_w[1],"R0->R1");
        check_link(in_v_e[0],in_e[0],"R1->R0");
        check_link(in_v_w[2],in_w[2],"R1->R2");
        check_link(in_v_e[1],in_e[1],"R2->R1");
        check_link(in_v_w[4],in_w[4],"R3->R4");
        check_link(in_v_e[3],in_e[3],"R4->R3");
        check_link(in_v_w[5],in_w[5],"R4->R5");
        check_link(in_v_e[4],in_e[4],"R5->R4");
        check_link(in_v_n[3],in_n[3],"R0->R3");
        check_link(in_v_s[0],in_s[0],"R3->R0");
        check_link(in_v_n[4],in_n[4],"R1->R4");
        check_link(in_v_s[1],in_s[1],"R4->R1");
        check_link(in_v_n[5],in_n[5],"R2->R5");
        check_link(in_v_s[2],in_s[2],"R5->R2");
    end

    // ------------------------------------------------------------------------
    // Main regression
    // ------------------------------------------------------------------------
    integer s, d, v, tag;

    initial begin
        checks = 0;
        errors = 0;
        protocol_errors = 0;
        inj_blocked = 0;
        rst = 1'b0;
        clear_injection();
        clear_scoreboard();

        for (s=0; s<N; s=s+1)
            C[s] = tile_to_coord(TILES[s]);

        $display("N-7 CONFIG: TB_LINK_PIPE = %0d (noc_mesh_3x2.LINK_PIPE)", TB_LINK_PIPE);

        // T1: edge tie-off + clean reset.
        $display("\n============================================================");
        $display("N-7 T1 EDGE TIE-OFF + RESET");
        $display("============================================================");
        reset_mesh();

        repeat (3) begin
            @(negedge clk);
            #1;
            check(!out_v_w[0] && !out_v_n[0],
                  "T1 router 0 nonexistent WEST/NORTH quiet");
            check(!out_v_e[2] && !out_v_n[2],
                  "T1 router 2 nonexistent EAST/NORTH quiet");
            check(!out_v_w[3] && !out_v_s[3],
                  "T1 router 3 nonexistent WEST/SOUTH quiet");
            check(!out_v_e[5] && !out_v_s[5],
                  "T1 router 5 nonexistent EAST/SOUTH quiet");
        end

        // T2: exhaustive 30 remote pairs x 3 VCs.
        // One packet at a time here is intentional: this isolates routing and
        // credit conservation before the later contention tests.
        $display("\n============================================================");
        $display("N-7 T2 ALL 30 REMOTE PAIRS x 3 VCs");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();
        tag = 16'h2000;

        for (s=0; s<N; s=s+1) begin
            for (d=0; d<N; d=d+1) begin
                if (s != d) begin
                    for (v=0; v<NUM_VC; v=v+1) begin
                        inject_one(s,d,v,tag);
                        tag++;
                        wait_mesh_quiet();
                    end
                end
            end
        end
        check_scoreboard("T2");

        // T3: six simultaneous flows.
        $display("\n============================================================");
        $display("N-7 T3 SIMULTANEOUS SIX-SOURCE TRAFFIC");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();
        inject_simultaneous6(16'h3000);
        wait_mesh_quiet();
        check_scoreboard("T3");

        // T4: true many-to-one contention.
        $display("\n============================================================");
        $display("N-7 T4 MANY-TO-ONE CONTENTION");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();
        inject_many_to_one_simultaneous(4,16'h4000);
        wait_mesh_quiet();
        check_scoreboard("T4");

        // T5: simultaneous head-on traffic.
        $display("\n============================================================");
        $display("N-7 T5 BIDIRECTIONAL / HEAD-ON");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();
        inject_head_on_simultaneous();
        wait_mesh_quiet();
        check_scoreboard("T5");

        // T6: same source/destination, all three VCs at once. This specifically
        // checks that VC identity survives every physical hop and that the
        // endpoint credit return is VC-specific.
        $display("\n============================================================");
        $display("N-7 T6 VC INDEPENDENCE");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();

        clear_injection();
        inj_flit[0]  = make_flit(0,5,VC_REQUEST,FLIT_HEAD_TAIL,16'h6000);
        inj_valid[0] = 1'b1;
        expected[key_of(0,5,VC_REQUEST)]++;

        inj_flit[1]  = make_flit(1,5,VC_RESPONSE,FLIT_HEAD_TAIL,16'h6001);
        inj_valid[1] = 1'b1;
        expected[key_of(1,5,VC_RESPONSE)]++;

        inj_flit[2]  = make_flit(2,5,VC_ATTESTATION,FLIT_HEAD_TAIL,16'h6002);
        inj_valid[2] = 1'b1;
        expected[key_of(2,5,VC_ATTESTATION)]++;

        @(posedge clk);
        #1;
        clear_injection();
        wait_mesh_quiet();
        check_scoreboard("T6");

        // T7: reset while traffic is present. No pre-reset packet may survive.
        $display("\n============================================================");
        $display("N-7 T7 RESET DURING TRAFFIC");
        $display("============================================================");
        clear_scoreboard();
        reset_mesh();

        // Inject several simultaneous packets with multi-hop paths.
        clear_injection();
        inj_flit[0]  = make_flit(0,5,VC_REQUEST,FLIT_HEAD_TAIL,16'h7000);
        inj_valid[0] = 1'b1;
        inj_flit[1]  = make_flit(1,4,VC_RESPONSE,FLIT_HEAD_TAIL,16'h7001);
        inj_valid[1] = 1'b1;
        inj_flit[3]  = make_flit(3,2,VC_ATTESTATION,FLIT_HEAD_TAIL,16'h7002);
        inj_valid[3] = 1'b1;

        // Deliberately do not add these to expected: reset is supposed to
        // discard them before endpoint delivery.
        @(posedge clk);
        #1;
        clear_injection();

        // Assert reset on the following negedge and hold for two active edges.
        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        #1;
        rst = 1'b0;

        @(posedge clk);
        #1;

        check(mesh_outputs_idle(),
              "T7 reset clears all router output traffic");
        wait_mesh_quiet();
        check_scoreboard("T7 no pre-reset packet delivered");

        // Final protocol count. Any illegal VC seen on a valid link is a hard
        // failure even if the endpoint scoreboard happens to balance.
        check(protocol_errors == 0,
              $sformatf("no malformed protocol observations (count=%0d)",
                        protocol_errors));
        check(port_mismatch == 0,
              $sformatf("mesh tile_out port == router LOCAL output (mismatch=%0d)",
                        port_mismatch));

        $display("\n============================================================");
        $display("N-7 RIGOROUS 3x2 MESH RESULT");
        $display("Checks = %0d",checks);
        $display("Errors = %0d",errors);
        $display("ProtocolErrors = %0d",protocol_errors);
        $display("InjBlocked     = %0d",inj_blocked);
        if (errors == 0)
            $display("RESULT = PASS");
        else
            $display("RESULT = FAIL");
        $display("============================================================");

        $finish;
    end

endmodule

