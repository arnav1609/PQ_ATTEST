
// File        : noc_network_interface.sv
// Module      : noc_network_interface   (M10)
// Project     : PQ-Attest NoC
//
// M10 RESPONSIBILITIES
//   - Serialise a tile transaction into a NoC packet:
//       HEAD + PAYLOAD + optional MAC
//   - Deserialise incoming NoC packets back into tile transactions
//   - Select VC from message type
//   - Hardwire source coordinates from LOCAL_TILE_ID
//   - Enforce packet length and packet-shape correctness
//   - Reject packets not addressed to this tile
//   - Track up to N_OUTSTANDING remote memory transactions
//   - Allocate a transaction tag from the outstanding-table slot
//   - Carry transaction tag in head_flit.control[0]
//   - Match memory responses using:
//       response tag
//       response source coordinate
//       response message type
//   - Consume malformed/unmatched responses instead of stalling the fabric
//
// N-8.1 (FD-1 B', M-F1 rev 4 sec.10) - spec: docs/decisions/N-8.1-ni-endpoint-containment.md rev 1
//   RX
//   - Packet ends ONLY on the terminator flit (AM-3):
//         terminator(k, type) = (k == 0 && HEAD_TAIL) || (k >= 1 && TAIL)
//     Counters select the payload/MAC region and DETECT framing errors;
//     they never end a packet. This mirrors allocator.sv (only the owner's
//     TAIL releases a locked output).
//   - Rejected flits are always consumed (noc_rx_ready = 1). A rejected
//     HEAD or mid-packet non-terminator enters RX_DISCARD; a rejected
//     terminator or an orphan BODY/TAIL in IDLE stays/returns to IDLE.
//   - RX_DISCARD: noc_rx_ready = 1 every cycle; leaves only on the actual
//     terminator. Never "stop accepting".
//   - Per-packet cumulative watchdog (AM-1): counts cycles with
//         responsible && noc_rx_valid && !noc_rx_ready
//     including the HEAD-pending interval in RX_IDLE. Holds when
//     noc_rx_valid = 0. Expires on the WD_LIMIT-th stall cycle
//     (registered); forced acceptance begins the next cycle via DISCARD.
//   - Persistent report: sticky + saturating counter + first-event info,
//     cleared only by rst or ni_status_clr (trusted RoT side, never tile).
//   - A matched memory response frees its slot exactly once, at its
//     accepted terminator, whatever the outcome (delivered/aborted/discarded).
//   - Reserved msg_type 8..15, length mismatch and VC mismatch are rejected.
//   TX
//   - Store-and-forward (AM-2): the whole payload is collected from the
//     tile in TX_FILL before the HEAD is injected. From HEAD to terminator
//     noc_tx_valid = 1 every cycle; only the router can pause it.
//   - Reserved msg_type 8..15 raises tx_error and is never sent (AM-5).
//   - MAC tag source unchanged: tx_mac_tag sampled at request accept.
//
// TRANSACTION TAG
//   N_OUTSTANDING = 2
//   TXN_TAG_WIDTH = $clog2(2) = 1
//   tag            = control[0]
//
// IMPORTANT:
//   M10 owns the transaction tag. The CPU does NOT provide it.
//
// SECURITY NOTE:
//   The source-coordinate check is NOT cryptographic authentication.
//   A compromised destination tile could still forge its own response.
//   L2 MAC authentication in M13 is what closes that gap.
//
// Target:
//   xc7a100tcsg324-1, Vivado 2024.1
//=============================================================================

`timescale 1ns/1ps

module noc_network_interface #(
    parameter int LOCAL_TILE_ID = 0,

    // N-8.1 watchdog. WD_LIMIT = 16 is a TEST DEFAULT, not a production
    // value: W_prod = S_tile + 1 from the tile contract (OPEN-T1, N-14).
    // WD_ENABLE = 0 exists ONLY for the negative-control simulation.
    parameter bit WD_ENABLE = 1'b1,
    parameter int WD_LIMIT  = 16
) (
    input  logic clk,
    input  logic rst,

    //=========================================================================
    // TILE -> NoC : transaction request
    //=========================================================================

    input  logic                           tx_valid,
    output logic                           tx_ready,

    input  noc_pkg::coord_t                tx_dest_coord,
    input  noc_pkg::msg_type_e             tx_msg_type,
    input  logic [10:0]                    tx_control,

    input  logic [noc_pkg::FLIT_WIDTH-1:0] tx_payload_data,
    input  logic                           tx_payload_valid,
    output logic                           tx_payload_ready,

    input  logic [noc_pkg::MAC_TAG_BITS-1:0] tx_mac_tag,

    output logic                           tx_error,

    //=========================================================================
    // NoC egress
    //=========================================================================

    output noc_pkg::flit_t                 noc_tx_flit,
    output logic                           noc_tx_valid,
    input  logic                           noc_tx_ready,

    //=========================================================================
    // NoC ingress
    //=========================================================================

    input  noc_pkg::flit_t                 noc_rx_flit,
    input  logic                           noc_rx_valid,
    output logic                           noc_rx_ready,

    //=========================================================================
    // NoC -> TILE : received transaction
    //=========================================================================

    output noc_pkg::coord_t                rx_src_coord,
    output noc_pkg::coord_t                rx_dest_coord,
    output noc_pkg::msg_type_e             rx_msg_type,
    output logic [10:0]                    rx_control,
    output logic [4:0]                     rx_length,
    output logic                           rx_head_valid,

    output logic [noc_pkg::FLIT_WIDTH-1:0] rx_payload_data,
    output logic                           rx_payload_valid,
    output logic                           rx_payload_last,
    input  logic                           rx_ready,

    output logic [noc_pkg::MAC_TAG_BITS-1:0] rx_mac_tag,
    output logic                           rx_mac_valid,

    output logic                           rx_protocol_error,
    output logic                           rx_length_error,

    // N-8.1: the packet in progress will not complete; tile drops partial data.
    output logic                           rx_abort,

    //=========================================================================
    // N-8.1 persistent containment / framing report (to RoT / status side)
    //=========================================================================

    // One-cycle clear. INTEGRATION RULE (N-14): driven by the trusted RoT /
    // status register only, NEVER by the local tile.
    input  logic                           ni_status_clr,

    output logic                           ni_contain_sticky,
    output logic [7:0]                     ni_contain_cnt,
    output logic [9:0]                     ni_contain_info,   // {src_x, src_y, msg_type}
    output logic                           ni_framing_sticky,
    output logic [7:0]                     ni_framing_cnt,

    //=========================================================================
    // Status
    //=========================================================================

    output logic                           tx_busy,
    output logic                           rx_busy
);

    import noc_pkg::*;

    //=========================================================================
    // Local constants
    //=========================================================================

    localparam tile_id_e LOCAL_TILE =
        tile_id_e'(LOCAL_TILE_ID[TILE_ID_WIDTH-1:0]);

    localparam coord_t LOCAL_COORD =
        tile_to_coord(LOCAL_TILE);

    localparam int unsigned MAC_CNT_WIDTH =
        (MAC_FLITS_FULL <= 1) ? 1 : $clog2(MAC_FLITS_FULL + 1);

    // Largest payload of any message type (ATTEST_RESPONSE = 16).
    localparam int unsigned TX_BUF_DEPTH = 16;
    localparam int unsigned TX_BUF_AW    = $clog2(TX_BUF_DEPTH);

    // Watchdog counter: range 0 .. WD_LIMIT-1 (the value WD_LIMIT is never
    // stored: the stall that would reach it is the expiry cycle, which
    // resets the counter). One spare value is deliberate: works for W = 1.
    localparam int unsigned WD_W = $clog2(WD_LIMIT + 1);

    //=========================================================================
    // Transaction tracking
    //=========================================================================

    logic [N_OUTSTANDING-1:0] txn_valid_q;

    coord_t txn_dest_q [N_OUTSTANDING];

    msg_type_e txn_resp_type_q [N_OUTSTANDING];

    logic [TXN_TAG_WIDTH-1:0] tx_alloc_tag;
    logic                      tx_slot_available;

    logic [TXN_TAG_WIDTH-1:0] rx_resp_tag;
    logic                      rx_response_match;
    logic [TXN_TAG_WIDTH-1:0] rx_match_slot;

    logic rx_is_mem_response;

    //=========================================================================
    // Find lowest-numbered free outstanding slot.
    //=========================================================================

    always_comb begin

        tx_slot_available = 1'b0;
        tx_alloc_tag      = '0;

        for (int i = 0; i < N_OUTSTANDING; i++) begin

            if (!txn_valid_q[i] && !tx_slot_available) begin

                tx_slot_available = 1'b1;
                tx_alloc_tag      = TXN_TAG_WIDTH'(i);

            end

        end

    end

    //=========================================================================
    // TX state
    //=========================================================================

    typedef enum logic [2:0] {
        TX_IDLE    = 3'd0,
        TX_FILL    = 3'd1,     // N-8.1 store-and-forward
        TX_HEAD    = 3'd2,
        TX_PAYLOAD = 3'd3,
        TX_MAC     = 3'd4
    } tx_state_e;

    tx_state_e tx_state_q;
    tx_state_e tx_state_d;

    coord_t                   tx_dest_q;
    msg_type_e                tx_msg_q;
    logic [10:0]              tx_control_q;
    logic [4:0]               tx_payload_n_q;
    logic [4:0]               tx_payload_cnt_q;
    logic [4:0]               tx_fill_cnt_q;
    logic [MAC_CNT_WIDTH-1:0] tx_mac_cnt_q;
    logic [MAC_TAG_BITS-1:0]  tx_mac_tag_q;

    // Payload buffer. No reset: written before it is read in every packet,
    // and a reset would prevent distributed-RAM inference.
    logic [FLIT_WIDTH-1:0]    tx_buf [TX_BUF_DEPTH];

    vc_e        tx_vc;
    head_flit_t tx_head;

    logic tx_dest_ok;
    logic tx_msg_legal;
    logic tx_accept;
    logic tx_fill_hs;
    logic tx_single;
    logic tx_last_payload;
    logic tx_last_fill;
    logic tx_last_mac;

    //=========================================================================
    // RX state
    //=========================================================================

    typedef enum logic [1:0] {
        RX_IDLE    = 2'd0,
        RX_PAYLOAD = 2'd1,
        RX_MAC     = 2'd2,
        RX_DISCARD = 2'd3      // N-8.1: consume to the actual terminator
    } rx_state_e;

    rx_state_e rx_state_q;
    rx_state_e rx_state_d;

    coord_t                   rx_src_q;
    coord_t                   rx_dest_q;
    msg_type_e                rx_msg_q;
    logic [10:0]              rx_control_q;
    logic [4:0]               rx_length_q;
    logic [VC_ID_WIDTH-1:0]   rx_vc_q;
    logic [4:0]               rx_payload_n_q;
    logic [4:0]               rx_payload_cnt_q;
    logic [MAC_CNT_WIDTH-1:0] rx_mac_cnt_q;
    logic [MAC_TAG_BITS-1:0]  rx_mac_tag_q;

    // DISCARD entered with the HEAD still on the wire (k == 0): a HEAD_TAIL
    // there is the terminator. Otherwise only TAIL terminates.
    logic                     rx_disc_start_q;

    // Slot to free at this packet's terminator (matched memory response).
    logic                     rx_free_q;
    logic [TXN_TAG_WIDTH-1:0] rx_free_tag_q;

    head_flit_t rx_head;

    logic       rx_is_head;
    logic       rx_is_head_tail;
    logic       rx_head_for_us;
    logic       rx_head_msg_legal;
    logic       rx_head_len_ok;
    logic       rx_head_shape_ok;
    logic       rx_head_vc_ok;
    logic       rx_head_resp_ok;
    logic       rx_head_deliverable;
    logic       rx_head_frees_slot;
    logic [4:0] rx_head_payload_n;

    // Per-cycle RX control (outputs of the RX always_comb)
    logic rx_accept;          // noc_rx_valid && noc_rx_ready
    logic rx_responsible;     // watchdog armed this cycle
    logic rx_stall;
    logic rx_expire;
    logic rx_term_acc;        // accepted flit is this packet's terminator
    logic rx_enter_discard;   // non-watchdog entry into DISCARD
    logic rx_framing_evt;
    logic rx_do_free;         // free rx_*free* slot this cycle
    logic rx_abort_fr;        // abort from a framing error

    logic [WD_W-1:0] wd_cnt_q;

    //=========================================================================
    // TX PATH
    //=========================================================================

    assign tx_dest_ok   = valid_coord(tx_dest_coord);

    // AM-5: msg_type 8..15 are reserved.
    assign tx_msg_legal = !tx_msg_type[3];

    assign tx_accept =
        (tx_state_q == TX_IDLE) &&
        tx_valid &&
        tx_ready &&
        tx_dest_ok &&
        tx_msg_legal;

    assign tx_fill_hs =
        (tx_state_q == TX_FILL) &&
        tx_payload_valid &&
        tx_payload_ready;

    assign tx_vc = message_to_vc(tx_msg_q);

    assign tx_single =
        (tx_payload_n_q == 5'd0) &&
        (MAC_FLITS == 0);

    assign tx_last_payload =
        (tx_payload_cnt_q + 5'd1) >= tx_payload_n_q;

    assign tx_last_fill =
        (tx_fill_cnt_q + 5'd1) >= tx_payload_n_q;

    assign tx_last_mac =
        (MAC_FLITS != 0) &&
        ((tx_mac_cnt_q + MAC_CNT_WIDTH'(1)) >=
         MAC_CNT_WIDTH'(MAC_FLITS));

    //=========================================================================
    // TX head construction
    //=========================================================================

    always_comb begin

        tx_head             = '0;

        tx_head.dest_x      = tx_dest_q.x;
        tx_head.dest_y      = tx_dest_q.y;

        tx_head.src_x       = LOCAL_COORD.x;
        tx_head.src_y       = LOCAL_COORD.y;

        tx_head.msg_type    = tx_msg_q;
        tx_head.length      = message_length(tx_msg_q);

        tx_head.control.raw = tx_control_q;

    end

    //=========================================================================
    // TX outputs
    //=========================================================================

    always_comb begin

        noc_tx_flit      = '0;
        noc_tx_valid     = 1'b0;

        tx_ready         = 1'b0;
        tx_payload_ready = 1'b0;

        tx_error         = 1'b0;

        unique case (tx_state_q)

            TX_IDLE: begin

                if ((tx_msg_type == MSG_MEM_RD_REQ) ||
                    (tx_msg_type == MSG_MEM_WR_REQ)) begin

                    tx_ready = tx_slot_available;

                end
                else begin

                    tx_ready = 1'b1;

                end

                tx_error =
                    tx_valid &&
                    (!tx_dest_ok || !tx_msg_legal);

            end

            //-----------------------------------------------------------------
            // N-8.1 store-and-forward: collect the whole payload from the
            // tile. Nothing is in the network yet, so a stalling tile holds
            // only its own NI.
            //-----------------------------------------------------------------
            TX_FILL: begin

                tx_payload_ready = 1'b1;

            end

            TX_HEAD: begin

                noc_tx_valid          = 1'b1;

                noc_tx_flit.flit_data = tx_head;

                noc_tx_flit.flit_type =
                    tx_single ? FLIT_HEAD_TAIL : FLIT_HEAD;

                noc_tx_flit.vc_id =
                    tx_vc;

            end

            // Payload comes from the buffer: never depends on the tile.
            TX_PAYLOAD: begin

                noc_tx_valid          = 1'b1;

                noc_tx_flit.flit_data =
                    tx_buf[tx_payload_cnt_q[TX_BUF_AW-1:0]];

                noc_tx_flit.flit_type =
                    (tx_last_payload && (MAC_FLITS == 0))
                    ? FLIT_TAIL
                    : FLIT_BODY;

                noc_tx_flit.vc_id =
                    tx_vc;

            end

            TX_MAC: begin

                noc_tx_valid = 1'b1;

                noc_tx_flit.flit_data =
                    tx_mac_tag_q[
                        {tx_mac_cnt_q, 5'd0} +: FLIT_WIDTH
                    ];

                noc_tx_flit.flit_type =
                    tx_last_mac
                    ? FLIT_TAIL
                    : FLIT_BODY;

                noc_tx_flit.vc_id =
                    tx_vc;

            end

            default: begin

                noc_tx_valid = 1'b0;

            end

        endcase

    end

    //=========================================================================
    // TX next-state
    //=========================================================================

    always_comb begin

        tx_state_d = tx_state_q;

        unique case (tx_state_q)

            TX_IDLE: begin

                if (tx_accept) begin

                    if (message_payload_flits(tx_msg_type) != 5'd0)
                        tx_state_d = TX_FILL;
                    else
                        tx_state_d = TX_HEAD;

                end

            end

            TX_FILL: begin

                if (tx_fill_hs && tx_last_fill)
                    tx_state_d = TX_HEAD;

            end

            TX_HEAD: begin

                if (noc_tx_valid && noc_tx_ready) begin

                    if (tx_single)
                        tx_state_d = TX_IDLE;

                    else if (tx_payload_n_q != 5'd0)
                        tx_state_d = TX_PAYLOAD;

                    else
                        tx_state_d = TX_MAC;

                end

            end

            TX_PAYLOAD: begin

                if (noc_tx_valid &&
                    noc_tx_ready &&
                    tx_last_payload) begin

                    tx_state_d =
                        (MAC_FLITS != 0)
                        ? TX_MAC
                        : TX_IDLE;

                end

            end

            TX_MAC: begin

                if (noc_tx_valid &&
                    noc_tx_ready &&
                    tx_last_mac) begin

                    tx_state_d = TX_IDLE;

                end

            end

            default: begin

                tx_state_d = TX_IDLE;

            end

        endcase

    end

    //=========================================================================
    // TX payload buffer write (distributed RAM, no reset)
    //=========================================================================

    always_ff @(posedge clk) begin

        if (tx_fill_hs) begin

            tx_buf[tx_fill_cnt_q[TX_BUF_AW-1:0]] <= tx_payload_data;

        end

    end

    //=========================================================================
    // TX registers
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            tx_state_q       <= TX_IDLE;

            tx_dest_q        <= '0;
            tx_msg_q         <= MSG_MEM_RD_REQ;
            tx_control_q     <= '0;

            tx_payload_n_q   <= '0;
            tx_payload_cnt_q <= '0;
            tx_fill_cnt_q    <= '0;

            tx_mac_cnt_q     <= '0;
            tx_mac_tag_q     <= '0;

        end
        else begin

            tx_state_q <= tx_state_d;

            //-----------------------------------------------------------------
            // Accept new transaction
            //-----------------------------------------------------------------

            if (tx_accept) begin

                tx_dest_q    <= tx_dest_coord;
                tx_msg_q     <= tx_msg_type;

                tx_control_q <= tx_control;

                tx_payload_n_q <=
                    message_payload_flits(tx_msg_type);

                tx_payload_cnt_q <= '0;
                tx_fill_cnt_q    <= '0;
                tx_mac_cnt_q     <= '0;

                // MAC source unchanged (N-8.1 sec.8): sampled at request accept.
                tx_mac_tag_q <= tx_mac_tag;

                //-----------------------------------------------------------------
                // Allocate tag for memory requests.
                //-----------------------------------------------------------------

                if ((tx_msg_type == MSG_MEM_RD_REQ) ||
                    (tx_msg_type == MSG_MEM_WR_REQ)) begin

                    tx_control_q[TXN_TAG_WIDTH-1:0]
                        <= tx_alloc_tag;

                end

            end

            //-----------------------------------------------------------------
            // Fill counter
            //-----------------------------------------------------------------

            if (tx_fill_hs) begin

                tx_fill_cnt_q <= tx_fill_cnt_q + 5'd1;

            end

            //-----------------------------------------------------------------
            // Payload counter
            //-----------------------------------------------------------------

            if ((tx_state_q == TX_PAYLOAD) &&
                noc_tx_valid &&
                noc_tx_ready) begin

                tx_payload_cnt_q <=
                    tx_payload_cnt_q + 5'd1;

            end

            //-----------------------------------------------------------------
            // MAC counter
            //-----------------------------------------------------------------

            if ((tx_state_q == TX_MAC) &&
                noc_tx_valid &&
                noc_tx_ready) begin

                tx_mac_cnt_q <=
                    tx_mac_cnt_q + MAC_CNT_WIDTH'(1);

            end

        end

    end

    //=========================================================================
    // Outstanding transaction table
    //
    // Allocation: at TX request accept.
    // Release (N-8.1 Gap D): exactly once, at the accepted TERMINATOR of the
    // packet whose HEAD matched, whatever happened to the packet (delivered,
    // aborted on a framing error, or discarded by containment). The slot tag
    // is registered at HEAD time (rx_free_q / rx_free_tag_q) except for a
    // HEAD_TAIL accepted in IDLE, where the live header is still on the wire.
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            for (int i = 0; i < N_OUTSTANDING; i++) begin

                txn_valid_q[i] <= 1'b0;

                txn_dest_q[i] <= '0;

                txn_resp_type_q[i] <=
                    MSG_MEM_RD_RESP;

            end

        end
        else begin

            //-----------------------------------------------------------------
            // Allocate slot when memory request is accepted.
            //-----------------------------------------------------------------

            if (tx_accept &&
                ((tx_msg_type == MSG_MEM_RD_REQ) ||
                 (tx_msg_type == MSG_MEM_WR_REQ))) begin

                txn_valid_q[tx_alloc_tag] <= 1'b1;

                txn_dest_q[tx_alloc_tag] <=
                    tx_dest_coord;

                if (tx_msg_type == MSG_MEM_RD_REQ) begin

                    txn_resp_type_q[tx_alloc_tag] <=
                        MSG_MEM_RD_RESP;

                end
                else begin

                    txn_resp_type_q[tx_alloc_tag] <=
                        MSG_MEM_WR_RESP;

                end

            end

            //-----------------------------------------------------------------
            // Release.
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_IDLE) &&
                rx_accept &&
                rx_is_head_tail &&
                rx_head_frees_slot) begin

                // Single-flit response, live header on the wire.
                txn_valid_q[rx_match_slot] <= 1'b0;

            end
            else if (rx_do_free) begin

                // Multi-flit (or contained) response: registered tag.
                txn_valid_q[rx_free_tag_q] <= 1'b0;

            end

        end

    end

    //=========================================================================
    // RX PATH - header decode (valid only when the flit is HEAD/HEAD_TAIL)
    //=========================================================================

    assign rx_head =
        head_flit_t'(noc_rx_flit.flit_data);

    assign rx_is_head =
        noc_rx_valid &&
        (noc_rx_flit.flit_type == FLIT_HEAD);

    assign rx_is_head_tail =
        noc_rx_valid &&
        (noc_rx_flit.flit_type == FLIT_HEAD_TAIL);

    assign rx_head_for_us =
        (rx_head.dest_x == LOCAL_COORD.x) &&
        (rx_head.dest_y == LOCAL_COORD.y);

    // AM-5
    assign rx_head_msg_legal =
        !rx_head.msg_type[3];

    assign rx_head_payload_n =
        message_payload_flits(rx_head.msg_type);

    // AM-6: length must equal message_length(msg_type)
    assign rx_head_len_ok =
        (rx_head.length ==
         (5'd1 +
          rx_head_payload_n +
          5'(MAC_FLITS)));

    assign rx_head_shape_ok =
        rx_is_head_tail
        ? ((rx_head_payload_n == 5'd0) &&
           (MAC_FLITS == 0))
        : ((rx_head_payload_n != 5'd0) ||
           (MAC_FLITS != 0));

    // F5: VC must be the message's VC (VC 3 always fails).
    assign rx_head_vc_ok =
        (noc_rx_flit.vc_id ==
         VC_ID_WIDTH'(message_to_vc(rx_head.msg_type)));

    //=========================================================================
    // Response matching
    //=========================================================================

    assign rx_is_mem_response =
        (rx_head.msg_type == MSG_MEM_RD_RESP) ||
        (rx_head.msg_type == MSG_MEM_WR_RESP);

    assign rx_resp_tag =
        rx_head.control.raw[TXN_TAG_WIDTH-1:0];

    always_comb begin

        rx_match_slot     = '0;
        rx_response_match = 1'b0;

        if (rx_is_mem_response) begin

            if (int'(rx_resp_tag) < N_OUTSTANDING) begin

                rx_match_slot = rx_resp_tag;

                if (txn_valid_q[rx_resp_tag] &&
                    (rx_head.src_x ==
                     txn_dest_q[rx_resp_tag].x) &&
                    (rx_head.src_y ==
                     txn_dest_q[rx_resp_tag].y) &&
                    (rx_head.msg_type ==
                     txn_resp_type_q[rx_resp_tag])) begin

                    rx_response_match = 1'b1;

                end

            end

        end

    end

    assign rx_head_resp_ok =
        !(rx_is_mem_response && !rx_response_match);

    assign rx_head_deliverable =
        (rx_is_head || rx_is_head_tail) &&
        rx_head_for_us &&
        rx_head_msg_legal &&
        rx_head_shape_ok &&
        rx_head_len_ok &&
        rx_head_vc_ok &&
        rx_head_resp_ok;

    // A matched response addressed to us frees its slot at its terminator,
    // whether it is delivered or rejected for another reason (e.g. length).
    assign rx_head_frees_slot =
        (rx_is_head || rx_is_head_tail) &&
        rx_head_for_us &&
        rx_is_mem_response &&
        rx_response_match;

    //=========================================================================
    // RX body/tail/MAC position checks (valid in RX_PAYLOAD / RX_MAC)
    //=========================================================================

    logic rx_last_payload;
    logic rx_last_mac;
    logic rx_vc_ok;
    logic rx_pay_legal;
    logic rx_mac_legal;

    assign rx_last_payload =
        (rx_payload_cnt_q + 5'd1) >= rx_payload_n_q;

    assign rx_last_mac =
        (rx_mac_cnt_q + MAC_CNT_WIDTH'(1)) >=
        MAC_CNT_WIDTH'(MAC_FLITS);

    assign rx_vc_ok =
        (noc_rx_flit.vc_id == rx_vc_q);

    // Expected type in the payload region: TAIL only at the last payload
    // flit with MAC off; BODY otherwise.
    assign rx_pay_legal =
        rx_vc_ok &&
        ((rx_last_payload && (MAC_FLITS == 0))
         ? (noc_rx_flit.flit_type == FLIT_TAIL)
         : (noc_rx_flit.flit_type == FLIT_BODY));

    // Expected type in the MAC region: TAIL only at the last MAC flit.
    assign rx_mac_legal =
        rx_vc_ok &&
        (rx_last_mac
         ? (noc_rx_flit.flit_type == FLIT_TAIL)
         : (noc_rx_flit.flit_type == FLIT_BODY));

    //=========================================================================
    // RX outputs + control (single always_comb: one place defines ready)
    //=========================================================================

    always_comb begin

        rx_head_valid     = 1'b0;

        rx_payload_valid  = 1'b0;
        rx_payload_last   = 1'b0;
        rx_payload_data   = '0;

        rx_mac_valid      = 1'b0;

        rx_protocol_error = 1'b0;
        rx_length_error   = 1'b0;
        rx_abort_fr       = 1'b0;

        noc_rx_ready      = 1'b0;

        rx_responsible    = 1'b0;
        rx_framing_evt    = 1'b0;

        rx_src_coord  = rx_src_q;
        rx_dest_coord = rx_dest_q;
        rx_msg_type   = rx_msg_q;
        rx_control    = rx_control_q;
        rx_length     = rx_length_q;

        unique case (rx_state_q)

            //=================================================================
            // RX_IDLE : expecting HEAD / HEAD_TAIL (k = 0)
            //=================================================================

            RX_IDLE: begin

                if (rx_head_deliverable) begin

                    // Responsibility starts at presentation (AM-1).
                    rx_responsible = 1'b1;

                    noc_rx_ready  = rx_ready;
                    rx_head_valid = 1'b1;

                    rx_src_coord =
                        '{x: rx_head.src_x,
                          y: rx_head.src_y};

                    rx_dest_coord =
                        '{x: rx_head.dest_x,
                          y: rx_head.dest_y};

                    rx_msg_type =
                        rx_head.msg_type;

                    rx_control =
                        rx_head.control.raw;

                    rx_length =
                        rx_head.length;

                    rx_payload_last =
                        rx_is_head_tail;

                end
                else if (rx_is_head || rx_is_head_tail) begin

                    // Rejected HEAD / HEAD_TAIL: consume, report.
                    noc_rx_ready   = 1'b1;
                    rx_framing_evt = 1'b1;

                    if (!rx_head_len_ok &&
                        rx_head_for_us &&
                        rx_head_msg_legal &&
                        rx_head_shape_ok &&
                        rx_head_vc_ok &&
                        rx_head_resp_ok)
                        rx_length_error   = 1'b1;
                    else
                        rx_protocol_error = 1'b1;

                end
                else if (noc_rx_valid) begin

                    // F8 orphan BODY / TAIL: consume, report, stay IDLE.
                    noc_rx_ready      = 1'b1;
                    rx_protocol_error = 1'b1;
                    rx_framing_evt    = 1'b1;

                end

            end

            //=================================================================
            // RX_PAYLOAD : owned packet, payload region (k >= 1)
            //=================================================================

            RX_PAYLOAD: begin

                rx_responsible = 1'b1;

                if (noc_rx_valid) begin

                    if (rx_pay_legal) begin

                        noc_rx_ready     = rx_ready;

                        rx_payload_valid = 1'b1;

                        rx_payload_data  =
                            noc_rx_flit.flit_data;

                        rx_payload_last  =
                            rx_last_payload;

                    end
                    else begin

                        // F1 / F2 / F5 / F7: consume, abort the packet.
                        noc_rx_ready      = 1'b1;
                        rx_protocol_error = 1'b1;
                        rx_abort_fr       = 1'b1;
                        rx_framing_evt    = 1'b1;

                    end

                end

            end

            //=================================================================
            // RX_MAC : NI-internal, never a tile stall (ready = 1)
            //=================================================================

            RX_MAC: begin

                noc_rx_ready = 1'b1;

                if (noc_rx_valid) begin

                    if (rx_mac_legal) begin

                        if (rx_last_mac)
                            rx_mac_valid = 1'b1;

                    end
                    else begin

                        rx_protocol_error = 1'b1;
                        rx_abort_fr       = 1'b1;
                        rx_framing_evt    = 1'b1;

                    end

                end

            end

            //=================================================================
            // RX_DISCARD : consume every flit to the actual terminator
            //=================================================================

            RX_DISCARD: begin

                noc_rx_ready = 1'b1;

                // A HEAD / HEAD_TAIL at k >= 1 is extra framing (F7);
                // it does not end the packet (mirrors the allocator).
                if (noc_rx_valid &&
                    !rx_disc_start_q &&
                    ((noc_rx_flit.flit_type == FLIT_HEAD) ||
                     (noc_rx_flit.flit_type == FLIT_HEAD_TAIL))) begin

                    rx_framing_evt = 1'b1;

                end

            end

            default: begin

                noc_rx_ready = 1'b1;

            end

        endcase

    end

    // Watchdog expiry also aborts (the tile was offered this packet).
    // The expiry abort is REGISTERED (rx_expire_q, the first DISCARD cycle):
    // rx_expire depends combinationally on the tile's rx_ready (through
    // noc_rx_ready), so a combinational abort would create a tile-input ->
    // tile-output path and a loop with any tile whose rx_ready looks at
    // rx_abort. Framing aborts depend only on the flit and stay same-cycle.
    logic rx_expire_q;

    always_ff @(posedge clk) begin
        if (rst) rx_expire_q <= 1'b0;
        else     rx_expire_q <= rx_expire;
    end

    assign rx_abort = rx_abort_fr || rx_expire_q;

    //=========================================================================
    // RX handshake, watchdog, terminator
    //=========================================================================

    assign rx_accept = noc_rx_valid && noc_rx_ready;

    // Tile-induced stall == actual backpressure while responsible
    // (noc_rx_ready is low only when forwarding the tile's rx_ready).
    assign rx_stall =
        rx_responsible &&
        noc_rx_valid &&
        !noc_rx_ready;

    assign rx_expire =
        WD_ENABLE &&
        rx_stall &&
        (wd_cnt_q == WD_W'(WD_LIMIT - 1));

    always_comb begin

        rx_term_acc = 1'b0;

        if (rx_accept) begin

            unique case (rx_state_q)

                RX_IDLE:
                    rx_term_acc =
                        (noc_rx_flit.flit_type == FLIT_HEAD_TAIL);

                RX_DISCARD:
                    rx_term_acc =
                        rx_disc_start_q
                        ? (noc_rx_flit.flit_type == FLIT_HEAD_TAIL)
                        : (noc_rx_flit.flit_type == FLIT_TAIL);

                default:   // RX_PAYLOAD / RX_MAC, k >= 1
                    rx_term_acc =
                        (noc_rx_flit.flit_type == FLIT_TAIL);

            endcase

        end

    end

    // Slot release for a packet whose HEAD was accepted earlier.
    assign rx_do_free =
        rx_term_acc &&
        (rx_state_q != RX_IDLE) &&
        rx_free_q;

    //=========================================================================
    // RX next-state
    //=========================================================================

    always_comb begin

        rx_state_d       = rx_state_q;
        rx_enter_discard = 1'b0;

        unique case (rx_state_q)

            RX_IDLE: begin

                if (rx_expire) begin

                    rx_state_d = RX_DISCARD;         // HEAD still on the wire

                end
                else if (rx_accept && rx_is_head) begin

                    if (rx_head_deliverable) begin

                        rx_state_d =
                            (rx_head_payload_n != 5'd0)
                            ? RX_PAYLOAD
                            : RX_MAC;

                    end
                    else begin

                        rx_state_d       = RX_DISCARD;   // rejected HEAD
                        rx_enter_discard = 1'b1;

                    end

                end
                // HEAD_TAIL (delivered or rejected) and orphans: stay IDLE.

            end

            RX_PAYLOAD: begin

                if (rx_expire) begin

                    rx_state_d = RX_DISCARD;

                end
                else if (rx_accept) begin

                    if (rx_pay_legal) begin

                        if (rx_last_payload)
                            rx_state_d =
                                (MAC_FLITS != 0) ? RX_MAC : RX_IDLE;

                    end
                    else if (rx_term_acc) begin

                        rx_state_d = RX_IDLE;            // F1 premature TAIL

                    end
                    else begin

                        rx_state_d       = RX_DISCARD;   // F2 / F5 / F7
                        rx_enter_discard = 1'b1;

                    end

                end

            end

            RX_MAC: begin

                if (rx_accept) begin

                    if (rx_mac_legal) begin

                        if (rx_last_mac)
                            rx_state_d = RX_IDLE;

                    end
                    else if (rx_term_acc) begin

                        rx_state_d = RX_IDLE;

                    end
                    else begin

                        rx_state_d       = RX_DISCARD;
                        rx_enter_discard = 1'b1;

                    end

                end

            end

            RX_DISCARD: begin

                if (rx_term_acc)
                    rx_state_d = RX_IDLE;

            end

            default: begin

                rx_state_d = RX_IDLE;

            end

        endcase

    end

    //=========================================================================
    // RX registers
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            rx_state_q       <= RX_IDLE;

            rx_src_q         <= '0;
            rx_dest_q        <= '0;

            rx_msg_q         <= MSG_MEM_RD_REQ;

            rx_control_q     <= '0;
            rx_length_q      <= '0;
            rx_vc_q          <= '0;

            rx_payload_n_q   <= '0;
            rx_payload_cnt_q <= '0;

            rx_mac_cnt_q     <= '0;
            rx_mac_tag_q     <= '0;

            rx_disc_start_q  <= 1'b0;
            rx_free_q        <= 1'b0;
            rx_free_tag_q    <= '0;

        end
        else begin

            rx_state_q <= rx_state_d;

            //-----------------------------------------------------------------
            // HEAD accepted in IDLE (delivered or rejected): capture metadata
            // and the slot-release obligation.
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_IDLE) &&
                rx_accept &&
                rx_is_head) begin

                rx_src_q         <= '{x: rx_head.src_x, y: rx_head.src_y};
                rx_dest_q        <= '{x: rx_head.dest_x, y: rx_head.dest_y};
                rx_msg_q         <= rx_head.msg_type;
                rx_control_q     <= rx_head.control.raw;
                rx_length_q      <= rx_head.length;
                rx_vc_q          <= noc_rx_flit.vc_id;
                rx_payload_n_q   <= rx_head_payload_n;
                rx_payload_cnt_q <= '0;
                rx_mac_cnt_q     <= '0;

                rx_free_q        <= rx_head_frees_slot;
                rx_free_tag_q    <= rx_match_slot;

                rx_disc_start_q  <= 1'b0;

            end

            //-----------------------------------------------------------------
            // Watchdog expiry in IDLE: HEAD not yet accepted, still on the
            // wire. Capture metadata for the report and the slot obligation.
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_IDLE) && rx_expire) begin

                rx_src_q         <= '{x: rx_head.src_x, y: rx_head.src_y};
                rx_dest_q        <= '{x: rx_head.dest_x, y: rx_head.dest_y};
                rx_msg_q         <= rx_head.msg_type;
                rx_control_q     <= rx_head.control.raw;
                rx_length_q      <= rx_head.length;
                rx_vc_q          <= noc_rx_flit.vc_id;

                rx_free_q        <= rx_head_frees_slot;
                rx_free_tag_q    <= rx_match_slot;

                rx_disc_start_q  <= 1'b1;

            end

            //-----------------------------------------------------------------
            // Entry into DISCARD from a consumed flit / expiry mid-packet:
            // k >= 1, only TAIL terminates.
            //-----------------------------------------------------------------

            if (rx_enter_discard ||
                ((rx_state_q == RX_PAYLOAD) && rx_expire)) begin

                rx_disc_start_q <= 1'b0;

            end

            //-----------------------------------------------------------------
            // In DISCARD with the HEAD on the wire: once any non-terminating
            // flit is accepted, k >= 1.
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_DISCARD) && rx_accept && !rx_term_acc) begin

                rx_disc_start_q <= 1'b0;

            end

            //-----------------------------------------------------------------
            // Payload counter (legal payload flit accepted)
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_PAYLOAD) &&
                rx_accept &&
                rx_pay_legal) begin

                rx_payload_cnt_q <=
                    rx_payload_cnt_q + 5'd1;

            end

            //-----------------------------------------------------------------
            // MAC capture (legal MAC flit accepted)
            //-----------------------------------------------------------------

            if ((rx_state_q == RX_MAC) &&
                rx_accept &&
                rx_mac_legal) begin

                rx_mac_tag_q[
                    {rx_mac_cnt_q, 5'd0} +: FLIT_WIDTH
                ] <= noc_rx_flit.flit_data;

                rx_mac_cnt_q <=
                    rx_mac_cnt_q + MAC_CNT_WIDTH'(1);

            end

            //-----------------------------------------------------------------
            // Slot obligation cleared once discharged.
            //-----------------------------------------------------------------

            if (rx_do_free)
                rx_free_q <= 1'b0;

        end

    end

    //=========================================================================
    // Watchdog counter (N-8.1 sec.5)
    //   range 0 .. WD_LIMIT-1; per packet, cumulative; holds on valid = 0.
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst)
            wd_cnt_q <= '0;
        else if (rx_expire)
            wd_cnt_q <= '0;
        else if (rx_term_acc || rx_enter_discard)
            wd_cnt_q <= '0;
        else if (rx_stall)
            wd_cnt_q <= wd_cnt_q + WD_W'(1);

    end

    //=========================================================================
    // Persistent report (N-8.1 sec.7, invariant I-N81-RPT)
    //   An event in the same cycle as a clear wins: count becomes 1.
    //=========================================================================

    always_ff @(posedge clk) begin

        if (rst) begin

            ni_contain_sticky <= 1'b0;
            ni_contain_cnt    <= '0;
            ni_contain_info   <= '0;
            ni_framing_sticky <= 1'b0;
            ni_framing_cnt    <= '0;

        end
        else begin

            //------------------------------ containment
            if (rx_expire) begin

                ni_contain_sticky <= 1'b1;

                if (ni_status_clr)
                    ni_contain_cnt <= 8'd1;
                else if (ni_contain_cnt != 8'hFF)
                    ni_contain_cnt <= ni_contain_cnt + 8'd1;

                // First event since the last clear.
                if (!ni_contain_sticky || ni_status_clr) begin

                    if (rx_state_q == RX_IDLE)
                        ni_contain_info <= {rx_head.src_x,
                                            rx_head.src_y,
                                            rx_head.msg_type};
                    else
                        ni_contain_info <= {rx_src_q.x,
                                            rx_src_q.y,
                                            rx_msg_q};

                end

            end
            else if (ni_status_clr) begin

                ni_contain_sticky <= 1'b0;
                ni_contain_cnt    <= '0;
                ni_contain_info   <= '0;

            end

            //------------------------------ framing
            if (rx_framing_evt && rx_accept) begin

                ni_framing_sticky <= 1'b1;

                if (ni_status_clr)
                    ni_framing_cnt <= 8'd1;
                else if (ni_framing_cnt != 8'hFF)
                    ni_framing_cnt <= ni_framing_cnt + 8'd1;

            end
            else if (ni_status_clr) begin

                ni_framing_sticky <= 1'b0;
                ni_framing_cnt    <= '0;

            end

        end

    end

    //=========================================================================
    // Outputs / status
    //=========================================================================

    // MAC tag: on the rx_mac_valid cycle the last MAC word is still on the
    // wire (it is registered at this edge), so overlay it. Before N-8.1 the
    // output was rx_mac_tag_q alone and missed the last word in that cycle.
    always_comb begin

        rx_mac_tag = rx_mac_tag_q;

        if (rx_mac_valid)
            rx_mac_tag[{rx_mac_cnt_q, 5'd0} +: FLIT_WIDTH] =
                noc_rx_flit.flit_data;

    end

    head_flit_t tx_head_on_wire;

    assign tx_head_on_wire =
        head_flit_t'(noc_tx_flit.flit_data);

    assign tx_busy =
        (tx_state_q != TX_IDLE);

    assign rx_busy =
        (rx_state_q != RX_IDLE);

    //=========================================================================
    // Assertions
    //=========================================================================

`ifndef SYNTHESIS
    // synthesis translate_off

    initial begin

        if (WD_LIMIT < 1)
            $fatal(1, "noc_network_interface: WD_LIMIT %0d < 1 (N-8.1 sec.5)", WD_LIMIT);

        for (int m = 0; m < 16; m++) begin
            if (message_payload_flits(msg_type_e'(m)) > TX_BUF_DEPTH)
                $fatal(1, "noc_network_interface: payload of msg %0d exceeds TX_BUF_DEPTH %0d",
                       m, TX_BUF_DEPTH);
        end

        if (!WD_ENABLE)
            $warning("noc_network_interface tile %0d: WD_ENABLE = 0 (negative-control build only)",
                     LOCAL_TILE_ID);

    end

    property p_tx_valid_stable;
        @(posedge clk) disable iff (rst)
        noc_tx_valid && !noc_tx_ready
        |=> noc_tx_valid;
    endproperty

    a_tx_valid_stable:
        assert property (p_tx_valid_stable)
        else $error(
            "M10: noc_tx_valid dropped before transfer completed"
        );

    property p_tx_flit_stable;
        @(posedge clk) disable iff (rst)
        noc_tx_valid && !noc_tx_ready
        |=> $stable(noc_tx_flit);
    endproperty

    a_tx_flit_stable:
        assert property (p_tx_flit_stable)
        else $error(
            "M10: noc_tx_flit changed while stalled"
        );

    // N-8.1: payload is taken from the tile only while filling.
    property p_payload_ready_state;
        @(posedge clk) disable iff (rst)
        tx_payload_ready
        |-> (tx_state_q == TX_FILL);
    endproperty

    a_payload_ready_state:
        assert property (p_payload_ready_state)
        else $error(
            "M10: tx_payload_ready asserted outside TX_FILL"
        );

    // N-8.1 AM-2: from HEAD to terminator the NI never withholds supply.
    property p_tx_no_bubble;
        @(posedge clk) disable iff (rst)
        ((tx_state_q == TX_HEAD) ||
         (tx_state_q == TX_PAYLOAD) ||
         (tx_state_q == TX_MAC))
        |-> noc_tx_valid;
    endproperty

    a_tx_no_bubble:
        assert property (p_tx_no_bubble)
        else $error(
            "M10: TX bubble between HEAD and terminator (AM-2)"
        );

    // N-8.1 AM-4: VC 3 is never emitted.
    property p_tx_vc_legal;
        @(posedge clk) disable iff (rst)
        noc_tx_valid |-> (noc_tx_flit.vc_id != VC_ID_WIDTH'(3));
    endproperty

    a_tx_vc_legal:
        assert property (p_tx_vc_legal)
        else $error(
            "M10: VC 3 emitted (AM-4)"
        );

    // N-8.1 AM-5: a reserved msg_type is never sent.
    property p_tx_msg_legal;
        @(posedge clk) disable iff (rst)
        (noc_tx_valid &&
         ((noc_tx_flit.flit_type == FLIT_HEAD) ||
          (noc_tx_flit.flit_type == FLIT_HEAD_TAIL)))
        |-> !tx_head_on_wire.msg_type[3];
    endproperty

    a_tx_msg_legal:
        assert property (p_tx_msg_legal)
        else $error(
            "M10: reserved msg_type sent (AM-5)"
        );

    property p_vc_constant_in_packet;
        @(posedge clk) disable iff (rst)
        (tx_state_q != TX_IDLE) &&
        (tx_state_d != TX_IDLE)
        |=> $stable(tx_vc);
    endproperty

    a_vc_constant_in_packet:
        assert property (p_vc_constant_in_packet)
        else $error(
            "M10: VC changed between packet flits"
        );

    property p_head_tail_zero_payload;
        @(posedge clk) disable iff (rst)
        (noc_tx_valid &&
         noc_tx_flit.flit_type == FLIT_HEAD_TAIL)
        |-> (tx_payload_n_q == 5'd0) &&
            (MAC_FLITS == 0);
    endproperty

    a_head_tail_zero_payload:
        assert property (p_head_tail_zero_payload)
        else $error(
            "M10: illegal HEAD_TAIL packet generated"
        );

    property p_no_deliver_and_drop;
        @(posedge clk) disable iff (rst)
        rx_protocol_error
        |-> !(rx_head_valid || rx_payload_valid);
    endproperty

    a_no_deliver_and_drop:
        assert property (p_no_deliver_and_drop)
        else $error(
            "M10: packet simultaneously delivered and rejected"
        );

    property p_error_flit_consumed;
        @(posedge clk) disable iff (rst)
        (rx_protocol_error || rx_length_error)
        |-> noc_rx_ready;
    endproperty

    a_error_flit_consumed:
        assert property (p_error_flit_consumed)
        else $error(
            "M10: protocol error stalled the NoC"
        );

    // N-8.1 sec.5: noc_rx_ready is low only while forwarding the tile.
    property p_ready_low_only_for_tile;
        @(posedge clk) disable iff (rst)
        noc_rx_valid && !noc_rx_ready
        |-> rx_responsible && !rx_ready;
    endproperty

    a_ready_low_only_for_tile:
        assert property (p_ready_low_only_for_tile)
        else $error(
            "M10: noc_rx_ready low without tile backpressure (N-8.1 sec.5)"
        );

    // N-8.1 sec.5: counter range 0 .. WD_LIMIT-1.
    property p_wd_range;
        @(posedge clk) disable iff (rst)
        int'(wd_cnt_q) < WD_LIMIT;
    endproperty

    a_wd_range:
        assert property (p_wd_range)
        else $error(
            "M10: watchdog counter out of range (N-8.1 sec.5)"
        );

    // N-8.1 sec.6: DISCARD always consumes.
    property p_discard_ready;
        @(posedge clk) disable iff (rst)
        (rx_state_q == RX_DISCARD) |-> noc_rx_ready;
    endproperty

    a_discard_ready:
        assert property (p_discard_ready)
        else $error(
            "M10: RX_DISCARD not consuming (N-8.1 sec.6)"
        );

    // N-8.1 sec.2 environment assumption: the router holds a presented flit
    // stable until it is accepted (router SVA a_local_out_flit_hold).
    property p_rx_flit_hold;
        @(posedge clk) disable iff (rst)
        noc_rx_valid && !noc_rx_ready
        |=> noc_rx_valid && $stable(noc_rx_flit);
    endproperty

    a_rx_flit_hold:
        assert property (p_rx_flit_hold)
        else $error(
            "M10: upstream dropped or changed a stalled RX flit"
        );

    property p_src_is_local;
        @(posedge clk) disable iff (rst)
        (noc_tx_valid &&
         ((noc_tx_flit.flit_type == FLIT_HEAD) ||
          (noc_tx_flit.flit_type == FLIT_HEAD_TAIL)))
        |-> (tx_head_on_wire.src_x == LOCAL_COORD.x) &&
            (tx_head_on_wire.src_y == LOCAL_COORD.y);
    endproperty

    a_src_is_local:
        assert property (p_src_is_local)
        else $error(
            "M10: injected foreign source coordinate"
        );

    property p_outstanding_bounded;
        @(posedge clk) disable iff (rst)
        $countones(txn_valid_q) <= N_OUTSTANDING;
    endproperty

    a_outstanding_bounded:
        assert property (p_outstanding_bounded)
        else $error(
            "M10: outstanding transaction count exceeded N_OUTSTANDING"
        );

    property p_no_slot_blocks_mem_request;
        @(posedge clk) disable iff (rst)
        (tx_state_q == TX_IDLE) &&
        !tx_slot_available &&
        ((tx_msg_type == MSG_MEM_RD_REQ) ||
         (tx_msg_type == MSG_MEM_WR_REQ))
        |-> !tx_ready;
    endproperty

    a_no_slot_blocks_mem_request:
        assert property (p_no_slot_blocks_mem_request)
        else $error(
            "M10: accepted memory request with no outstanding slot"
        );

    generate
        for (genvar g = 0; g < N_OUTSTANDING; g++) begin : GEN_TXN_ASSERT

            property p_valid_slot_response_type;
                @(posedge clk) disable iff (rst)
                txn_valid_q[g]
                |->
                ((txn_resp_type_q[g] == MSG_MEM_RD_RESP) ||
                 (txn_resp_type_q[g] == MSG_MEM_WR_RESP));
            endproperty

            a_valid_slot_response_type:
                assert property (p_valid_slot_response_type)
                else $error(
                    "M10: invalid expected response type in slot %0d",
                    g
                );

        end
    endgenerate

    property p_matched_response_has_valid_slot;
        @(posedge clk) disable iff (rst)
        rx_response_match
        |-> txn_valid_q[rx_match_slot];
    endproperty

    a_matched_response_has_valid_slot:
        assert property (p_matched_response_has_valid_slot)
        else $error(
            "M10: response matched an invalid transaction slot"
        );

    property p_matched_response_source;
        @(posedge clk) disable iff (rst)
        rx_response_match
        |->
        (rx_head.src_x == txn_dest_q[rx_match_slot].x) &&
        (rx_head.src_y == txn_dest_q[rx_match_slot].y);
    endproperty

    a_matched_response_source:
        assert property (p_matched_response_source)
        else $error(
            "M10: matched response source does not match request destination"
        );

    property p_matched_response_type;
        @(posedge clk) disable iff (rst)
        rx_response_match
        |->
        (rx_head.msg_type ==
         txn_resp_type_q[rx_match_slot]);
    endproperty

    a_matched_response_type:
        assert property (p_matched_response_type)
        else $error(
            "M10: matched response type is incorrect"
        );

    // synthesis translate_on
`endif

endmodule
