`timescale 1ns/1ps
module tb_noc_router_m9_credit;

    import noc_pkg::*;

    localparam int NORTH=PORT_NORTH, SOUTH=PORT_SOUTH, EAST=PORT_EAST;
    localparam int WEST=PORT_WEST, LOCAL=PORT_LOCAL;
    localparam int DEPTH=VC0_DEPTH;

    logic clk, rst;
    coord_t current_coord;
    flit_t in_flit_north,in_flit_south,in_flit_east,in_flit_west,in_flit_local;
    logic in_valid_north,in_valid_south,in_valid_east,in_valid_west,in_valid_local;
    flit_t out_flit_north,out_flit_south,out_flit_east,out_flit_west,out_flit_local;
    logic out_valid_north,out_valid_south,out_valid_east,out_valid_west,out_valid_local;
    logic [NUM_VC-1:0] credit_return [NUM_PORTS];
    integer checks=0, errors=0;

    // 7c LOCAL ready/valid.
    logic in_ready_local;
    logic out_ready_local;
    flit_t pkt [0:5];
    flit_t got;
    logic  v_ready0, v_ready1;

    flit_t head, b1, b2, b3, tail, competitor;
    flit_t vc1_pkt, vc2_pkt;

    noc_router dut (
        .clk(clk), .rst(rst), .current_coord(current_coord),
        .in_flit_north(in_flit_north), .in_valid_north(in_valid_north),
        .in_flit_south(in_flit_south), .in_valid_south(in_valid_south),
        .in_flit_east(in_flit_east), .in_valid_east(in_valid_east),
        .in_flit_west(in_flit_west), .in_valid_west(in_valid_west),
        .in_flit_local(in_flit_local), .in_valid_local(in_valid_local),
        .in_ready_local(in_ready_local), .credit_out(),
        .credit_return(credit_return),
        .out_flit_north(out_flit_north), .out_valid_north(out_valid_north),
        .out_flit_south(out_flit_south), .out_valid_south(out_valid_south),
        .out_flit_east(out_flit_east), .out_valid_east(out_valid_east),
        .out_flit_west(out_flit_west), .out_valid_west(out_valid_west),
        .out_flit_local(out_flit_local), .out_valid_local(out_valid_local),
        .out_ready_local(out_ready_local)
    );

    always #5 clk=~clk;

    task automatic check(input logic c,input string m);
        checks++;
        if(c) $display("[PASS] %s",m);
        else begin errors++; $display("[FAIL] %s",m); end
    endtask

    task automatic clear_inputs;
        begin
            in_flit_north='0; in_flit_south='0; in_flit_east='0;
            in_flit_west='0; in_flit_local='0;
            in_valid_north=0; in_valid_south=0; in_valid_east=0;
            in_valid_west=0; in_valid_local=0;
        end
    endtask

    task automatic clear_credits;
        begin
            for(int p=0;p<NUM_PORTS;p++) credit_return[p]='0;
        end
    endtask

    function automatic flit_t make_flit(input int dx,input int dy,
                                         input flit_type_e ft,input int vc,
                                         input logic [15:0] tag);
        flit_t f;
        begin
            f='0;
            f.flit_data[31:29]=dx[2:0];
            f.flit_data[28:26]=dy[2:0];
            case (vc)
                VC_REQUEST:     f.flit_data[19:16] = MSG_MEM_RD_REQ;
                VC_RESPONSE:    f.flit_data[19:16] = MSG_MEM_RD_RESP;
                VC_ATTESTATION: f.flit_data[19:16] = MSG_ATTEST_CHALLENGE;
                default:        f.flit_data[19:16] = MSG_MEM_RD_REQ;
            endcase
            f.flit_data[15:11]=5'd1;
            f.flit_data[10:0]=tag[10:0];
            f.flit_type=ft;
            f.vc_id=vc[VC_ID_WIDTH-1:0];
            return f;
        end
    endfunction

    task automatic reset_dut;
        begin
            clear_inputs(); clear_credits(); rst=1;
            repeat(2) @(posedge clk); #1;
            check(!(out_valid_north||out_valid_south||out_valid_east||
                    out_valid_west||out_valid_local),"reset produces no output");
            rst=0; @(posedge clk); #1;
        end
    endtask

    task automatic enqueue_one(input int p,input flit_t f);
        begin
            // Put the flit into the selected input FIFO. The FIFO write
            // occurs on this active edge; the flit is therefore not yet a
            // transferred output on this same edge.
            @(negedge clk);
            clear_inputs();
            case(p)
                NORTH: begin in_flit_north=f; in_valid_north=1; end
                SOUTH: begin in_flit_south=f; in_valid_south=1; end
                EAST : begin in_flit_east=f;  in_valid_east=1;  end
                WEST : begin in_flit_west=f;  in_valid_west=1;  end
                LOCAL: begin in_flit_local=f; in_valid_local=1; end
                default: $fatal(1,"bad input port");
            endcase
            @(posedge clk); #1;
            clear_inputs();
        end
    endtask

    task automatic consume_east_expected(input flit_t f, input string m);
        logic v;
        flit_t observed;
        begin
            // M9 output valid/data are combinational from the FIFO head and
            // the qualified grant. The actual transfer/dequeue happens at
            // the following active edge. Sample before that edge.
            @(negedge clk); #1;
            v = out_valid_east;
            observed = out_flit_east;
            check(v && observed===f, m);
            @(posedge clk); #1;
        end
    endtask

    task automatic return_one_credit(input int p, input int v);
        begin
            // Present the return before the sampling edge.  The credit
            // counter updates on this posedge; the newly-qualified output
            // therefore exists during the cycle immediately AFTER this
            // posedge and must be consumed on the NEXT posedge.
            @(negedge clk);
            clear_inputs();
            credit_return[p][v] = 1'b1;
            @(posedge clk); #1;
            // Keep the return asserted until the following negedge so the
            // transfer-check task can observe the qualified output without
            // creating a second sampling edge.
        end
    endtask

    task automatic finish_credit_return;
        begin
            @(negedge clk);
            clear_credits();
        end
    endtask

    function automatic logic no_output;
        return !(out_valid_north||out_valid_south||out_valid_east||
                 out_valid_west||out_valid_local);
    endfunction

    initial begin
        clk=0; rst=0; current_coord.x=1; current_coord.y=0;
        out_ready_local=1'b1;
        clear_inputs(); clear_credits();

        // T1: initial credit depth.
        reset_dut();
        check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==DEPTH,
              "T1 credit initializes to downstream FIFO depth");

        // T2: enqueue and then actually transfer exactly DEPTH flits.
        // The previous TB checked out_valid one clock too late: seeing a
        // flit after the dequeue edge is not proof that that flit transferred
        // on that edge. Separate enqueue from transfer observation.
        for(int k=0;k<DEPTH;k++) begin
            flit_t f;
            f=make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h2000+k);
            enqueue_one(LOCAL,f);
            consume_east_expected(f,
                $sformatf("T2 transfer %0d while credit available",k));
        end
        check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==0,
              "T2 credit reaches zero after four actual transfers");

        // T3: zero credit blocks a queued flit.
        begin
            flit_t f;
            f=make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h20FF);
            enqueue_one(LOCAL,f);
            @(negedge clk); #1;
            check(no_output(),"T3 zero credit blocks output");
            check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==0,
                  "T3 credit remains zero");
        end

        // T4: return one credit; queued flit becomes transferable; consume it.
        return_one_credit(EAST, VC_REQUEST);
        check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==1,
              "T4 credit return restores one slot");
        // T3's blocked flit is already queued and is the one that should
        // consume the returned credit.
        begin
            flit_t blocked;
            blocked=make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h20FF);
            // Credit was sampled on the preceding posedge.  The queued flit
            // is now visible during this cycle and transfers on the next
            // posedge.
            check(out_valid_east && out_flit_east===blocked,
                  "T4 returned credit permits queued transfer");

            // The return credit has already been applied.  Deassert it BEFORE
            // the transfer edge; otherwise the same edge can apply another
            // credit return while consuming the queued flit, leaving the
            // counter at 1 instead of 0.
            @(negedge clk);
            clear_credits();

            // The queued flit remains qualified and transfers on this edge.
            @(posedge clk); #1;
            check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==0,
                  "T4 queued transfer consumes returned credit");
        end

        // T5: reservation survives a zero-credit mid-packet stall.
        reset_dut();
        head=make_flit(2,0,FLIT_HEAD,VC_REQUEST,16'h2200);
        b1=make_flit(2,0,FLIT_BODY,VC_REQUEST,16'h2201);
        b2=make_flit(2,0,FLIT_BODY,VC_REQUEST,16'h2202);
        b3=make_flit(2,0,FLIT_BODY,VC_REQUEST,16'h2203);
        tail=make_flit(2,0,FLIT_TAIL,VC_REQUEST,16'h2204);
        competitor=make_flit(2,0,FLIT_HEAD_TAIL,VC_RESPONSE,16'h22FF);

        enqueue_one(LOCAL,head); consume_east_expected(head,"T5 HEAD transfers");
        enqueue_one(LOCAL,b1);   consume_east_expected(b1,"T5 BODY1 transfers");
        enqueue_one(LOCAL,b2);   consume_east_expected(b2,"T5 BODY2 transfers");
        enqueue_one(LOCAL,b3);   consume_east_expected(b3,"T5 BODY3 consumes final credit");

        check(dut.u_allocator.output_locked[EAST]==1,
              "T5 EAST reservation remains held at zero credit");
        check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==0,
              "T5 credit is zero before TAIL");

        enqueue_one(LOCAL,tail);
        @(negedge clk); #1;
        check(no_output(),"T5 TAIL stalls at zero credit");
        check(dut.u_allocator.output_locked[EAST]==1,
              "T5 reservation remains held during TAIL stall");

        enqueue_one(NORTH,competitor);
        @(negedge clk); #1;
        check(no_output(),"T5 competitor cannot steal reserved EAST");

        return_one_credit(EAST, VC_REQUEST);
        check(dut.u_credit_control.credit_count[EAST][VC_REQUEST]==1,
              "T5 credit return restores slot");

        // The return was sampled on the preceding posedge.  The stalled TAIL
        // must now be visible in the same post-return cycle and transfer on
        // the next posedge.
        check(out_valid_east && out_flit_east===tail,
              "T5 stalled TAIL resumes after credit return");
        @(posedge clk); #1;
        check(dut.u_allocator.output_locked[EAST]==0,
              "T5 TAIL releases EAST reservation after transfer");
        finish_credit_return();

        // T6: independent VC credit accounting.
        reset_dut();
        vc1_pkt = make_flit(2,0,FLIT_HEAD_TAIL,VC_RESPONSE,16'h2301);
        vc2_pkt = make_flit(2,0,FLIT_HEAD_TAIL,VC_ATTESTATION,16'h2302);

        enqueue_one(LOCAL,vc1_pkt);
        consume_east_expected(vc1_pkt,"T6 VC1 transfers with independent credit");
        check(dut.u_credit_control.credit_count[EAST][VC_RESPONSE]==VC1_DEPTH-1,
              "T6 VC1 credit decrements independently");

        enqueue_one(LOCAL,vc2_pkt);
        consume_east_expected(vc2_pkt,"T6 VC2 transfers with independent credit");
        check(dut.u_credit_control.credit_count[EAST][VC_ATTESTATION]==VC2_DEPTH-1,
              "T6 VC2 credit decrements independently");

        //=====================================================================
        // 7c LOCAL READY/VALID TESTS
        // Router is at (1,0). Flits with dest (1,0) entering on WEST eject
        // on LOCAL. The NI side is modelled by out_ready_local.
        //=====================================================================

        // T7: LOCAL eject under NI backpressure, 6-flit packet, ready low.
        reset_dut();
        out_ready_local = 1'b0;
        pkt[0]=make_flit(1,0,FLIT_HEAD,VC_REQUEST,16'h2700);
        pkt[1]=make_flit(1,0,FLIT_BODY,VC_REQUEST,16'h2701);
        pkt[2]=make_flit(1,0,FLIT_BODY,VC_REQUEST,16'h2702);
        pkt[3]=make_flit(1,0,FLIT_BODY,VC_REQUEST,16'h2703);
        pkt[4]=make_flit(1,0,FLIT_BODY,VC_REQUEST,16'h2704);
        pkt[5]=make_flit(1,0,FLIT_TAIL,VC_REQUEST,16'h2705);
        for (int k=0;k<6;k++) enqueue_one(WEST,pkt[k]);
        repeat(6) @(posedge clk); #1;

        check(out_valid_local && out_flit_local===pkt[0],
              "T7 HEAD presented on LOCAL while NI not ready");
        check(dut.u_credit_control.credit_count[LOCAL][VC_REQUEST]==0,
              "T7 LOCAL VC0 credit exhausted by eject buffer (4 flits)");
        check(dut.u_eject_fifo.count==VC0_DEPTH,
              "T7 eject buffer holds exactly VC0_DEPTH flits");
        check(dut.empty_west_vc0==1'b0,
              "T7 remaining flits wait in WEST input FIFO, not lost");

        // Valid and flit must hold while ready is low.
        begin
            flit_t f0; logic hold_ok;
            f0 = out_flit_local; hold_ok = 1'b1;
            for (int c=0;c<5;c++) begin
                @(negedge clk);
                if (!(out_valid_local && out_flit_local===f0)) hold_ok = 1'b0;
            end
            check(hold_ok, "T7 LOCAL valid+flit stable for 5 stalled cycles");
        end

        // T9 (placed here while the eject buffer is non-empty): out_valid
        // must not depend combinationally on out_ready (no comb loop with NI).
        @(negedge clk);
        out_ready_local = 1'b0; #1; v_ready0 = out_valid_local;
        out_ready_local = 1'b1; #1; v_ready1 = out_valid_local;
        out_ready_local = 1'b0;
        check(v_ready0 && v_ready1,
              "T9 out_valid_local independent of out_ready_local");

        // Release: all 6 flits must arrive in order, once each.
        begin
            int n; int guard; logic order_ok;
            n = 0; guard = 0; order_ok = 1'b1;
            // Sample at each negedge; the flit seen there is accepted at the
            // following posedge (ready is high), so each negedge shows the
            // next flit exactly once.
            @(negedge clk); out_ready_local = 1'b1;
            while (n < 6 && guard < 40) begin
                #1; guard++;
                if (out_valid_local) begin
                    if (out_flit_local !== pkt[n]) order_ok = 1'b0;
                    n++;
                end
                @(negedge clk);
            end
            repeat(4) @(posedge clk); #1;
            check(n==6, "T7 all 6 flits delivered after release");
            check(order_ok, "T7 flits delivered in order, no corruption");
            check(!out_valid_local, "T7 no duplicate/extra LOCAL flit");
            check(dut.u_credit_control.credit_count[LOCAL][VC_REQUEST]==VC0_DEPTH,
                  "T7 LOCAL VC0 credit fully restored");
            check(dut.u_allocator.output_locked[LOCAL]==0,
                  "T7 LOCAL reservation released by TAIL");
        end

        // T8: LOCAL input backpressure (in_ready_local).
        reset_dut();
        out_ready_local = 1'b1;
        // 4 flits consume EAST credit, 4 more fill the LOCAL VC0 FIFO.
        for (int k=0;k<2*DEPTH;k++)
            enqueue_one(LOCAL, make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h2800+k));
        repeat(3) @(posedge clk);
        @(negedge clk);
        in_flit_local = make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h28FF);
        in_valid_local = 1'b0; #1;
        check(dut.full_local_vc0==1'b1, "T8 LOCAL VC0 input FIFO full");
        check(in_ready_local==1'b0, "T8 in_ready_local low for full VC0");
        in_flit_local = make_flit(2,0,FLIT_HEAD_TAIL,VC_RESPONSE,16'h28FE); #1;
        check(in_ready_local==1'b1, "T8 in_ready_local high for non-full VC1");
        // Present VC0 with valid while not ready: must NOT be written.
        in_flit_local = make_flit(2,0,FLIT_HEAD_TAIL,VC_REQUEST,16'h28FF);
        in_valid_local = 1'b1;
        @(posedge clk); #1;
        clear_inputs();
        check(dut.u_datapath.local_vc0_fifo.count==DEPTH,
              "T8 flit presented while not ready was not written");

        $display("\n==============================================");
        $display(" M9 CREDIT INTEGRATION TEST COMPLETE");
        $display(" Checks = %0d",checks);
        $display(" Errors = %0d",errors);
        $display("==============================================");
        if(errors==0) $display("RESULT = PASS");
        else $display("RESULT = FAIL");
        $finish;
    end
endmodule






