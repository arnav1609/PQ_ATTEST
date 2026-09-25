//=============================================================================
// File        : ni_tb.sv
// Module      : tb_noc_ni
// Project     : PQ-Attest NoC   (M10 network interface)
//
// Coverage
//   T01  reset / idle
//   T02  single-flit TX             (FLIT_HEAD_TAIL, zero-payload message)
//   T03  multi-flit TX              (HEAD + BODY + TAIL, field-exact header)
//   T04  TX back-pressure           (valid and flit stable while stalled)
//   T05  illegal destination        (refused, nothing injected)
//   T06  message class -> VC        (all eight message types)
//   T07  single-flit RX metadata    (combinational bypass, no stale registers)
//   T08  multi-flit RX              (payload ordering and last-flit marking)
//   T09  RX back-pressure
//   T10  back-to-back RX            (second packet must not show stale fields)
//   T11  stray BODY in idle         (dropped, consumed, flagged)
//   T12  misrouted packet           (dropped, consumed, flagged)
//   T13  lying length field         (delivered but flagged)
//   T14  malformed packet shape     (HEAD_TAIL that should have had a payload,
//                                    and HEAD that could have had none)
//   SVA  protocol invariants
//
//-----------------------------------------------------------------------------
// THE ONE RULE THIS TESTBENCH LIVES OR DIES BY
//
//   Drive at the negedge. Wait TSETTLE. Sample. Release after the posedge
//   that consumes the transfer.
//
//   Skipping the settle is what produced the "T03 payload0 : flit_type"
//   failure and the watchdog hang. A blocking assignment followed by an
//   immediate read of a DUT output is evaluated BEFORE the DUT's always_comb
//   re-runs, so the read returns the previous value, the testbench concludes
//   the transfer has not happened, waits a cycle, and by then the transfer is
//   a flit in the past. Do not remove #TSETTLE.
//=============================================================================

`timescale 1ns/1ps

module tb_noc_ni;

    import noc_pkg::*;

    //=========================================================================
    // DUT configuration
    //=========================================================================

    localparam int     DUT_TILE_ID = int'(TILE_CPU0);
    localparam coord_t DUT_COORD   = tile_to_coord(TILE_CPU0);

    //=========================================================================
    // Clock, reset, settle delay
    //=========================================================================

    logic clk = 1'b0;
    logic rst;

    always #5 clk = ~clk;

    // Half period is 5 ns, so a 1 ns settle never crosses an edge.
    localparam time TSETTLE = 1ns;

    //=========================================================================
    // DUT signals
    //=========================================================================

    logic                        tx_valid;
    logic                        tx_ready;

    coord_t                      tx_dest_coord;
    msg_type_e                   tx_msg_type;
    logic [10:0]                 tx_control;

    logic [FLIT_WIDTH-1:0]       tx_payload_data;
    logic                        tx_payload_valid;
    logic                        tx_payload_ready;

    logic [MAC_TAG_BITS-1:0]     tx_mac_tag;
    logic                        tx_error;

    flit_t                       noc_tx_flit;
    logic                        noc_tx_valid;
    logic                        noc_tx_ready;

    flit_t                       noc_rx_flit;
    logic                        noc_rx_valid;
    logic                        noc_rx_ready;

    coord_t                      rx_src_coord;
    coord_t                      rx_dest_coord;
    msg_type_e                   rx_msg_type;
    logic [10:0]                 rx_control;
    logic [4:0]                  rx_length;
    logic                        rx_head_valid;

    logic [FLIT_WIDTH-1:0]       rx_payload_data;
    logic                        rx_payload_valid;
    logic                        rx_payload_last;
    logic                        rx_ready;

    logic [MAC_TAG_BITS-1:0]     rx_mac_tag;
    logic                        rx_mac_valid;

    logic                        rx_protocol_error;
    logic                        rx_length_error;

    logic                        tx_busy;
    logic                        rx_busy;

    //=========================================================================
    // DUT
    //=========================================================================

    noc_network_interface #(
        .LOCAL_TILE_ID(DUT_TILE_ID)
    ) dut (
        .clk               (clk),
        .rst               (rst),

        .tx_valid          (tx_valid),
        .tx_ready          (tx_ready),
        .tx_dest_coord     (tx_dest_coord),
        .tx_msg_type       (tx_msg_type),
        .tx_control        (tx_control),

        .tx_payload_data   (tx_payload_data),
        .tx_payload_valid  (tx_payload_valid),
        .tx_payload_ready  (tx_payload_ready),

        .tx_mac_tag        (tx_mac_tag),
        .tx_error          (tx_error),

        .noc_tx_flit       (noc_tx_flit),
        .noc_tx_valid      (noc_tx_valid),
        .noc_tx_ready      (noc_tx_ready),

        .noc_rx_flit       (noc_rx_flit),
        .noc_rx_valid      (noc_rx_valid),
        .noc_rx_ready      (noc_rx_ready),

        .rx_src_coord      (rx_src_coord),
        .rx_dest_coord     (rx_dest_coord),
        .rx_msg_type       (rx_msg_type),
        .rx_control        (rx_control),
        .rx_length         (rx_length),
        .rx_head_valid     (rx_head_valid),

        .rx_payload_data   (rx_payload_data),
        .rx_payload_valid  (rx_payload_valid),
        .rx_payload_last   (rx_payload_last),
        .rx_ready          (rx_ready),

        .rx_mac_tag        (rx_mac_tag),
        .rx_mac_valid      (rx_mac_valid),

        .rx_protocol_error (rx_protocol_error),
        .rx_length_error   (rx_length_error),

        .tx_busy           (tx_busy),
        .rx_busy           (rx_busy)
    );

    //=========================================================================
    // Scoreboard
    //=========================================================================

    integer errors = 0;
    integer checks = 0;

    task automatic chk(input logic cond, input string name);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $error("[FAIL] %s   (t=%0t)", name, $time);
            end
            else begin
                $display("[PASS] %s", name);
            end
        end
    endtask

    task automatic banner(input string name);
        begin
            $display("");
            $display("---- %s", name);
        end
    endtask

    //=========================================================================
    // Message name table
    //
    // Replaces the enum .name() method, which Vivado's editor flags.
    //=========================================================================

    function automatic string msg_name(input msg_type_e m);
        begin
            case (m)
                MSG_MEM_RD_REQ:       msg_name = "MSG_MEM_RD_REQ";
                MSG_MEM_RD_RESP:      msg_name = "MSG_MEM_RD_RESP";
                MSG_MEM_WR_REQ:       msg_name = "MSG_MEM_WR_REQ";
                MSG_MEM_WR_RESP:      msg_name = "MSG_MEM_WR_RESP";
                MSG_ATTEST_CHALLENGE: msg_name = "MSG_ATTEST_CHALLENGE";
                MSG_ATTEST_RESPONSE:  msg_name = "MSG_ATTEST_RESPONSE";
                MSG_ATTEST_GRANT:     msg_name = "MSG_ATTEST_GRANT";
                MSG_ATTEST_REVOKE:    msg_name = "MSG_ATTEST_REVOKE";
                default:              msg_name = "UNKNOWN_MSG";
            endcase
        end
    endfunction

    //=========================================================================
    // Head flit construction
    //=========================================================================

    function automatic logic [FLIT_WIDTH-1:0] mk_head(
        input coord_t      dest,
        input coord_t      src,
        input msg_type_e   msg,
        input logic [4:0]  len,
        input logic [10:0] ctrl
    );
        head_flit_t h;
        begin
            h             = '0;
            h.dest_x      = dest.x;
            h.dest_y      = dest.y;
            h.src_x       = src.x;
            h.src_y       = src.y;
            h.msg_type    = msg;
            h.length      = len;
            h.control.raw = ctrl;
            mk_head       = h;
        end
    endfunction

    //=========================================================================
    // Reset
    //=========================================================================

    task automatic reset_dut;
        begin
            rst              = 1'b1;

            tx_valid         = 1'b0;
            tx_dest_coord    = '0;
            tx_msg_type      = MSG_MEM_RD_REQ;
            tx_control       = '0;

            tx_payload_data  = '0;
            tx_payload_valid = 1'b0;

            tx_mac_tag       = '0;

            noc_tx_ready     = 1'b1;

            noc_rx_flit      = '0;
            noc_rx_valid     = 1'b0;

            rx_ready         = 1'b1;

            repeat (3) @(posedge clk);
            #TSETTLE;

            rst = 1'b0;

            @(posedge clk);
            #TSETTLE;
        end
    endtask

    //=========================================================================
    // TX helpers
    //
    // Each helper returns just after a posedge, with the transfer it describes
    // already consumed. Checks inside a helper run while the transfer is still
    // asserted.
    //=========================================================================

    task automatic tx_request(
        input coord_t      dest,
        input msg_type_e   msg,
        input logic [10:0] ctrl
    );
        begin
            @(negedge clk);

            tx_dest_coord = dest;
            tx_msg_type   = msg;
            tx_control    = ctrl;
            tx_valid      = 1'b1;
            #TSETTLE;

            while (!tx_ready) begin
                @(negedge clk);
                #TSETTLE;
            end

            @(posedge clk);
            #TSETTLE;

            tx_valid = 1'b0;
        end
    endtask

    task automatic expect_head(
        input flit_type_e  exp_type,
        input coord_t      exp_dest,
        input msg_type_e   exp_msg,
        input logic [10:0] exp_ctrl,
        input string       name
    );
        head_flit_t h;
        begin
            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            h = head_flit_t'(noc_tx_flit.flit_data);

            chk(noc_tx_flit.flit_type === exp_type,
                $sformatf("%s : head flit_type", name));
            chk(noc_tx_flit.vc_id === message_to_vc(exp_msg),
                $sformatf("%s : head vc_id", name));
            chk(h.dest_x === exp_dest.x,
                $sformatf("%s : dest_x", name));
            chk(h.dest_y === exp_dest.y,
                $sformatf("%s : dest_y", name));
            // D.10 : the source is the DUT's own coordinate, never the tile's.
            chk(h.src_x === DUT_COORD.x,
                $sformatf("%s : src_x hardwired", name));
            chk(h.src_y === DUT_COORD.y,
                $sformatf("%s : src_y hardwired", name));
            chk(h.msg_type === exp_msg,
                $sformatf("%s : msg_type", name));
            chk(h.length === message_length(exp_msg),
                $sformatf("%s : length", name));
            chk(h.control.raw === exp_ctrl,
                $sformatf("%s : control", name));

            @(posedge clk);
            #TSETTLE;
        end
    endtask

    task automatic tx_payload_flit(
        input logic [FLIT_WIDTH-1:0] data,
        input flit_type_e            exp_type,
        input vc_e                   exp_vc,
        input string                 name
    );
        begin
            @(negedge clk);

            tx_payload_data  = data;
            tx_payload_valid = 1'b1;
            #TSETTLE;

            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            chk(noc_tx_flit.flit_type === exp_type,
                $sformatf("%s : flit_type", name));
            chk(noc_tx_flit.vc_id === exp_vc,
                $sformatf("%s : vc_id", name));
            chk(noc_tx_flit.flit_data === data,
                $sformatf("%s : flit_data", name));

            @(posedge clk);
            #TSETTLE;

            tx_payload_valid = 1'b0;
        end
    endtask

    // Push one payload flit without checking it. Used where the point of the
    // test is something else and the FSM just has to be returned to idle.
    task automatic tx_drain_flit(input logic [FLIT_WIDTH-1:0] data);
        begin
            @(negedge clk);

            tx_payload_data  = data;
            tx_payload_valid = 1'b1;
            #TSETTLE;

            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            @(posedge clk);
            #TSETTLE;

            tx_payload_valid = 1'b0;
        end
    endtask

    //=========================================================================
    // RX helpers
    //
    // rx_begin presents a flit and returns while it is STILL asserted and
    // about to be accepted, so the caller can check the combinational outputs.
    // rx_end releases it after the posedge that consumes it. Exactly one
    // posedge occurs between the two, so a flit is never consumed twice.
    //=========================================================================

    task automatic rx_begin(
        input flit_type_e            ftype,
        input vc_e                   vc,
        input logic [FLIT_WIDTH-1:0] data
    );
        begin
            @(negedge clk);

            noc_rx_flit.flit_data = data;
            noc_rx_flit.flit_type = ftype;
            noc_rx_flit.vc_id     = vc;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            while (!noc_rx_ready) begin
                @(negedge clk);
                #TSETTLE;
            end
        end
    endtask

    task automatic rx_end;
        begin
            @(posedge clk);
            #TSETTLE;
            noc_rx_valid = 1'b0;
        end
    endtask

    //=========================================================================
    // T01 : reset and idle
    //=========================================================================

    task automatic t01_reset;
        begin
            banner("T01 reset / idle");

            reset_dut;

            chk(tx_ready          === 1'b1, "T01 tx_ready after reset");
            chk(noc_tx_valid      === 1'b0, "T01 no egress after reset");
            chk(rx_head_valid     === 1'b0, "T01 no rx_head_valid after reset");
            chk(rx_protocol_error === 1'b0, "T01 no protocol error after reset");
            chk(tx_busy           === 1'b0, "T01 tx idle after reset");
            chk(rx_busy           === 1'b0, "T01 rx idle after reset");
        end
    endtask

    //=========================================================================
    // T02 : single-flit TX
    //
    // MSG_MEM_WR_RESP has zero payload flits and MAC_ENABLE is 0, so the whole
    // packet is one FLIT_HEAD_TAIL.
    //=========================================================================

    task automatic t02_single_tx;
        begin
            banner("T02 single-flit TX (FLIT_HEAD_TAIL)");

            tx_request(tile_to_coord(TILE_MEMORY), MSG_MEM_WR_RESP, 11'h005);

            expect_head(FLIT_HEAD_TAIL,
                        tile_to_coord(TILE_MEMORY),
                        MSG_MEM_WR_RESP,
                        11'h005,
                        "T02");

            chk(tx_busy === 1'b0, "T02 returns to idle");
        end
    endtask

    //=========================================================================
    // T03 : multi-flit TX
    //
    // MSG_MEM_WR_REQ carries 2 payload flits: address then data.
    //=========================================================================

    task automatic t03_multiflit_tx;
        begin
            banner("T03 multi-flit TX (HEAD + BODY + TAIL)");

            tx_request(tile_to_coord(TILE_MEMORY), MSG_MEM_WR_REQ, 11'h00F);

            expect_head(FLIT_HEAD,
                        tile_to_coord(TILE_MEMORY),
                        MSG_MEM_WR_REQ,
                        11'h00F,
                        "T03 head");

            tx_payload_flit(32'h2000_1234, FLIT_BODY, VC_REQUEST, "T03 payload0");
            tx_payload_flit(32'hDEAD_BEEF, FLIT_TAIL, VC_REQUEST, "T03 payload1");

            chk(tx_busy === 1'b0, "T03 returns to idle");
        end
    endtask

    //=========================================================================
    // T04 : TX back-pressure
    //
    // The packet is COMPLETED at the end. Leaving the FSM mid-packet would
    // hang the next test, because tx_ready is low until the packet finishes.
    //=========================================================================

    task automatic t04_tx_backpressure;
        flit_t held;
        begin
            banner("T04 TX back-pressure");

            noc_tx_ready = 1'b0;

            tx_request(tile_to_coord(TILE_CPU1), MSG_MEM_RD_REQ, 11'h000);

            while (!noc_tx_valid) begin
                @(negedge clk);
                #TSETTLE;
            end

            held = noc_tx_flit;

            repeat (5) begin
                @(negedge clk);
                #TSETTLE;
                chk(noc_tx_valid === 1'b1, "T04 valid held while stalled");
                chk(noc_tx_flit  === held, "T04 flit held while stalled");
            end

            noc_tx_ready = 1'b1;
            #TSETTLE;

            // Release the head.
            while (!(noc_tx_valid && noc_tx_ready)) begin
                @(negedge clk);
                #TSETTLE;
            end

            @(posedge clk);
            #TSETTLE;

            // MSG_MEM_RD_REQ has exactly one payload flit; drain it.
            tx_payload_flit(32'h2000_0000, FLIT_TAIL, VC_REQUEST, "T04 payload");

            chk(tx_busy === 1'b0, "T04 returns to idle");
        end
    endtask

    //=========================================================================
    // T05 : illegal destination coordinate
    //
    // x = 3 is outside a 3-wide mesh. Nothing may be injected.
    //=========================================================================

    task automatic t05_bad_dest;
        coord_t bad;
        begin
            banner("T05 illegal destination refused");

            bad.x = 3'd3;
            bad.y = 3'd0;

            @(negedge clk);

            tx_dest_coord = bad;
            tx_msg_type   = MSG_MEM_RD_REQ;
            tx_control    = 11'h000;
            tx_valid      = 1'b1;
            #TSETTLE;

            chk(tx_error     === 1'b1, "T05 tx_error asserted");
            chk(noc_tx_valid === 1'b0, "T05 nothing injected");

            @(posedge clk);
            #TSETTLE;

            tx_valid = 1'b0;

            @(negedge clk);
            #TSETTLE;

            chk(tx_busy      === 1'b0, "T05 stays idle");
            chk(noc_tx_valid === 1'b0, "T05 still nothing injected");
        end
    endtask

    //=========================================================================
    // T06 : message class -> virtual channel
    //
    // The VC assignment is the deadlock argument, so every message type is
    // checked against noc_pkg::message_to_vc rather than a hand-written table.
    //=========================================================================

    task automatic t06_vc_mapping;
        msg_type_e   m;
        int unsigned n;
        begin
            banner("T06 message class -> VC");

            for (int i = 0; i < 8; i++) begin

                m = msg_type_e'(i);
                n = int'(message_payload_flits(m));

                tx_request(tile_to_coord(TILE_ROT), m, 11'h000);

                while (!(noc_tx_valid && noc_tx_ready)) begin
                    @(negedge clk);
                    #TSETTLE;
                end

                chk(noc_tx_flit.vc_id === message_to_vc(m),
                    $sformatf("T06 %s -> VC", msg_name(m)));

                // A zero-payload message must be a single flit, anything else
                // must be a head. This is the TX half of the shape invariant
                // that T14 checks on the RX side.
                chk(noc_tx_flit.flit_type ===
                        ((n == 0) ? FLIT_HEAD_TAIL : FLIT_HEAD),
                    $sformatf("T06 %s flit shape", msg_name(m)));

                @(posedge clk);
                #TSETTLE;

                for (int j = 0; j < n; j++)
                    tx_drain_flit(32'hA000_0000 + j);

                chk(tx_busy === 1'b0,
                    $sformatf("T06 %s returns to idle", msg_name(m)));
            end
        end
    endtask

    //=========================================================================
    // T07 : single-flit RX metadata
    //
    // Checked WHILE the flit is asserted, which is the whole point: the
    // metadata must come from the incoming flit, not from registers still
    // holding the previous packet.
    //=========================================================================

    task automatic t07_single_rx;
        begin
            banner("T07 single-flit RX metadata");

            rx_ready = 1'b1;

            rx_begin(FLIT_HEAD_TAIL, VC_RESPONSE,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_MEMORY),
                             MSG_MEM_WR_RESP,
                             message_length(MSG_MEM_WR_RESP),
                             11'h001));

            chk(rx_head_valid     === 1'b1,            "T07 rx_head_valid");
            chk(rx_src_coord      === tile_to_coord(TILE_MEMORY),
                                                       "T07 source coordinate");
            chk(rx_dest_coord     === DUT_COORD,       "T07 destination coordinate");
            chk(rx_msg_type       === MSG_MEM_WR_RESP, "T07 message type");
            chk(rx_control        === 11'h001,         "T07 control");
            chk(rx_payload_last   === 1'b1,            "T07 last on single flit");
            chk(rx_protocol_error === 1'b0,            "T07 no protocol error");
            chk(rx_length_error   === 1'b0,            "T07 no length error");

            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T07 stays idle");
        end
    endtask

    //=========================================================================
    // T08 : multi-flit RX
    //=========================================================================

    task automatic t08_multiflit_rx;
        begin
            banner("T08 multi-flit RX");

            rx_ready = 1'b1;

            rx_begin(FLIT_HEAD, VC_REQUEST,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_CPU1),
                             MSG_MEM_WR_REQ,
                             message_length(MSG_MEM_WR_REQ),
                             11'h00F));

            chk(rx_head_valid   === 1'b1,           "T08 head valid");
            chk(rx_msg_type     === MSG_MEM_WR_REQ, "T08 head message type");
            chk(rx_length_error === 1'b0,           "T08 length consistent");
            rx_end;

            rx_begin(FLIT_BODY, VC_REQUEST, 32'h1111_2222);
            chk(rx_payload_valid === 1'b1,          "T08 payload0 valid");
            chk(rx_payload_data  === 32'h1111_2222, "T08 payload0 data");
            chk(rx_payload_last  === 1'b0,          "T08 payload0 not last");
            rx_end;

            rx_begin(FLIT_TAIL, VC_REQUEST, 32'h3333_4444);
            chk(rx_payload_valid === 1'b1,          "T08 payload1 valid");
            chk(rx_payload_data  === 32'h3333_4444, "T08 payload1 data");
            chk(rx_payload_last  === 1'b1,          "T08 payload1 is last");
            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T08 returns to idle");
        end
    endtask

    //=========================================================================
    // T09 : RX back-pressure
    //=========================================================================

    task automatic t09_rx_backpressure;
        begin
            banner("T09 RX back-pressure");

            rx_ready = 1'b1;

            rx_begin(FLIT_HEAD, VC_REQUEST,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_CPU1),
                             MSG_MEM_WR_REQ,
                             message_length(MSG_MEM_WR_REQ),
                             11'h000));
            rx_end;

            // Stall the tile and present a payload flit.
            rx_ready = 1'b0;

            @(negedge clk);

            noc_rx_flit.flit_data = 32'hABCD_EF01;
            noc_rx_flit.flit_type = FLIT_BODY;
            noc_rx_flit.vc_id     = VC_REQUEST;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            repeat (4) begin
                @(negedge clk);
                #TSETTLE;
                chk(noc_rx_ready === 1'b0, "T09 ready low while tile stalled");
            end

            // Release the stall and check in the SAME cycle. Waiting a full
            // cycle here would let the posedge accept the flit once and then
            // rx_end accept it a second time, ending the packet a flit early.
            rx_ready = 1'b1;
            #TSETTLE;

            chk(noc_rx_ready     === 1'b1,          "T09 ready follows tile");
            chk(rx_payload_valid === 1'b1,          "T09 payload delivered");
            chk(rx_payload_data  === 32'hABCD_EF01, "T09 payload data");
            chk(rx_payload_last  === 1'b0,          "T09 payload0 not last");

            rx_end;

            // Finish the packet.
            rx_begin(FLIT_TAIL, VC_REQUEST, 32'h0000_0001);
            chk(rx_payload_last === 1'b1, "T09 tail is last");
            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T09 returns to idle");
        end
    endtask

    //=========================================================================
    // T10 : back-to-back single-flit RX
    //
    // The second packet must show its own metadata, not the first's. Both are
    // zero-payload message types, so FLIT_HEAD_TAIL is the legal shape for
    // each - see T14 for what happens when it is not.
    //=========================================================================

    task automatic t10_back_to_back_rx;
        begin
            banner("T10 back-to-back RX, no stale metadata");

            rx_ready = 1'b1;

            rx_begin(FLIT_HEAD_TAIL, VC_RESPONSE,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_CPU1),
                             MSG_MEM_WR_RESP,
                             message_length(MSG_MEM_WR_RESP),
                             11'h111));

            chk(rx_src_coord === tile_to_coord(TILE_CPU1), "T10 first source");
            chk(rx_msg_type  === MSG_MEM_WR_RESP,          "T10 first message");
            chk(rx_control   === 11'h111,                  "T10 first control");
            rx_end;

            rx_begin(FLIT_HEAD_TAIL, VC_ATTESTATION,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_ROT),
                             MSG_ATTEST_GRANT,
                             message_length(MSG_ATTEST_GRANT),
                             11'h222));

            chk(rx_src_coord === tile_to_coord(TILE_ROT),
                "T10 second source not stale");
            chk(rx_msg_type  === MSG_ATTEST_GRANT,
                "T10 second message not stale");
            chk(rx_control   === 11'h222,
                "T10 second control not stale");
            chk(rx_protocol_error === 1'b0, "T10 second no protocol error");
            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T10 returns to idle");
        end
    endtask

    //=========================================================================
    // T11 : stray BODY flit with no packet open
    //
    // It must be CONSUMED, not stalled. A security check that back-pressures
    // the router turns a spoofed flit into a fabric-wide deadlock.
    //=========================================================================

    task automatic t11_stray_body;
        begin
            banner("T11 stray BODY dropped");

            rx_ready = 1'b1;

            @(negedge clk);

            noc_rx_flit.flit_data = 32'hDEAD_DEAD;
            noc_rx_flit.flit_type = FLIT_BODY;
            noc_rx_flit.vc_id     = VC_REQUEST;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            chk(rx_protocol_error === 1'b1, "T11 protocol error raised");
            chk(rx_head_valid     === 1'b0, "T11 nothing delivered");
            chk(rx_payload_valid  === 1'b0, "T11 no payload delivered");
            chk(noc_rx_ready      === 1'b1, "T11 flit consumed, no stall");

            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T11 stays idle");
        end
    endtask

    //=========================================================================
    // T12 : misrouted packet
    //
    // Addressed to CPU1, delivered to CPU0. Under XY routing this cannot
    // happen by accident, so it is either a fabric bug or a spoof.
    //=========================================================================

    task automatic t12_misrouted;
        begin
            banner("T12 misrouted packet dropped");

            rx_ready = 1'b1;

            @(negedge clk);

            noc_rx_flit.flit_data = mk_head(tile_to_coord(TILE_CPU1),
                                            tile_to_coord(TILE_SPOOF),
                                            MSG_MEM_WR_REQ,
                                            message_length(MSG_MEM_WR_REQ),
                                            11'h000);
            noc_rx_flit.flit_type = FLIT_HEAD;
            noc_rx_flit.vc_id     = VC_REQUEST;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            chk(rx_protocol_error === 1'b1, "T12 protocol error raised");
            chk(rx_head_valid     === 1'b0, "T12 not delivered to the tile");
            chk(noc_rx_ready      === 1'b1, "T12 flit consumed, no stall");

            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T12 stays idle");
        end
    endtask

    //=========================================================================
    // T13 : lying length field
    //
    // The length field is attacker-controlled. The NI must recompute the
    // expected payload count locally from the message type and flag the
    // mismatch, and must never size a counter from the wire.
    //=========================================================================

    task automatic t13_length_lie;
        begin
            banner("T13 lying length field flagged");

            rx_ready = 1'b1;

            rx_begin(FLIT_HEAD, VC_REQUEST,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_SPOOF),
                             MSG_MEM_WR_REQ,
                             5'd31,              // claims 31; the real length is 3
                             11'h000));

            chk(rx_length_error === 1'b1,  "T13 length error raised");
            chk(rx_length       === 5'd31, "T13 wire length reported verbatim");
            chk(rx_head_valid   === 1'b1,  "T13 still delivered, flagged not dropped");
            rx_end;

            // The NI sized itself from msg_type, so the packet still ends
            // after exactly two payload flits despite the lie.
            rx_begin(FLIT_BODY, VC_REQUEST, 32'h0000_0001);
            chk(rx_payload_last === 1'b0, "T13 payload0 not last");
            rx_end;

            rx_begin(FLIT_TAIL, VC_REQUEST, 32'h0000_0002);
            chk(rx_payload_last === 1'b1, "T13 payload1 is last despite the lie");
            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T13 recovers to idle");
        end
    endtask

    //=========================================================================
    // T14 : malformed packet shape
    //
    // The flit type and the message type must agree about how many flits the
    // packet has. Two ways to break that:
    //
    //   (a) HEAD_TAIL for a message that owes payload flits. The tile would
    //       see a complete packet with rx_payload_last asserted and no data
    //       behind it, and whatever it reads next is stale. This is the one
    //       a spoof tile would actually use.
    //
    //   (b) HEAD for a message that owes nothing. The NI would open a packet
    //       that can never be closed and sit in RX_PAYLOAD forever, which is
    //       a one-flit denial of service against this tile.
    //
    // Both must be dropped, consumed, and flagged.
    //=========================================================================

    task automatic t14_bad_shape;
        begin
            banner("T14 malformed packet shape dropped");

            rx_ready = 1'b1;

            //-- (a) HEAD_TAIL that owes a payload ------------------------------
            @(negedge clk);

            noc_rx_flit.flit_data = mk_head(DUT_COORD,
                                            tile_to_coord(TILE_SPOOF),
                                            MSG_MEM_RD_RESP,   // owes 1 payload flit
                                            message_length(MSG_MEM_RD_RESP),
                                            11'h000);
            noc_rx_flit.flit_type = FLIT_HEAD_TAIL;
            noc_rx_flit.vc_id     = VC_RESPONSE;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            chk(rx_protocol_error === 1'b1, "T14a truncated HEAD_TAIL flagged");
            chk(rx_head_valid     === 1'b0, "T14a not delivered to the tile");
            chk(noc_rx_ready      === 1'b1, "T14a flit consumed, no stall");

            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T14a stays idle");

            //-- (b) HEAD that owes nothing -------------------------------------
            @(negedge clk);

            noc_rx_flit.flit_data = mk_head(DUT_COORD,
                                            tile_to_coord(TILE_SPOOF),
                                            MSG_MEM_WR_RESP,   // owes 0 payload flits
                                            message_length(MSG_MEM_WR_RESP),
                                            11'h000);
            noc_rx_flit.flit_type = FLIT_HEAD;
            noc_rx_flit.vc_id     = VC_RESPONSE;
            noc_rx_valid          = 1'b1;
            #TSETTLE;

            chk(rx_protocol_error === 1'b1, "T14b unclosable HEAD flagged");
            chk(rx_head_valid     === 1'b0, "T14b not delivered to the tile");
            chk(noc_rx_ready      === 1'b1, "T14b flit consumed, no stall");

            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T14b did not open a packet");

            //-- the NI must still work afterwards ------------------------------
            rx_begin(FLIT_HEAD_TAIL, VC_RESPONSE,
                     mk_head(DUT_COORD,
                             tile_to_coord(TILE_MEMORY),
                             MSG_MEM_WR_RESP,
                             message_length(MSG_MEM_WR_RESP),
                             11'h0AA));

            chk(rx_head_valid     === 1'b1,  "T14 good packet still accepted");
            chk(rx_control        === 11'h0AA, "T14 good packet control");
            chk(rx_protocol_error === 1'b0,  "T14 good packet not flagged");
            rx_end;

            @(negedge clk);
            #TSETTLE;
            chk(rx_busy === 1'b0, "T14 returns to idle");
        end
    endtask

    //=========================================================================
    // Testbench-side protocol assertions
    //
    // These check the DUT's interface contract. Legality of the STIMULUS is
    // deliberately NOT asserted here: T11, T12 and T14 inject illegal flits on
    // purpose, and an assertion forbidding them would fire during the very
    // tests that prove the DUT handles them.
    //=========================================================================

    property p_tx_valid_stable;
        @(posedge clk) disable iff (rst)
        noc_tx_valid && !noc_tx_ready |=> noc_tx_valid;
    endproperty
    a_tx_valid_stable: assert property (p_tx_valid_stable)
        else $error("SVA: egress valid dropped before acceptance");

    property p_tx_flit_stable;
        @(posedge clk) disable iff (rst)
        noc_tx_valid && !noc_tx_ready |=> $stable(noc_tx_flit);
    endproperty
    a_tx_flit_stable: assert property (p_tx_flit_stable)
        else $error("SVA: egress flit changed while stalled");

    property p_head_valid_implies_head_flit;
        @(posedge clk) disable iff (rst)
        rx_head_valid |-> (noc_rx_valid &&
                           (noc_rx_flit.flit_type == FLIT_HEAD ||
                            noc_rx_flit.flit_type == FLIT_HEAD_TAIL));
    endproperty
    a_head_valid_implies_head_flit: assert property (p_head_valid_implies_head_flit)
        else $error("SVA: rx_head_valid outside a head flit");

    property p_payload_valid_implies_body;
        @(posedge clk) disable iff (rst)
        rx_payload_valid |-> (noc_rx_valid &&
                              (noc_rx_flit.flit_type == FLIT_BODY ||
                               noc_rx_flit.flit_type == FLIT_TAIL));
    endproperty
    a_payload_valid_implies_body: assert property (p_payload_valid_implies_body)
        else $error("SVA: rx_payload_valid outside a body/tail flit");

    property p_error_excludes_delivery;
        @(posedge clk) disable iff (rst)
        rx_protocol_error |-> !(rx_head_valid || rx_payload_valid);
    endproperty
    a_error_excludes_delivery: assert property (p_error_excludes_delivery)
        else $error("SVA: packet both delivered and flagged illegal");

    property p_error_never_stalls;
        @(posedge clk) disable iff (rst)
        rx_protocol_error |-> noc_rx_ready;
    endproperty
    a_error_never_stalls: assert property (p_error_never_stalls)
        else $error("SVA: illegal flit flagged but not consumed - fabric stall");

    property p_no_egress_when_idle;
        @(posedge clk) disable iff (rst)
        !tx_busy |-> !noc_tx_valid;
    endproperty
    a_no_egress_when_idle: assert property (p_no_egress_when_idle)
        else $error("SVA: egress flit produced from the idle state");

    //=========================================================================
    // Watchdog
    //
    // A hang after a run of PASS lines looks like a DUT bug and wastes an
    // afternoon. This turns it into a failure with a timestamp.
    //=========================================================================

    initial begin
        #200000;
        $display("");
        $display("*** WATCHDOG: testbench did not finish. ***");
        $fatal(1, "tb_noc_ni watchdog expired");
    end

    //=========================================================================
    // Main
    //=========================================================================

    initial begin
        $display("");
        $display("============================================================");
        $display(" M10 NETWORK INTERFACE TESTBENCH");
        $display("   MAC_ENABLE = %0d   MAC_FLITS = %0d", MAC_ENABLE, MAC_FLITS);
        $display("   DUT tile   = TILE_CPU0 at (%0d,%0d)",
                 DUT_COORD.x, DUT_COORD.y);
        $display("============================================================");

        t01_reset;
        t02_single_tx;
        t03_multiflit_tx;
        t04_tx_backpressure;
        t05_bad_dest;
        t06_vc_mapping;
        t07_single_rx;
        t08_multiflit_rx;
        t09_rx_backpressure;
        t10_back_to_back_rx;
        t11_stray_body;
        t12_misrouted;
        t13_length_lie;
        t14_bad_shape;

        repeat (5) @(posedge clk);

        $display("");
        $display("============================================================");
        $display(" M10 SUMMARY");
        $display("   checks : %0d", checks);
        $display("   errors : %0d", errors);
        $display("   result : %s", (errors == 0) ? "PASS" : "FAIL");
        $display("============================================================");
        $display("");

        $finish;
    end

endmodule
