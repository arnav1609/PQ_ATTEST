//=============================================================================
// File   : pq_kdf.sv
// Module : pq_kdf   (PQ-Attest Stage 5 - tile-key KDF)
// Project: PQ-Attest
//
// Reproduces derive_tile_key() from software/kmac128_ref.py:
//
//     kdf_message = encode_string(tile_id)
//                 + encode_string(epoch)
//                 + encode_string(context)
//
//     return kmac128(key            = root_secret,
//                    message        = kdf_message,
//                    output_bytes   = key_bytes,
//                    customization  = b"")
//
//-----------------------------------------------------------------------------
// TWO THINGS THAT ARE EASY TO GET BACKWARDS
//
//  1. customization is EMPTY.
//     The context string goes into the MESSAGE, not the customization field.
//     Stage 7 (attestation) does the opposite - it sets customization to
//     "PQ-ATTEST-AUTH". Wiring that here fails all six KDF vectors
//     identically, which is the hardest failure mode to diagnose because
//     nothing looks partially right.
//
//  2. right_encode(L) is KMAC's job, not ours.
//     kmac_encode appends it in block 2. Do NOT append it here - that
//     produces  X || right_encode(L) || right_encode(L)  and every vector
//     fails. (This is what pq_kdf_block_formatter.sv was doing; that module
//     has been removed.)
//
//-----------------------------------------------------------------------------
// OUTPUT LENGTH IS NOT TRUNCATION
//
// In KMAC, L is absorbed as right_encode(L), so:
//
//     KMAC128(K, X, 128)  !=  KMAC128(K, X, 256)[0:16]
//
// Verified against kmac128_ref.py with the V01 inputs:
//     L=128            -> 9c699e785af03e632e2da3cbe9ede27c   (V01 golden)
//     L=256 truncated  -> f3d22e09c5b0ba3b0e5a7c85ab7703fc   (V06 prefix)
//
// tag_out is always 256 bits wide. For L=128 only tag_out[127:0] is the
// answer, and it IS the answer only because right_encode(128) was absorbed.
//
//-----------------------------------------------------------------------------
// BYTE ORDER
//
// Matches kmac_encode: byte i lives at [i*8 +: 8].
//
// KDF message layout (byte index):
//     [0]       0x01            left_encode(56) length byte
//     [1]       0x38            56  = 7 bytes * 8
//     [2..8]    TILE_ID
//     [9]       0x01            left_encode(80) length byte
//     [10]      0x50            80  = 10 bytes * 8
//     [11..20]  EPOCH
//     [21]      0x01            left_encode(8*context_len) length byte
//     [22]      context_len*8   always one byte: 8*len <= 112 < 256
//     [23..]    CONTEXT
//
//   total = 23 + context_len   (23 .. 37 bytes)
//
// encode_string(TILE_ID) and encode_string(EPOCH) are compile-time constants
// because both fields are fixed length, which is why no separate encoder
// module is needed - the whole SP 800-185 encoding here is twelve lines.
//
// Target : xc7a100tcsg324-1, Vivado 2024.1
//=============================================================================

`timescale 1ns/1ps

module pq_kdf
    import pq_kdf_pkg::*;
    import kmac_pkg::*;
(
    input  logic clk,
    input  logic rst_n,                         // ACTIVE LOW, matching kmac128

    input  logic                         start,
    input  logic [ROOT_SECRET_BITS-1:0]  root_secret,
    input  logic [TILE_ID_BITS-1:0]      tile_id,
    input  logic [EPOCH_BITS-1:0]        epoch,
    input  logic [CONTEXT_MAX_BITS-1:0]  context_in,    // 'context' is a reserved SV keyword
    input  logic [CONTEXT_LEN_BITS-1:0]  context_len,   // 0 .. 14
    input  logic [1:0]                   key_len_sel,   // KDF_LEN_128 / KDF_LEN_256

    output logic [KDF_KEY_MAX_BITS-1:0]  derived_key,
    output logic [5:0]                   derived_key_bytes,
    output logic                         busy,
    output logic                         done
);

    // Must not exceed kmac_pkg::MAX_MSG_BYTES.
    localparam int MSG_BYTES_KDF = 40;

    //-------------------------------------------------------------------------
    // Latched request
    //-------------------------------------------------------------------------
    logic [ROOT_SECRET_BITS-1:0] root_q;
    logic [TILE_ID_BITS-1:0]     tile_q;
    logic [EPOCH_BITS-1:0]       epoch_q;
    logic [CONTEXT_MAX_BITS-1:0] ctx_q;
    logic [CONTEXT_LEN_BITS-1:0] ctx_len_q;
    logic [1:0]                  key_sel_q;

    //-------------------------------------------------------------------------
    // KDF message construction - pure combinational.
    //
    // encode_string(S) = left_encode(8*len(S)) || S, and for every field here
    // 8*len(S) <= 112 < 256, so left_encode is always exactly two bytes:
    // 0x01 (one length byte) followed by the bit count.
    //-------------------------------------------------------------------------
    logic [MSG_BYTES_KDF*8-1:0]         kdf_msg;
    logic [$clog2(MSG_BYTES_KDF+1)-1:0] kdf_msg_len;

    always_comb begin
        kdf_msg = '0;

        // encode_string(TILE_ID) : 01 38 || tile_id       -> bytes 0..8
        kdf_msg[0*8 +: 8] = 8'h01;
        kdf_msg[1*8 +: 8] = 8'd56;                         // 7 * 8
        for (int i = 0; i < TILE_ID_BYTES; i++)
            kdf_msg[(2 + i)*8 +: 8] = tile_q[i*8 +: 8];

        // encode_string(EPOCH)   : 01 50 || epoch         -> bytes 9..20
        kdf_msg[9*8  +: 8] = 8'h01;
        kdf_msg[10*8 +: 8] = 8'd80;                        // 10 * 8
        for (int i = 0; i < EPOCH_BYTES; i++)
            kdf_msg[(11 + i)*8 +: 8] = epoch_q[i*8 +: 8];

        // encode_string(CONTEXT) : 01 <8*len> || context  -> bytes 21..
        //
        // context_len == 0 is legal and gives exactly 01 00, which is what
        // KDF vector V05 (empty context) requires.
        kdf_msg[21*8 +: 8] = 8'h01;

        // left_encode(8 * context_len). context_len <= 14, so 8*len <= 112
        // and this is always exactly one value byte.
        kdf_msg[22*8 +: 8] = {1'b0, ctx_len_q, 3'b000};    // context_len * 8

        for (int i = 0; i < CONTEXT_MAX_BYTES; i++)
            if (i < int'(ctx_len_q))
                kdf_msg[(23 + i)*8 +: 8] = ctx_q[i*8 +: 8];

        kdf_msg_len = 6'd23 + ctx_len_q;
    end

    //-------------------------------------------------------------------------
    // Control FSM
    //
    // The message path above is combinational, so there is nothing to
    // sequence except the KMAC handshake.
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_KMAC = 2'd1,        // one-cycle start pulse to kmac128
        S_WAIT = 2'd2,        // waiting for kmac_done
        S_DONE = 2'd3
    } state_e;

    state_e state_q, state_d;

    logic         kmac_start;
    logic [255:0] kmac_tag;
    logic         kmac_busy;
    logic         kmac_done;

    always_comb begin
        state_d    = state_q;
        kmac_start = 1'b0;

        unique case (state_q)

            S_IDLE: if (start) state_d = S_KMAC;

            S_KMAC: begin
                kmac_start = 1'b1;
                state_d    = S_WAIT;
            end

            S_WAIT: if (kmac_done) state_d = S_DONE;

            S_DONE: state_d = S_IDLE;

            default: state_d = S_IDLE;

        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin
            state_q     <= S_IDLE;
            root_q      <= '0;
            tile_q      <= '0;
            epoch_q     <= '0;
            ctx_q       <= '0;
            ctx_len_q   <= '0;
            key_sel_q   <= '0;
            derived_key <= '0;
        end

        else begin
            state_q <= state_d;

            // Latch the whole request on accept. A start pulse while busy is
            // ignored: state_q != S_IDLE means this branch cannot fire, and
            // the in-progress operation is untouched.
            if (state_q == S_IDLE && start) begin
                root_q    <= root_secret;
                tile_q    <= tile_id;
                epoch_q   <= epoch;
                ctx_q     <= context_in;
                ctx_len_q <= context_len;
                key_sel_q <= key_len_sel;
            end

            // Capture the tag. For L=128 only the first 16 bytes are the
            // answer - see the header note on why this is not truncation.
            if (state_q == S_WAIT && kmac_done) begin
                if (key_sel_q == KDF_LEN_256)
                    derived_key <= kmac_tag;
                else
                    derived_key <= {128'b0, kmac_tag[127:0]};
            end
        end
    end

    assign busy              = (state_q != S_IDLE);
    assign done              = (state_q == S_DONE);
    assign derived_key_bytes = (key_sel_q == KDF_LEN_256) ? 6'd32 : 6'd16;

    //-------------------------------------------------------------------------
    // KMAC128 - reused, not reimplemented.
    //
    // customization is EMPTY. See the header note.
    //-------------------------------------------------------------------------
    kmac128 #(
        .KEY_BYTES    (ROOT_SECRET_BYTES),      // 32
        .CUSTOM_BYTES (16),
        .MSG_BYTES    (MSG_BYTES_KDF)           // 40
    ) u_kmac (

        .clk          (clk),
        .rst_n        (rst_n),
        .start        (kmac_start),

        .key_in       (root_q),
        .key_len      (6'd32),                  // $clog2(32+1) = 6 bits

        .custom_in    ('0),
        .custom_len   ('0),

        .msg_in       (kdf_msg),
        .msg_len      (kdf_msg_len),

        .out_len_sel  ((key_sel_q == KDF_LEN_256) ? KMAC_L_256 : KMAC_L_128),

        .tag_out      (kmac_tag),
        .busy         (kmac_busy),
        .done         (kmac_done)

    );

endmodule
