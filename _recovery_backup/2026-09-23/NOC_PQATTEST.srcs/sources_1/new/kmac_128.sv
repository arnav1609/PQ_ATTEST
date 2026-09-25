`timescale 1ns/1ps

module kmac128
    import keccak_pkg::*;
    import kmac_pkg::TAG_BITS;
    import kmac_pkg::KMAC_DOMAIN;
#(
    parameter int KEY_BYTES    = 32,
    parameter int CUSTOM_BYTES = 16,
    parameter int MSG_BYTES    = 16
)(
    input logic clk,
    input logic rst_n,

    // ============================================================
    // INPUTS
    // ============================================================

    input logic start,

    input logic [KEY_BYTES*8-1:0] key_in,
    input logic [$clog2(KEY_BYTES+1)-1:0] key_len,

    input logic [CUSTOM_BYTES*8-1:0] custom_in,
    input logic [$clog2(CUSTOM_BYTES+1)-1:0] custom_len,

    input logic [MSG_BYTES*8-1:0] msg_in,
    input logic [$clog2(MSG_BYTES+1)-1:0] msg_len,

    // Requested output length: kmac_pkg::KMAC_L_128 / KMAC_L_256.
    // tag_out is always 256 bits wide; for L=128 only tag_out[127:0]
    // is the answer, and it is the answer because right_encode(128)
    // was ABSORBED - not because a 256-bit result was truncated.
    input logic out_len_sel,

    // ============================================================
    // OUTPUTS
    // ============================================================

    output logic [TAG_BITS-1:0] tag_out,
    output logic                busy,
    output logic                done
);

    // ============================================================
    // KMAC128 PARAMETERS
    //
    // KMAC128 / cSHAKE128:
    //
    //     Rate     = 1344 bits
    //              = 168 bytes
    //
    //     Capacity = 256 bits
    // ============================================================

    localparam int RATE_BITS  = 1344;
    localparam int RATE_BYTES = 168;

    // ============================================================
    // INTERNAL FSM
    // ============================================================

    typedef enum logic [3:0] {

        KMAC_IDLE       = 4'b0000,
        KMAC_ENC_START  = 4'b0001,

        KMAC_BLOCK0     = 4'b0010,
        KMAC_PERMUTE0   = 4'b0011,

        KMAC_BLOCK1     = 4'b0100,
        KMAC_PERMUTE1   = 4'b0101,

        KMAC_BLOCK2     = 4'b0110,
        KMAC_PERMUTE2   = 4'b0111,

        KMAC_SQUEEZE    = 4'b1000,
        KMAC_DONE       = 4'b1001

    } kmac_ctrl_state_e;

    kmac_ctrl_state_e ctrl_state;

    // ============================================================
    // LATCHED INPUTS
    // ============================================================

    logic [KEY_BYTES*8-1:0] key_reg;

    logic [$clog2(KEY_BYTES+1)-1:0]
        key_len_reg;

    logic [CUSTOM_BYTES*8-1:0] custom_reg;

    logic [$clog2(CUSTOM_BYTES+1)-1:0]
        custom_len_reg;

    logic [MSG_BYTES*8-1:0] msg_reg;

    logic [$clog2(MSG_BYTES+1)-1:0]
        msg_len_reg;

    logic out_len_sel_reg;

    // ============================================================
    // ENCODER INTERFACE
    // ============================================================

    logic encoder_start;

    logic [RATE_BYTES-1:0][7:0] encoded_block;

    logic encoder_valid;
    logic encoder_ready;
    logic encoder_last;

    logic encoder_busy;
    logic encoder_done;

    // ============================================================
    // BLOCK SIGNALS
    // ============================================================

    logic [RATE_BITS-1:0] raw_block;
    logic [RATE_BITS-1:0] final_block;
    logic [RATE_BITS-1:0] absorb_block;

    logic absorb_en;

    // ============================================================
    // KECCAK STATE
    // ============================================================

    state_t state_reg;
    state_t absorbed_state;

    // ============================================================
    // KECCAK CONTROL
    // ============================================================

    logic keccak_start;
    logic keccak_busy;
    logic keccak_done;

    state_t keccak_state_in;
    state_t keccak_state_out;

    // ============================================================
    // RAW ENCODED BLOCK
    //
    // Convert encoder's byte array into the packed
    // 1344-bit Keccak absorption block.
    // ============================================================

    always_comb begin

        raw_block = '0;

        for (int i = 0; i < RATE_BYTES; i++) begin

            raw_block[i*8 +: 8] =
                encoded_block[i];

        end

    end

    // ============================================================
    // FINAL BLOCK
    //
    // Encoder Block 2 contains:
    //
    //     X || right_encode(256) || zeros
    //
    // right_encode(256):
    //
    //     01 00 02
    //
    // KMAC/cSHAKE domain suffix:
    //
    //     04
    //
    // pad10*1 final bit:
    //
    //     MSB of final rate byte = 1
    // ============================================================

    always_comb begin

        final_block = raw_block;

        // The domain byte follows right_encode(L), whose length
        // depends on L:  2 bytes for L=128, 3 bytes for L=256.
        final_block[(msg_len_reg +
                     (out_len_sel_reg == kmac_pkg::KMAC_L_256 ? 3 : 2))*8 +: 8] =
            KMAC_DOMAIN;

        final_block[(RATE_BYTES-1)*8 + 7] =
            1'b1;

    end

    // ============================================================
    // SELECT BLOCK
    // ============================================================

    always_comb begin

        if (ctrl_state == KMAC_BLOCK2)
            absorb_block = final_block;
        else
            absorb_block = raw_block;

    end

    // ============================================================
    // ENCODER START
    // ============================================================

    assign encoder_start =
        (ctrl_state == KMAC_ENC_START);

    // ============================================================
    // ENCODER READY
    //
    // A block can be consumed only when:
    //
    //   1. Controller is in BLOCK0/BLOCK1/BLOCK2
    //   2. Keccak is idle
    //
    // This preserves the verified block/Keccak handshake.
    // ============================================================

    assign encoder_ready =
        (
            (ctrl_state == KMAC_BLOCK0) ||
            (ctrl_state == KMAC_BLOCK1) ||
            (ctrl_state == KMAC_BLOCK2)
        )
        &&
        !keccak_busy;

    // ============================================================
    // ABSORB ENABLE
    // ============================================================

    assign absorb_en =
        encoder_valid &&
        encoder_ready;

    // ============================================================
    // ABSORBER
    // ============================================================

    kmac_absorb u_kmac_absorb (

        .state_in  (state_reg),
        .block_in  (absorb_block),
        .absorb_en (absorb_en),
        .state_out (absorbed_state)

    );

    // ============================================================
    // KECCAK INPUT
    // ============================================================

    assign keccak_state_in =
        absorbed_state;

    // ============================================================
    // KECCAK START
    //
    // Exactly the same condition as absorb_en.
    //
    // Therefore the state given to Keccak is exactly:
    //
    //     current_state XOR current_block
    // ============================================================

    assign keccak_start =
        encoder_valid &&
        encoder_ready;

    // ============================================================
    // ENCODER
    // ============================================================

    kmac_encode #(
        .KEY_BYTES    (KEY_BYTES),
        .CUSTOM_BYTES (CUSTOM_BYTES),
        .MSG_BYTES    (MSG_BYTES)
    ) u_kmac_encode (

        .clk         (clk),
        .rst_n       (rst_n),

        .start       (encoder_start),

        .key_in      (key_reg),
        .key_len     (key_len_reg),

        .custom_in   (custom_reg),
        .custom_len  (custom_len_reg),

        .msg_in      (msg_reg),
        .msg_len     (msg_len_reg),

        .out_len_sel (out_len_sel_reg),

        .block_data  (encoded_block),

        .block_valid (encoder_valid),
        .block_ready (encoder_ready),

        .block_last  (encoder_last),

        .busy        (encoder_busy),
        .done        (encoder_done)

    );

    // ============================================================
    // KECCAK-f[1600]
    //
    // Current project version uses active-high "rst".
    // ============================================================

    keccak_f1600 u_keccak (

        .clk       (clk),
        .rst       (~rst_n),

        .start     (keccak_start),

        .state_in  (keccak_state_in),

        .state_out (keccak_state_out),

        .busy      (keccak_busy),
        .done      (keccak_done)

    );

    // ============================================================
    // MAIN FSM
    // ============================================================

    always_ff @(posedge clk) begin

        if (!rst_n) begin

            ctrl_state <= KMAC_IDLE;

            key_reg     <= '0;
            key_len_reg <= '0;

            custom_reg     <= '0;
            custom_len_reg <= '0;

            msg_reg     <= '0;
            msg_len_reg <= '0;

            out_len_sel_reg <= 1'b0;

            tag_out <= '0;

            for (int x = 0; x < STATE_DIM; x++) begin

                for (int y = 0; y < STATE_DIM; y++) begin

                    state_reg[x][y] <= '0;

                end

            end

        end

        else begin

            case (ctrl_state)

                // =================================================
                // IDLE
                // =================================================

                KMAC_IDLE: begin

                    if (start) begin

                        key_reg     <= key_in;
                        key_len_reg <= key_len;

                        custom_reg     <= custom_in;
                        custom_len_reg <= custom_len;

                        msg_reg     <= msg_in;
                        msg_len_reg <= msg_len;

                        out_len_sel_reg <= out_len_sel;

                        for (int x = 0; x < STATE_DIM; x++) begin

                            for (int y = 0; y < STATE_DIM; y++) begin

                                state_reg[x][y] <= '0;

                            end

                        end

                        ctrl_state <= KMAC_ENC_START;

                    end

                end

                // =================================================
                // START ENCODER
                // =================================================

                KMAC_ENC_START: begin

                    ctrl_state <= KMAC_BLOCK0;

                end

                // =================================================
                // BLOCK 0
                // =================================================

                KMAC_BLOCK0: begin

                    if (encoder_valid && encoder_ready) begin

                        ctrl_state <= KMAC_PERMUTE0;

                    end

                end

                // =================================================
                // PERMUTE BLOCK 0
                // =================================================

                KMAC_PERMUTE0: begin

                    if (keccak_done) begin

                        state_reg <= keccak_state_out;

                        ctrl_state <= KMAC_BLOCK1;

                    end

                end

                // =================================================
                // BLOCK 1
                // =================================================

                KMAC_BLOCK1: begin

                    if (encoder_valid && encoder_ready) begin

                        ctrl_state <= KMAC_PERMUTE1;

                    end

                end

                // =================================================
                // PERMUTE BLOCK 1
                // =================================================

                KMAC_PERMUTE1: begin

                    if (keccak_done) begin

                        state_reg <= keccak_state_out;

                        ctrl_state <= KMAC_BLOCK2;

                    end

                end

                // =================================================
                // BLOCK 2
                // =================================================

                KMAC_BLOCK2: begin

                    if (encoder_valid && encoder_ready) begin

                        ctrl_state <= KMAC_PERMUTE2;

                    end

                end

                // =================================================
                // FINAL PERMUTATION
                // =================================================

                KMAC_PERMUTE2: begin

                    if (keccak_done) begin

                        state_reg <= keccak_state_out;

                        ctrl_state <= KMAC_SQUEEZE;

                    end

                end

                // =================================================
                // SQUEEZE
                //
                // KMAC128 output requested:
                //
                //     L = 256 bits
                //
                // First four 64-bit lanes of the rate portion
                // provide the complete 256-bit result.
                //
                // IMPORTANT:
                // Serialize bytes explicitly so that:
                //
                //   byte 0  = state_reg[0][0][7:0]
                //   byte 1  = state_reg[0][0][15:8]
                //   ...
                //
                // This matches the byte-oriented Python KMAC
                // reference representation.
                // =================================================

                KMAC_SQUEEZE: begin

                    for (int i = 0; i < 32; i++) begin

                        tag_out[i*8 +: 8] <=
                            state_reg[i/8][0][(i%8)*8 +: 8];

                    end

                    ctrl_state <= KMAC_DONE;

                end

                // =================================================
                // DONE
                // =================================================

                KMAC_DONE: begin

                    ctrl_state <= KMAC_IDLE;

                end

                // =================================================
                // SAFETY
                // =================================================

                default: begin

                    ctrl_state <= KMAC_IDLE;

                    for (int x = 0; x < STATE_DIM; x++) begin

                        for (int y = 0; y < STATE_DIM; y++) begin

                            state_reg[x][y] <= '0;

                        end

                    end

                end

            endcase

        end

    end

    // ============================================================
    // STATUS
    // ============================================================

    assign busy =
        (ctrl_state != KMAC_IDLE) &&
        (ctrl_state != KMAC_DONE);

    assign done =
        (ctrl_state == KMAC_DONE);

endmodule