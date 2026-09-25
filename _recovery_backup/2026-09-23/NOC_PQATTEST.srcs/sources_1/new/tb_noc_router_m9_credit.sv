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

    flit_t head, b1, b2, b3, tail, competitor;
    flit_t vc1_pkt, vc2_pkt;

    noc_router dut (
        .clk(clk), .rst(rst), .current_coord(current_coord),
        .in_flit_north(in_flit_north), .in_valid_north(in_valid_north),
        .in_flit_south(in_flit_south), .in_valid_south(in_valid_south),
        .in_flit_east(in_flit_east), .in_valid_east(in_valid_east),
        .in_flit_west(in_flit_west), .in_valid_west(in_valid_west),
        .in_flit_local(in_flit_local), .in_valid_local(in_valid_local),
        .credit_return(credit_return),
        .out_flit_north(out_flit_north), .out_valid_north(out_valid_north),
        .out_flit_south(out_flit_south), .out_valid_south(out_valid_south),
        .out_flit_east(out_flit_east), .out_valid_east(out_valid_east),
        .out_flit_west(out_flit_west), .out_valid_west(out_valid_west),
        .out_flit_local(out_flit_local), .out_valid_local(out_valid_local)
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






