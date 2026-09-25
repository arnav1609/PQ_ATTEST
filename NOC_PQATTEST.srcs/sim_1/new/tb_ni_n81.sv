`timescale 1ns/1ps
//=============================================================================
// tb_ni_n81 - N-8.1 NI unit testbench (FD-1 B', M-F1 rev 4 sec.10)
//
// Spec : docs/decisions/N-8.1-ni-endpoint-containment.md rev 1, sec.11.1
// DUT  : noc_network_interface (tile CPU0 = (0,0)), driven directly on its
//        NoC RX / TX ports and tile ports. No router.
//
// Independence: packets are built here from message_length() /
// message_payload_flits() only (position rule: k = 0 HEAD or HEAD_TAIL,
// k = L-1 TAIL, else BODY). Expected deliveries, stall counts and report
// values are computed by the TB, not read back from DUT state, except the
// explicitly hierarchical checks marked [HIER].
//
// Run in both framing modes and both watchdog points:
//   MAC off : (no define)          -GW=1  and -GW=16
//   MAC on  : +define+PQ_MAC_ON    -GW=1  and -GW=16
// Any DUT SVA failure aborts the run (counts as FAIL).
//=============================================================================

// W can be set by define (XSim: xvlog -d N81_W=1) or by -GW (Verilator).
// The define path avoids xelab -generic_top, which has failed to launch in
// this Vivado project (N-7 pipe0, open item).
`ifndef N81_W
  `define N81_W 16
`endif

module tb_ni_n81 #(
    parameter int W = `N81_W
);

    import noc_pkg::*;

    localparam coord_t DUT_C  = tile_to_coord(TILE_CPU0);
    localparam coord_t SRC_C  = tile_to_coord(TILE_ROT);
    localparam coord_t MEM_C  = tile_to_coord(TILE_MEMORY);
    localparam coord_t OTHER_C = tile_to_coord(TILE_CPU1);

    //-------------------------------------------------------------------------
    // Signals
    //-------------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst;

    logic                    tx_valid, tx_ready;
    coord_t                  tx_dest_coord;
    msg_type_e               tx_msg_type;
    logic [10:0]             tx_control;
    logic [FLIT_WIDTH-1:0]   tx_payload_data;
    logic                    tx_payload_valid, tx_payload_ready;
    logic [MAC_TAG_BITS-1:0] tx_mac_tag;
    logic                    tx_error;

    flit_t                   noc_tx_flit;
    logic                    noc_tx_valid, noc_tx_ready;

    flit_t                   noc_rx_flit;
    logic                    noc_rx_valid, noc_rx_ready;

    coord_t                  rx_src_coord, rx_dest_coord;
    msg_type_e               rx_msg_type;
    logic [10:0]             rx_control;
    logic [4:0]              rx_length;
    logic                    rx_head_valid;
    logic [FLIT_WIDTH-1:0]   rx_payload_data;
    logic                    rx_payload_valid, rx_payload_last;
    logic                    rx_ready;
    logic [MAC_TAG_BITS-1:0] rx_mac_tag;
    logic                    rx_mac_valid;
    logic                    rx_protocol_error, rx_length_error, rx_abort;

    logic                    ni_status_clr;
    logic                    ni_contain_sticky, ni_framing_sticky;
    logic [7:0]              ni_contain_cnt, ni_framing_cnt;
    logic [9:0]              ni_contain_info;
    logic                    tx_busy, rx_busy;

    noc_network_interface #(
        .LOCAL_TILE_ID (int'(TILE_CPU0)),
        .WD_ENABLE     (1'b1),
        .WD_LIMIT      (W)
    ) dut (
        .clk, .rst,
        .tx_valid, .tx_ready, .tx_dest_coord, .tx_msg_type, .tx_control,
        .tx_payload_data, .tx_payload_valid, .tx_payload_ready,
        .tx_mac_tag, .tx_error,
        .noc_tx_flit, .noc_tx_valid, .noc_tx_ready,
        .noc_rx_flit, .noc_rx_valid, .noc_rx_ready,
        .rx_src_coord, .rx_dest_coord, .rx_msg_type, .rx_control, .rx_length,
        .rx_head_valid, .rx_payload_data, .rx_payload_valid, .rx_payload_last,
        .rx_ready, .rx_mac_tag, .rx_mac_valid,
        .rx_protocol_error, .rx_length_error, .rx_abort,
        .ni_status_clr, .ni_contain_sticky, .ni_contain_cnt, .ni_contain_info,
        .ni_framing_sticky, .ni_framing_cnt,
        .tx_busy, .rx_busy
    );

    always #5 clk = ~clk;

    //-------------------------------------------------------------------------
    // Check bookkeeping
    //-------------------------------------------------------------------------
    int checks = 0;
    int errors = 0;

    task automatic check(input bit cond, input string what);
        checks++;
        if (cond) $display("[PASS] %s", what);
        else begin
            errors++;
            $display("[FAIL] %s @ %0t", what, $time);
        end
    endtask

    //-------------------------------------------------------------------------
    // Cycle counter and independent monitors (sample pre-edge values)
    //-------------------------------------------------------------------------
    int cyc = 0;

    int  n_heads, n_pay, n_mac, n_abort, n_perr, n_lerr, n_stall;
    int  first_stall_cyc, last_acc_cyc;
    logic [FLIT_WIDTH-1:0]   got_pay [$];
    logic [MAC_TAG_BITS-1:0] got_mac_tag;
    bit  acc_q;

    task automatic clear_mon;
        n_heads = 0; n_pay = 0; n_mac = 0; n_abort = 0;
        n_perr = 0;  n_lerr = 0; n_stall = 0;
        first_stall_cyc = -1; last_acc_cyc = -1;
        got_pay.delete();
        got_mac_tag = '0;
    endtask

    always @(posedge clk) begin
        cyc <= cyc + 1;
        acc_q <= noc_rx_valid && noc_rx_ready;
        if (!rst) begin
            if (noc_rx_valid && noc_rx_ready) last_acc_cyc <= cyc;
            if (noc_rx_valid && !noc_rx_ready) begin
                n_stall <= n_stall + 1;
                if (first_stall_cyc < 0) first_stall_cyc <= cyc;
            end
            if (rx_head_valid && rx_ready)    n_heads <= n_heads + 1;
            if (rx_payload_valid && rx_ready) begin
                n_pay <= n_pay + 1;
                got_pay.push_back(rx_payload_data);
            end
            if (rx_mac_valid) begin
                n_mac <= n_mac + 1;
                got_mac_tag <= rx_mac_tag;
            end
            if (rx_abort)          n_abort <= n_abort + 1;
            if (rx_protocol_error) n_perr  <= n_perr + 1;
            if (rx_length_error)   n_lerr  <= n_lerr + 1;
        end
    end

    //-------------------------------------------------------------------------
    // Tile RX model. rx_ready is updated at posedge (NBA), stable per cycle.
    //   T_READY : always 1
    //   T_BLOCK : always 0
    //   T_STALLN: refuse the first tile_n OFFERED cycles, then accept
    //   T_ACCK  : accept the first tile_n offered cycles, then block
    //   T_DRIP  : accept one cycle in four
    //-------------------------------------------------------------------------
    typedef enum int {T_READY, T_BLOCK, T_STALLN, T_ACCK, T_DRIP} tmode_e;
    tmode_e tile_mode;
    int     tile_n;
    int     tile_refused, tile_accepted;

    task automatic set_tile(input tmode_e m, input int n);
        tile_mode     = m;
        tile_n        = n;
        tile_refused  = 0;
        tile_accepted = 0;
        case (m)
            T_READY : rx_ready = 1'b1;
            T_BLOCK : rx_ready = 1'b0;
            T_STALLN: rx_ready = (n == 0);
            T_ACCK  : rx_ready = (n > 0);
            T_DRIP  : rx_ready = 1'b0;
            default : rx_ready = 1'b1;
        endcase
    endtask

    always @(posedge clk) begin
        automatic bit offered = rx_head_valid || rx_payload_valid;
        automatic int ref_n = tile_refused  + ((offered && !rx_ready) ? 1 : 0);
        automatic int acc_n = tile_accepted + ((offered &&  rx_ready) ? 1 : 0);
        if (!rst) begin
            tile_refused  <= ref_n;
            tile_accepted <= acc_n;
            case (tile_mode)
                T_READY : rx_ready <= 1'b1;
                T_BLOCK : rx_ready <= 1'b0;
                T_STALLN: rx_ready <= (ref_n >= tile_n);
                T_ACCK  : rx_ready <= (acc_n <  tile_n);
                T_DRIP  : rx_ready <= ((cyc % 4) == 2);
                default : rx_ready <= 1'b1;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Packet builder (independent of the DUT)
    //-------------------------------------------------------------------------
    typedef flit_t flit_q_t [$];

    function automatic logic [FLIT_WIDTH-1:0] mk_head_word(
        input coord_t dst, input coord_t src, input msg_type_e m,
        input logic [4:0] len, input logic [10:0] ctrl);
        head_flit_t h;
        h = '0;
        h.dest_x = dst.x; h.dest_y = dst.y;
        h.src_x  = src.x; h.src_y  = src.y;
        h.msg_type = m;
        h.length   = len;
        h.control.raw = ctrl;
        return FLIT_WIDTH'(h);
    endfunction

    function automatic logic [FLIT_WIDTH-1:0] pay_word(input int seed, input int i);
        return 32'hA000_0000 + (seed << 8) + i;
    endfunction

    function automatic logic [FLIT_WIDTH-1:0] mac_word(input int seed, input int i);
        return 32'hC0DE_0000 + (seed << 8) + i;
    endfunction

    // Well-formed packet for msg m from src to dst.
    function automatic flit_q_t mk_pkt(input msg_type_e m, input coord_t dst,
                                       input coord_t src, input logic [10:0] ctrl,
                                       input int seed);
        flit_q_t q;
        flit_t   f;
        int L, n;
        L = int'(message_length(m));
        n = int'(message_payload_flits(m));
        for (int k = 0; k < L; k++) begin
            f = '0;
            f.vc_id = VC_ID_WIDTH'(message_to_vc(m));
            if (k == 0) begin
                f.flit_data = mk_head_word(dst, src, m, 5'(L), ctrl);
                f.flit_type = (L == 1) ? FLIT_HEAD_TAIL : FLIT_HEAD;
            end
            else begin
                f.flit_data = (k <= n) ? pay_word(seed, k - 1) : mac_word(seed, k - 1 - n);
                f.flit_type = (k == L - 1) ? FLIT_TAIL : FLIT_BODY;
            end
            q.push_back(f);
        end
        return q;
    endfunction

    //-------------------------------------------------------------------------
    // Router-side RX driver
    //-------------------------------------------------------------------------
    localparam int ACC_TIMEOUT = 4 * W + 64;

    // Present one flit and hold it until accepted. Returns 1 if accepted.
    task automatic send_flit(input flit_t f, output bit ok);
        int waited;
        @(negedge clk);
        noc_rx_flit  = f;
        noc_rx_valid = 1'b1;
        waited = 0;
        ok = 1'b0;
        forever begin
            @(posedge clk); #1;
            if (acc_q) begin ok = 1'b1; break; end
            waited++;
            if (waited > ACC_TIMEOUT) break;
        end
        @(negedge clk);
        noc_rx_valid = 1'b0;
        noc_rx_flit  = '0;
    endtask

    task automatic send_pkt(input flit_q_t q, input string name);
        bit ok;
        foreach (q[i]) begin
            send_flit(q[i], ok);
            if (!ok) begin
                check(1'b0, $sformatf("%s : flit %0d accepted (timeout)", name, i));
                return;
            end
        end
    endtask

    task automatic idle(input int n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    //-------------------------------------------------------------------------
    // Tile-side TX driver (store-and-forward NI)
    //-------------------------------------------------------------------------
    task automatic tx_request(input coord_t dst, input msg_type_e m,
                              input logic [10:0] ctrl, output bit accepted);
        int guard;
        @(negedge clk);
        tx_dest_coord = dst; tx_msg_type = m; tx_control = ctrl;
        tx_valid = 1'b1;
        guard = 0;
        #1;
        while (!tx_ready && guard < 50) begin
            @(negedge clk); #1; guard++;
        end
        accepted = tx_ready && !tx_error;
        @(posedge clk); #1;
        tx_valid = 1'b0;
    endtask

    task automatic tx_fill(input logic [FLIT_WIDTH-1:0] d, input int gap);
        repeat (gap) @(negedge clk);
        @(negedge clk);
        tx_payload_data  = d;
        tx_payload_valid = 1'b1;
        #1;
        while (!tx_payload_ready) begin @(negedge clk); #1; end
        @(posedge clk); #1;
        tx_payload_valid = 1'b0;
    endtask

    //-------------------------------------------------------------------------
    // Reset
    //-------------------------------------------------------------------------
    task automatic reset_dut;
        rst = 1'b1;
        tx_valid = 0; tx_dest_coord = '0; tx_msg_type = MSG_MEM_RD_REQ;
        tx_control = '0; tx_payload_data = '0; tx_payload_valid = 0;
        tx_mac_tag = '0; noc_tx_ready = 1'b1;
        noc_rx_flit = '0; noc_rx_valid = 1'b0;
        ni_status_clr = 1'b0;
        set_tile(T_READY, 0);
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        @(posedge clk); #1;
        clear_mon();
    endtask

    task automatic clr_status;
        @(negedge clk); ni_status_clr = 1'b1;
        @(negedge clk); ni_status_clr = 1'b0;
    endtask

    // A well-formed packet right after a fault must be delivered intact.
    task automatic check_recovery(input string name);
        flit_q_t q;
        int n;
        set_tile(T_READY, 0);
        clear_mon();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 77);
        send_pkt(q, {name, " recovery pkt"});
        idle(2);
        n = int'(message_payload_flits(MSG_ATTEST_CHALLENGE));
        check(n_heads == 1 && n_pay == n && n_abort == 0 && n_perr == 0,
              $sformatf("%s : next packet delivered intact (heads %0d pay %0d abort %0d perr %0d)",
                        name, n_heads, n_pay, n_abort, n_perr));
        begin
            bit data_ok = (got_pay.size() == n);
            for (int i = 0; i < got_pay.size() && i < n; i++)
                if (got_pay[i] !== pay_word(77, i)) data_ok = 1'b0;
            check(data_ok, {name, " : recovery payload data matches"});
        end
        check(!rx_busy, {name, " : NI idle after recovery"});
    endtask

    //=========================================================================
    // TESTS
    //=========================================================================

    // T01 well-formed packets, all RX-legal message shapes, tile ready.
    task automatic t01_good;
        msg_type_e ms [3] = '{MSG_ATTEST_GRANT, MSG_ATTEST_CHALLENGE, MSG_ATTEST_RESPONSE};
        $display("\n===== T01 well-formed packets =====");
        reset_dut();
        foreach (ms[j]) begin
            flit_q_t q;
            int n;
            clear_mon();
            q = mk_pkt(ms[j], DUT_C, SRC_C, 11'h0, j);
            n = int'(message_payload_flits(ms[j]));
            send_pkt(q, $sformatf("T01 msg %0d", ms[j]));
            idle(2);
            check(n_heads == 1 && n_pay == n && n_perr == 0 && n_abort == 0 && n_stall == 0,
                  $sformatf("T01 msg %0d : 1 head, %0d payload, no error/abort/stall", ms[j], n));
            check(n_mac == ((MAC_FLITS != 0) ? 1 : 0),
                  $sformatf("T01 msg %0d : rx_mac_valid count", ms[j]));
            if (MAC_FLITS != 0) begin
                logic [MAC_TAG_BITS-1:0] exp;
                for (int i = 0; i < int'(MAC_FLITS); i++)
                    exp[i*FLIT_WIDTH +: FLIT_WIDTH] = mac_word(j, i);
                check(got_mac_tag === exp,
                      $sformatf("T01 msg %0d : rx_mac_tag complete on rx_mac_valid", ms[j]));
            end
            check(!rx_busy, $sformatf("T01 msg %0d : NI idle", ms[j]));
        end
        check(!ni_contain_sticky && !ni_framing_sticky, "T01 : no sticky set");
    endtask

    // T02 F1 premature TAIL
    task automatic t02_premature_tail;
        flit_q_t q;
        $display("\n===== T02 F1 premature TAIL =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 2);
        // keep HEAD, BODY(k=1), TAIL at k=2; drop the rest
        q[2].flit_type = FLIT_TAIL;
        while (q.size() > 3) void'(q.pop_back());
        send_pkt(q, "T02");
        idle(2);
        check(n_heads == 1 && n_pay == 1, "T02 : HEAD + 1 payload delivered before the fault");
        check(n_abort == 1 && n_perr == 1, "T02 : premature TAIL -> abort + protocol error");
        check(!rx_busy, "T02 : premature TAIL is a terminator -> IDLE");
        check(ni_framing_sticky && ni_framing_cnt == 8'd1, "T02 : framing sticky, count 1");
        check_recovery("T02");
    endtask

    // T03 F2 BODY where TAIL expected (packet longer than declared)
    task automatic t03_body_at_end;
        flit_q_t q;
        flit_t   f;
        int L;
        $display("\n===== T03 F2 BODY where TAIL expected =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 3);
        L = q.size();
        q[L-1].flit_type = FLIT_BODY;           // BODY at k = L-1
        f = q[L-1]; f.flit_type = FLIT_BODY; q.push_back(f);   // extra BODY
        f.flit_type = FLIT_TAIL; q.push_back(f);               // real TAIL
        send_pkt(q, "T03");
        idle(2);
        check(n_abort == 1, "T03 : abort at the position of the expected TAIL");
        check(!rx_busy, "T03 : DISCARD consumed through the real TAIL -> IDLE");
        check(n_perr == 1 && ni_framing_cnt == 8'd1,
              $sformatf("T03 : exactly one framing event; extra flits eaten by DISCARD, not orphans (perr %0d)",
                        n_perr));
        check_recovery("T03");
    endtask

    // T04 F3 HEAD_TAIL for a multi-flit msg_type
    task automatic t04_headtail_multiflit;
        flit_t f;
        bit ok;
        $display("\n===== T04 F3 HEAD_TAIL on multi-flit type =====");
        reset_dut();
        f = '0;
        f.flit_data = mk_head_word(DUT_C, SRC_C, MSG_ATTEST_CHALLENGE,
                                   message_length(MSG_ATTEST_CHALLENGE), 11'h0);
        f.flit_type = FLIT_HEAD_TAIL;
        f.vc_id     = VC_ID_WIDTH'(VC_ATTESTATION);
        send_flit(f, ok);
        idle(2);
        check(ok && n_heads == 0 && n_perr == 1, "T04 : consumed, not delivered, protocol error");
        check(!rx_busy, "T04 : HEAD_TAIL at k=0 is a terminator -> IDLE");
        check_recovery("T04");
    endtask

    // T05 F3' HEAD for a zero-payload type (MAC off only; legal with MAC on)
    task automatic t05_head_zero_payload;
        flit_t f;
        bit ok;
        $display("\n===== T05 F3' HEAD on zero-payload type =====");
        if (MAC_FLITS != 0) begin
            $display("[SKIP] T05 : GRANT as HEAD is legal with MAC on");
            return;
        end
        reset_dut();
        f = '0;
        f.flit_data = mk_head_word(DUT_C, SRC_C, MSG_ATTEST_GRANT, 5'd1, 11'h0);
        f.flit_type = FLIT_HEAD;
        f.vc_id     = VC_ID_WIDTH'(VC_ATTESTATION);
        send_flit(f, ok);
        idle(1);
        check(ok && n_heads == 0 && n_perr == 1, "T05 : rejected HEAD consumed");
        check(rx_busy, "T05 : rejected HEAD -> DISCARD (router holds the wormhole)");
        f.flit_data = 32'h0; f.flit_type = FLIT_TAIL;
        send_flit(f, ok);
        idle(1);
        check(!rx_busy, "T05 : TAIL ends DISCARD");
        check_recovery("T05");
    endtask

    // T06 F4 length mismatch (short and long), full real packet follows
    task automatic t06_length;
        int lens [2] = '{3, 20};
        $display("\n===== T06 F4 length != message_length =====");
        foreach (lens[j]) begin
            flit_q_t q;
            reset_dut();
            q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 6);
            q[0].flit_data = mk_head_word(DUT_C, SRC_C, MSG_ATTEST_CHALLENGE, 5'(lens[j]), 11'h0);
            send_pkt(q, $sformatf("T06 len %0d", lens[j]));
            idle(2);
            check(n_heads == 0 && n_pay == 0,
                  $sformatf("T06 len %0d : HEAD rejected, nothing delivered (AM-6)", lens[j]));
            check(n_lerr == 1, $sformatf("T06 len %0d : rx_length_error", lens[j]));
            check(!rx_busy, $sformatf("T06 len %0d : discarded to the actual TAIL", lens[j]));
            check_recovery($sformatf("T06 len %0d", lens[j]));
        end
    endtask

    // T07 F5 VC mismatch / illegal VC 3 (HEAD and mid-packet)
    task automatic t07_vc;
        flit_q_t q;
        $display("\n===== T07 F5 VC mismatch / VC 3 =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 7);
        foreach (q[i]) q[i].vc_id = 2'd3;
        send_pkt(q, "T07 head VC3");
        idle(2);
        check(n_heads == 0 && n_pay == 0 && !rx_busy, "T07 : VC3 HEAD rejected, packet discarded");
        check_recovery("T07 head");

        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 7);
        q[2].vc_id = 2'd3;
        send_pkt(q, "T07 body VC3");
        idle(2);
        check(n_heads == 1 && n_pay == 1 && n_abort == 1, "T07 : mid-packet VC3 -> abort after 1 payload");
        check(!rx_busy, "T07 : discarded to TAIL");
        check_recovery("T07 body");
    endtask

    // T08 F7 mid-packet HEAD / HEAD_TAIL are NOT terminators.
    //   k=2 HEAD      : in RX_PAYLOAD -> abort, DISCARD (framing 1, perr 1)
    //   k=3 HEAD_TAIL : in RX_DISCARD at k>=1 -> NOT a terminator (framing 2)
    //   k=4.. BODY/TAIL: consumed in DISCARD, TAIL ends it.
    // Exact counts: a DISCARD that wrongly exits on HEAD_TAIL (M-n4) turns
    // the remaining BODY/TAIL into IDLE orphans (perr 3, framing 4).
    task automatic t08_midpacket_head;
        flit_q_t q;
        $display("\n===== T08 F7 mid-packet HEAD / HEAD_TAIL =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 8);
        q[2].flit_type = FLIT_HEAD;
        q[3].flit_type = FLIT_HEAD_TAIL;
        send_pkt(q, "T08");
        idle(1);
        check(n_abort == 1, "T08 : mid-packet HEAD aborts the packet");
        check(n_perr == 1, $sformatf("T08 : exactly one protocol error (%0d)", n_perr));
        check(ni_framing_cnt == 8'd2,
              $sformatf("T08 : HEAD_TAIL inside DISCARD counted, not a terminator (framing %0d)",
                        ni_framing_cnt));
        check(!rx_busy, "T08 : only the real TAIL ends DISCARD");
        check_recovery("T08");
    endtask

    // T09 F8 orphans in IDLE
    task automatic t09_orphans;
        flit_t f;
        bit ok;
        $display("\n===== T09 F8 orphan BODY / TAIL =====");
        reset_dut();
        f = '0; f.vc_id = 2'd2;
        f.flit_type = FLIT_BODY; send_flit(f, ok);
        f.flit_type = FLIT_TAIL; send_flit(f, ok);
        idle(1);
        check(n_perr == 2 && !rx_busy, "T09 : orphans consumed, stay IDLE");
        check(ni_framing_cnt == 8'd2, "T09 : 2 framing events");
        check_recovery("T09");
    endtask

    // T10 F9 reserved msg_type 8..15
    task automatic t10_reserved;
        flit_t f;
        bit ok;
        $display("\n===== T10 F9 reserved msg_type =====");
        reset_dut();
        f = '0;
        f.flit_data = mk_head_word(DUT_C, SRC_C, msg_type_e'(4'd9), 5'(1 + MAC_FLITS), 11'h0);
        f.flit_type = (MAC_FLITS == 0) ? FLIT_HEAD_TAIL : FLIT_HEAD;
        f.vc_id     = 2'd0;
        send_flit(f, ok);
        if (MAC_FLITS != 0) begin
            f.flit_data = 0;
            for (int i = 0; i < int'(MAC_FLITS); i++) begin
                f.flit_type = (i == int'(MAC_FLITS) - 1) ? FLIT_TAIL : FLIT_BODY;
                send_flit(f, ok);
            end
        end
        idle(2);
        check(n_heads == 0 && n_perr == 1 && !rx_busy, "T10 : reserved msg_type rejected (AM-5)");
        check_recovery("T10");
    endtask

    // T11 F10 not for us
    task automatic t11_not_for_us;
        flit_q_t q;
        $display("\n===== T11 F10 not addressed to us =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, OTHER_C, SRC_C, 11'h0, 11);
        send_pkt(q, "T11");
        idle(2);
        check(n_heads == 0 && n_pay == 0 && n_perr == 1 && !rx_busy,
              "T11 : consumed to its TAIL, one error, nothing delivered");
        check_recovery("T11");
    endtask

    // T12 F6 truncated packet + valid=0 hold (M-n3 target)
    task automatic t12_truncated_hold;
        flit_q_t q, rest;
        $display("\n===== T12 F6 truncated / counter holds on valid=0 =====");
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 12);
        // HEAD with tile ready, then W-1 refusals on BODY1
        set_tile(T_READY, 0);
        begin
            flit_q_t h; h.push_back(q[0]); send_pkt(h, "T12 head");
        end
        set_tile(T_STALLN, W - 1);
        begin
            flit_q_t b; b.push_back(q[1]); send_pkt(b, "T12 body1");
        end
        // upstream gap: noc_rx_valid = 0 for 4W cycles with tile refusing
        set_tile(T_BLOCK, 0);
        idle(4 * W);
        check(rx_busy && !ni_contain_sticky,
              "T12 : truncated packet stays owned; no containment while valid=0");
        check(n_stall == W - 1, $sformatf("T12 : stall cycles = W-1 (%0d)", n_stall));
        // finish the packet; tile ready -> total stall stays W-1
        set_tile(T_READY, 0);
        for (int i = 2; i < q.size(); i++) rest.push_back(q[i]);
        send_pkt(rest, "T12 rest");
        idle(2);
        check(!ni_contain_sticky && !rx_busy && n_abort == 0,
              "T12 : completed with W-1 stalls, no containment (valid=0 did not count)");
    endtask

    // T13 watchdog boundary: W-1 refusals ok, W refusals contain (M-n7 target)
    task automatic t13_boundary;
        flit_q_t q;
        int n;
        $display("\n===== T13 watchdog boundary W-1 / W =====");
        n = int'(message_payload_flits(MSG_ATTEST_CHALLENGE));

        reset_dut();
        set_tile(T_STALLN, W - 1);
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 13);
        send_pkt(q, "T13 W-1");
        idle(2);
        check(!ni_contain_sticky && n_pay == n && n_heads == 1,
              $sformatf("T13 : %0d refusals (W-1) -> delivered, no containment", W - 1));

        reset_dut();
        set_tile(T_STALLN, W);
        send_pkt(q, "T13 W");
        idle(2);
        check(ni_contain_sticky && ni_contain_cnt == 8'd1,
              $sformatf("T13 : %0d refusals (W) -> containment", W));
        check(n_stall == W, $sformatf("T13 : exactly W stall cycles (%0d)", n_stall));
        check(n_heads == 0 && n_pay == 0, "T13 : HEAD refused W times -> nothing delivered");
        check(n_abort == 1, "T13 : one rx_abort");
        check(!rx_busy, "T13 : whole packet discarded, IDLE");
        check(ni_contain_info == {SRC_C.x, SRC_C.y, MSG_ATTEST_CHALLENGE},
              "T13 : contain_info = {src, msg_type}");
        check_recovery("T13");
    endtask

    // T14 HEAD-pending containment: HEAD and HEAD_TAIL; forced accept timing
    task automatic t14_head_pending;
        flit_q_t q;
        $display("\n===== T14 HEAD-pending stall (AM-1) =====");
        reset_dut();
        set_tile(T_BLOCK, 0);
        q = mk_pkt(MSG_ATTEST_GRANT, DUT_C, SRC_C, 11'h0, 14);
        send_pkt(q, "T14 GRANT blocked");
        idle(2);
        check(ni_contain_sticky && n_heads == 0 && !rx_busy,
              "T14 : blocked GRANT contained and consumed");
        check(n_stall == W, $sformatf("T14 : W stall cycles on the pending HEAD (%0d)", n_stall));
        check(last_acc_cyc - first_stall_cyc >= W,
              $sformatf("T14 : first forced accept W cycles after first stall (%0d)",
                        last_acc_cyc - first_stall_cyc));

        reset_dut();
        set_tile(T_BLOCK, 0);
        q = mk_pkt(MSG_ATTEST_RESPONSE, DUT_C, SRC_C, 11'h0, 14);
        send_pkt(q, "T14 RESPONSE blocked");
        idle(2);
        check(ni_contain_sticky && ni_contain_cnt == 8'd1 && n_heads == 0 && n_pay == 0 && !rx_busy,
              "T14 : blocked 17/21-flit packet contained, fully consumed, nothing delivered");
        check(n_stall == W, "T14 : still exactly W stall cycles for the whole packet");
    endtask

    // T15 mid-packet containment (A-S1 shape) and slow drip (M-n2 target)
    task automatic t15_mid_and_drip;
        flit_q_t q;
        $display("\n===== T15 mid-packet + slow drip =====");
        reset_dut();
        set_tile(T_ACCK, 4);               // HEAD + 3 payload, then block
        q = mk_pkt(MSG_ATTEST_RESPONSE, DUT_C, SRC_C, 11'h0, 15);
        send_pkt(q, "T15 accept4");
        idle(2);
        check(n_heads == 1 && n_pay == 3 && n_abort == 1 && ni_contain_sticky && !rx_busy,
              "T15 : HEAD+3 delivered, then contained and discarded to TAIL");
        check(n_stall == W, "T15 : W stall cycles");

        reset_dut();
        set_tile(T_DRIP, 0);
        send_pkt(q, "T15 drip");
        idle(2);
        if (W <= 3 * int'(message_payload_flits(MSG_ATTEST_RESPONSE)))
            check(ni_contain_sticky && n_stall == W,
                  $sformatf("T15 : slow drip trips the per-packet budget (stall %0d)", n_stall));
        check(!rx_busy, "T15 : drip packet ends in IDLE");
    endtask

    // T16 counter resets at the terminator (two packets with W-1 each)
    task automatic t16_reset_per_packet;
        flit_q_t q;
        $display("\n===== T16 counter resets per packet =====");
        if (W < 2) begin $display("[SKIP] T16 needs W >= 2"); return; end
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 16);
        set_tile(T_STALLN, W - 1); send_pkt(q, "T16 a");
        set_tile(T_STALLN, W - 1); send_pkt(q, "T16 b");
        idle(2);
        check(!ni_contain_sticky && n_stall == 2 * (W - 1),
              "T16 : 2 x (W-1) stalls across two packets -> no containment");
    endtask

    // T17 MAC region never stalls (MAC on)
    task automatic t17_mac_nostall;
        flit_q_t q;
        $display("\n===== T17 MAC region never stalls =====");
        if (MAC_FLITS == 0) begin $display("[SKIP] T17 MAC off"); return; end
        reset_dut();
        q = mk_pkt(MSG_ATTEST_CHALLENGE, DUT_C, SRC_C, 11'h0, 17);
        set_tile(T_ACCK, 1 + int'(message_payload_flits(MSG_ATTEST_CHALLENGE)));
        send_pkt(q, "T17");
        idle(2);
        check(n_stall == 0 && n_mac == 1 && !ni_contain_sticky && !rx_busy,
              "T17 : tile blocked after payload; MAC flits consumed without stall");
    endtask

    // T18 report: clear, clear+event same cycle, saturation
    task automatic t18_report;
        flit_q_t q;
        flit_t f;
        bit ok;
        $display("\n===== T18 persistent report =====");
        reset_dut();
        set_tile(T_BLOCK, 0);
        q = mk_pkt(MSG_ATTEST_GRANT, DUT_C, SRC_C, 11'h0, 18);
        send_pkt(q, "T18 a");
        idle(20);
        check(ni_contain_sticky, "T18 : sticky persists 20 cycles after the event");
        set_tile(T_READY, 0);
        send_pkt(q, "T18 good");
        idle(2);
        check(ni_contain_sticky && ni_contain_cnt == 8'd1, "T18 : good traffic does not clear");
        clr_status();
        idle(1);
        check(!ni_contain_sticky && ni_contain_cnt == 0 && ni_contain_info == 0,
              "T18 : ni_status_clr clears");

        // framing saturation via 260 orphan TAILs
        f = '0; f.vc_id = 2'd2; f.flit_type = FLIT_TAIL;
        for (int i = 0; i < 260; i++) send_flit(f, ok);
        idle(1);
        check(ni_framing_cnt == 8'hFF && ni_framing_sticky, "T18 : framing counter saturates at 255");

        // event in the same cycle as a clear: event wins (count = 1)
        clr_status();
        @(negedge clk);
        f.flit_type = FLIT_TAIL;
        noc_rx_flit = f; noc_rx_valid = 1'b1; ni_status_clr = 1'b1;
        @(negedge clk);
        noc_rx_valid = 1'b0; ni_status_clr = 1'b0;
        idle(1);
        check(ni_framing_sticky && ni_framing_cnt == 8'd1, "T18 : clear + event same cycle -> count 1");
    endtask

    // T19 matched-response slot freed on containment and on framing abort (M-n5)
    task automatic t19_slot_free;
        bit acc;
        flit_q_t q;
        logic [10:0] c0, c1;
        $display("\n===== T19 slot freed on discard / containment =====");
        reset_dut();
        // two outstanding reads to MEMORY
        tx_request(MEM_C, MSG_MEM_RD_REQ, 11'h0, acc); tx_fill(32'h1, 0); idle(6);
        tx_request(MEM_C, MSG_MEM_RD_REQ, 11'h0, acc); tx_fill(32'h2, 0); idle(6);
        check(dut.txn_valid_q == 2'b11, "T19 [HIER] : two slots allocated");
        c0 = '0; c0[0] = 1'b0;
        c1 = '0; c1[0] = 1'b1;
        // response 0: tile blocks -> containment
        set_tile(T_BLOCK, 0);
        q = mk_pkt(MSG_MEM_RD_RESP, DUT_C, MEM_C, c0, 19);
        send_pkt(q, "T19 resp0");
        idle(2);
        check(ni_contain_sticky && dut.txn_valid_q[0] == 1'b0,
              "T19 [HIER] : contained response frees its slot");
        // response 1: F2-style framing abort (BODY at the expected TAIL, then TAIL)
        set_tile(T_READY, 0);
        q = mk_pkt(MSG_MEM_RD_RESP, DUT_C, MEM_C, c1, 19);
        begin
            flit_t f; int L = q.size();
            q[L-1].flit_type = FLIT_BODY;
            f = q[L-1]; f.flit_type = FLIT_TAIL; q.push_back(f);
        end
        send_pkt(q, "T19 resp1");
        idle(2);
        check(dut.txn_valid_q == 2'b00, "T19 [HIER] : aborted response frees its slot");
        // behavioural proof: two new requests are accepted
        tx_request(MEM_C, MSG_MEM_RD_REQ, 11'h0, acc); check(acc, "T19 : new request 1 accepted");
        tx_fill(32'h3, 0); idle(6);
        tx_request(MEM_C, MSG_MEM_RD_REQ, 11'h0, acc); check(acc, "T19 : new request 2 accepted");
        tx_fill(32'h4, 0); idle(6);
    endtask

    // T20 TX store-and-forward + reserved type
    task automatic t20_tx;
        bit acc;
        int n, L, got, bubbles;
        logic [MAC_TAG_BITS-1:0] tag;
        $display("\n===== T20 TX store-and-forward =====");
        reset_dut();
        n = int'(message_payload_flits(MSG_ATTEST_RESPONSE));
        L = int'(message_length(MSG_ATTEST_RESPONSE));
        for (int i = 0; i < int'(MAC_TAG_BITS / FLIT_WIDTH); i++)
            tag[i*FLIT_WIDTH +: FLIT_WIDTH] = mac_word(20, i);
        tx_mac_tag = tag;
        // Router side holds ready low during the fill so the packet cannot
        // drain before the streaming check below starts.
        noc_tx_ready = 1'b0;
        tx_request(RMT_ROT(), MSG_ATTEST_RESPONSE, 11'h0, acc);
        check(acc, "T20 : request accepted");
        begin
            bit seen = 0;
            bit fill_done = 0;
            fork
                begin
                    for (int i = 0; i < n; i++) tx_fill(pay_word(20, i), 2);   // slow tile
                    fill_done = 1;
                end
                begin
                    while (!fill_done) begin
                        @(posedge clk);
                        if (noc_tx_valid && !fill_done) seen = 1;
                    end
                end
            join
            check(!seen, "T20 : nothing injected while the payload is being filled");
        end
        // now the packet must stream with noc_tx_ready toggling; flit stable
        got = 0; bubbles = 0;
        while (got < L) begin
            @(negedge clk);
            noc_tx_ready = ($urandom_range(0, 2) != 0);
            #1;
            if (!noc_tx_valid) bubbles++;
            if (noc_tx_valid && noc_tx_ready) begin
                logic [FLIT_WIDTH-1:0] expd;
                flit_type_e expt;
                if (got == 0) expt = FLIT_HEAD;
                else expt = (got == L - 1) ? FLIT_TAIL : FLIT_BODY;
                if (got == 0) expd = noc_tx_flit.flit_data;
                else if (got <= n) expd = pay_word(20, got - 1);
                else expd = mac_word(20, got - 1 - n);
                if (noc_tx_flit.flit_type !== expt || noc_tx_flit.flit_data !== expd ||
                    noc_tx_flit.vc_id !== 2'd2)
                    check(1'b0, $sformatf("T20 : flit %0d type/data/vc", got));
                got++;
            end
        end
        noc_tx_ready = 1'b1;
        check(bubbles == 0, "T20 : no noc_tx_valid bubble from HEAD to TAIL (AM-2)");
        check(got == L, $sformatf("T20 : %0d flits sent with correct type/data/VC", L));
        idle(2);
        check(!tx_busy, "T20 : TX idle");

        tx_request(RMT_ROT(), msg_type_e'(4'd9), 11'h0, acc);
        check(!acc, "T20 : reserved msg_type not accepted, tx_error (AM-5)");
        idle(10);
        check(!tx_busy, "T20 : reserved msg_type sent nothing");
    endtask

    function automatic coord_t RMT_ROT();
        return tile_to_coord(TILE_ROT);
    endfunction

    //=========================================================================
    // MAIN
    //=========================================================================
    initial begin
        $display("============================================================");
        $display(" tb_ni_n81  W=%0d  MAC_FLITS=%0d", W, MAC_FLITS);
        $display("============================================================");
        t01_good();
        t02_premature_tail();
        t03_body_at_end();
        t04_headtail_multiflit();
        t05_head_zero_payload();
        t06_length();
        t07_vc();
        t08_midpacket_head();
        t09_orphans();
        t10_reserved();
        t11_not_for_us();
        t12_truncated_hold();
        t13_boundary();
        t14_head_pending();
        t15_mid_and_drip();
        t16_reset_per_packet();
        t17_mac_nostall();
        t18_report();
        t19_slot_free();
        t20_tx();
        idle(5);
        $display("============================================================");
        $display("CHECKS : %0d", checks);
        $display("ERRORS : %0d", errors);
        $display("CONFIG : W=%0d MAC_FLITS=%0d", W, MAC_FLITS);
        $display("RESULT : %s", (errors == 0) ? "PASS" : "FAIL");
        $display("============================================================");
        $finish;
    end

    initial begin
        #5ms;
        $display("RESULT : FAIL (global timeout)");
        $finish;
    end

endmodule
