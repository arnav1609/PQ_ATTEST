//=============================================================================
// PQ-Attest  -  Stage 7  -  pq_attestation_tag
//
//   TAG = KMAC128( tile_key,
//                  TILE_ID || EPOCH || NONCE || MEASUREMENT,
//                  "PQ-ATTEST-AUTH",
//                  L )
//
// WHAT THIS MODULE IS
//   A tag-generation primitive. It contains NO cryptography. Every Keccak,
//   cSHAKE and KMAC operation happens inside the Stage 3 kmac128 instance
//   below, which is reused verbatim, not reimplemented. cSHAKE128 is not a
//   module in this project - it is kmac_encode's ENC_BLOCK0.
//
// WHAT THIS MODULE IS NOT
//   Not a key derivation (Stage 5). Not a measurement engine (Stage 6). Not a
//   nonce generator - the nonce is an INPUT, produced by TRNG_TOP.nonce_out
//   (TRNG_PKG::NONCE_BITS = 128) on the RoT side. Keeping nonce generation out
//   is what makes this module deterministic and independently testable.
//   Not packetisation, not a replay database, not the SoC attestation FSM.
//
//-----------------------------------------------------------------------------
// PROTOCOL CONTRACT - FROZEN, AND FROZEN AGAINST THE FILES ON DISK
//-----------------------------------------------------------------------------
//
//   reset : SYNCHRONOUS, active low.
//           kmac_128.sv:349 is always_ff @(posedge clk) with if (!rst_n)
//           inside - no negedge rst_n in the sensitivity list. sha3_256 and
//           pq_measurement are synchronous too. Stage 7 drives kmac128, so it
//           matches its child: parent and child cannot then disagree about
//           the cycle on which reset is released.
//           OPEN ITEM: pq_kdf.sv:191 uses an ASYNCHRONOUS reset. It is the
//           only module in the crypto lane that does.
//
//   busy  : LOW on the done cycle.
//           kmac_128.sv:593  assign busy = (ctrl_state != KMAC_IDLE) &&
//                                          (ctrl_state != KMAC_DONE);
//           pq_measurement uses the same convention and is the module that
//           passed 33/0. Stage 7 matches both.
//           OPEN ITEM: pq_kdf.sv:230 uses busy = (state_q != S_IDLE), i.e.
//           busy HIGH on done. A consumer of BOTH modules cannot gate on
//           !busy the same way. That mismatch belongs in OPEN.md.
//
//   done  : a REGISTER, pulsing for one cycle while state_q is already
//           S_IDLE - exactly as in pq_measurement. Consequence: the next
//           start IS accepted on the done cycle. busy is LOW on that cycle,
//           so a consumer gating on !busy is correct here.
//
//   err   : pulses with done when a request was REJECTED. On that pulse
//           tag = 0 and tag_bytes = 0. A consumer MUST check err, not done
//           alone. err is never asserted for an accepted request.
//
// BYTE ORDER
//   byte i at [i*8 +: 8], uniform with kmac128 / pq_kdf / pq_measurement.
//
// Target : xc7a100tcsg324-1, Vivado 2024.1
//=============================================================================

`timescale 1ns/1ps

module pq_attestation_tag
    import pq_attest_pkg::*;
    import kmac_pkg::*;
(
    input  logic clk,
    input  logic rst_n,                          // ACTIVE LOW, SYNCHRONOUS

    // One-cycle pulse. A start while busy is ignored and the in-flight
    // request is untouched - see the S_IDLE latch below.
    input  logic start,

    input  logic [TILE_KEY_BITS-1:0]     tile_key,     // Stage 5 derived_key
    input  logic [TILE_ID_BITS-1:0]      tile_id,
    input  logic [EPOCH_BITS-1:0]        epoch,
    input  logic [NONCE_BITS-1:0]        nonce,        // TRNG_TOP.nonce_out
    input  logic [MEASUREMENT_BITS-1:0]  measurement,  // Stage 6 measurement

    // TAG_LEN_128 / TAG_LEN_256 only. Anything else is REJECTED.
    input  logic [1:0]                   tag_len_sel,

    // For L=128 only tag[127:0] is the answer. Absorbed, not truncated.
    output logic [TAG_MAX_BITS-1:0]      tag,
    output logic [5:0]                   tag_bytes,
    output logic                         busy,
    output logic                         done,
    output logic                         err           // pulses with done
);

    //-------------------------------------------------------------------------
    // Latched request
    //-------------------------------------------------------------------------
    logic [TILE_KEY_BITS-1:0]    key_q;
    logic [TILE_ID_BITS-1:0]     tile_q;
    logic [EPOCH_BITS-1:0]       epoch_q;
    logic [NONCE_BITS-1:0]       nonce_q;
    logic [MEASUREMENT_BITS-1:0] meas_q;
    logic [1:0]                  len_sel_q;
    logic                        len_ok_q;

    //-------------------------------------------------------------------------
    // Accept-time validation, on the LIVE input.
    //
    // Without this, 2'b10 and 2'b11 fall through the else of a two-way compare
    // and silently produce a 128-bit tag. Malformed control must not select a
    // valid cryptographic mode. Same shape as pq_measurement's req_len_ok.
    //-------------------------------------------------------------------------
    logic req_len_sel_ok;

    always_comb begin
        req_len_sel_ok = (tag_len_sel == TAG_LEN_128) ||
                         (tag_len_sel == TAG_LEN_256);
    end

    //-------------------------------------------------------------------------
    // Transcript - pure combinational, built from the LATCHED copies.
    //
    // Four fixed-offset slice assignments. No running offset, no accumulated
    // length, no loop: every field is constant width, so there is no address
    // arithmetic that can be wrong. Deliberately simpler than pq_measurement's
    // message builder, which has to handle variable lengths.
    //-------------------------------------------------------------------------
    logic [TAG_MSG_BITS-1:0]  tag_msg;
    logic [TAG_MSG_LEN_W-1:0] tag_msg_len;

    always_comb begin
        tag_msg = '0;
        tag_msg[TILE_OFF  * 8 +: TILE_ID_BITS    ] = tile_q;
        tag_msg[EPOCH_OFF * 8 +: EPOCH_BITS      ] = epoch_q;
        tag_msg[NONCE_OFF * 8 +: NONCE_BITS      ] = nonce_q;
        tag_msg[MEAS_OFF  * 8 +: MEASUREMENT_BITS] = meas_q;
    end

    // Constant. The transcript is always the full 65 bytes.
    assign tag_msg_len = TAG_MSG_BYTES;

    //-------------------------------------------------------------------------
    // kmac128 length fields.
    //
    // Each width equals the corresponding port width computed INSIDE kmac128
    // from its parameters (kmac_128.sv:21-28):
    //     key_len     $clog2(TILE_KEY_BYTES    + 1) = $clog2(33) = 6
    //     custom_len  $clog2(KMAC_CUSTOM_BYTES + 1) = $clog2(17) = 5
    //     msg_len     $clog2(TAG_MSG_BYTES     + 1) = $clog2(66) = 7
    //-------------------------------------------------------------------------
    logic [TILE_KEY_LEN_W-1:0]    kmac_key_len;
    logic [KMAC_CUSTOM_LEN_W-1:0] kmac_custom_len;

    assign kmac_key_len    = TILE_KEY_BYTES;      // 32
    assign kmac_custom_len = AUTH_CUSTOM_BYTES;   // 14

    // 16-byte customization field, 14 bytes used. Bytes 14 and 15 are zero
    // padding and are not absorbed - custom_len bounds the encoder's copy loop.
    logic [KMAC_CUSTOM_BYTES*8-1:0] kmac_custom_in;
    assign kmac_custom_in = { {(KMAC_CUSTOM_BYTES*8 - AUTH_CUSTOM_BITS){1'b0}},
                              AUTH_CUSTOM };

    //-------------------------------------------------------------------------
    // Control FSM
    //
    // Single always_ff with a registered child-start pulse and registered
    // done/err - the pq_measurement shape, which is the most recently
    // verified control style in this project (33 checks / 0 errors).
    //-------------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE = 3'd0,
        S_KMAC = 3'd1,      // one-cycle start pulse to kmac128
        S_WAIT = 3'd2,
        S_DONE = 3'd3,
        S_ERR  = 3'd4       // request rejected; completes the handshake
    } state_e;

    state_e state_q;

    logic                    kmac_start_q;
    logic [TAG_MAX_BITS-1:0] kmac_tag;
    logic                    kmac_busy;
    logic                    kmac_done;

    assign busy = (state_q == S_KMAC) || (state_q == S_WAIT);

    // tag_bytes reads 0 on a rejected request so a consumer that ignores err
    // still cannot mistake zeros for a real tag.
    assign tag_bytes = (!len_ok_q)                 ? 6'd0  :
                       (len_sel_q == TAG_LEN_256)  ? 6'd32 :
                                                     6'd16;

    always_ff @(posedge clk) begin

        if (!rst_n) begin
            state_q      <= S_IDLE;

            key_q        <= '0;
            tile_q       <= '0;
            epoch_q      <= '0;
            nonce_q      <= '0;
            meas_q       <= '0;
            len_sel_q    <= '0;
            len_ok_q     <= 1'b0;

            kmac_start_q <= 1'b0;
            tag          <= '0;
            done         <= 1'b0;
            err          <= 1'b0;
        end

        else begin

            // Defaults. ALL NON-BLOCKING. Mixing = and <= on one variable
            // inside one always_ff is illegal per IEEE 1800 and xvlog
            // rejects it.
            kmac_start_q <= 1'b0;
            done         <= 1'b0;
            err          <= 1'b0;

            case (state_q)

                //-------------------------------------------------------------
                // Accept. A start while busy cannot reach here, so an
                // in-flight request is untouched.
                //-------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        key_q     <= tile_key;
                        tile_q    <= tile_id;
                        epoch_q   <= epoch;
                        nonce_q   <= nonce;
                        meas_q    <= measurement;
                        len_sel_q <= tag_len_sel;
                        len_ok_q  <= req_len_sel_ok;

                        if (req_len_sel_ok) state_q <= S_KMAC;
                        else                state_q <= S_ERR;
                    end
                end

                S_KMAC: begin
                    kmac_start_q <= 1'b1;
                    state_q      <= S_WAIT;
                end

                S_WAIT: begin
                    if (kmac_done) begin
                        // For L=128 only the low 16 bytes are the answer; the
                        // upper half is zeroed so a consumer cannot read stale
                        // bits as tag material.
                        if (len_sel_q == TAG_LEN_256)
                            tag <= kmac_tag;
                        else
                            tag <= { {(TAG_MAX_BITS-128){1'b0}}, kmac_tag[127:0] };

                        state_q <= S_DONE;
                    end
                end

                S_DONE: begin
                    done    <= 1'b1;
                    state_q <= S_IDLE;
                end

                //-------------------------------------------------------------
                // Rejected request. The handshake still COMPLETES - a consumer
                // waiting on done must never hang because its control field
                // was malformed. tag is forced to zero.
                //-------------------------------------------------------------
                S_ERR: begin
                    tag     <= '0;
                    done    <= 1'b1;
                    err     <= 1'b1;
                    state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;

            endcase
        end
    end

    //-------------------------------------------------------------------------
    // KMAC128 - Stage 3, reused, not reimplemented.
    //
    // Identical to pq_kdf.sv:240-272 except for exactly three overrides:
    //     MSG_BYTES   40 -> 65          (the transcript is longer)
    //     custom_in   '0 -> AUTH_CUSTOM (Stage 7 has a customization)
    //     custom_len   0 -> 14
    //
    // Port names and widths transcribed from kmac_128.sv:12-42 as read from
    // disk, not from memory. out_len_sel is present in that file (6 uses)
    // and is load-bearing: it picks right_encode(L) in kmac_encode:435-447
    // and moves the domain byte in kmac_128:187-190. Leaving it unconnected
    // makes it float to 'z and corrupts every tag while the block and
    // permutation counts stay correct.
    //-------------------------------------------------------------------------
    kmac128 #(
        .KEY_BYTES    (TILE_KEY_BYTES),      // 32
        .CUSTOM_BYTES (KMAC_CUSTOM_BYTES),   // 16
        .MSG_BYTES    (TAG_MSG_BYTES)        // 65
    ) u_kmac (

        .clk          (clk),
        .rst_n        (rst_n),
        .start        (kmac_start_q),

        .key_in       (key_q),
        .key_len      (kmac_key_len),

        .custom_in    (kmac_custom_in),
        .custom_len   (kmac_custom_len),

        .msg_in       (tag_msg),
        .msg_len      (tag_msg_len),

        .out_len_sel  ((len_sel_q == TAG_LEN_256) ? KMAC_L_256 : KMAC_L_128),

        .tag_out      (kmac_tag),
        .busy         (kmac_busy),
        .done         (kmac_done)

    );

    //-------------------------------------------------------------------------
    // Simulation-only overlap check.
    //
    // kmac_busy is otherwise unused: the parent FSM owns the handshake, so it
    // is not needed functionally. This catches a start pulse issued into a
    // busy KMAC, which would silently discard the new request.
    //
    // Deliberately a PROCEDURAL check and not `assert property`. In this
    // project, SVA on NOC_ARBITER produced 405 failures whose own printed
    // operands satisfied the properties. Until that is understood, a plain
    // always_ff with $error is the more trustworthy detector.
    //-------------------------------------------------------------------------
    // synthesis translate_off
    always_ff @(posedge clk) begin
        if (rst_n && kmac_start_q && kmac_busy) begin
            $error("pq_attestation_tag: kmac start asserted while kmac128 busy");
        end
    end
    // synthesis translate_on

endmodule