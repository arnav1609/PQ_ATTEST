`timescale 1ns/1ps

module kmac_encode #(
    parameter int KEY_BYTES    = 32,
    parameter int CUSTOM_BYTES = 16,
    parameter int MSG_BYTES    = 16
)(
    input  logic clk,
    input  logic rst_n,

    // Start a new KMAC encoding transaction
    input  logic start,

    // Key
    input  logic [KEY_BYTES*8-1:0] key_in,
    input  logic [$clog2(KEY_BYTES+1)-1:0] key_len,

    // Customization string S
    input  logic [CUSTOM_BYTES*8-1:0] custom_in,
    input  logic [$clog2(CUSTOM_BYTES+1)-1:0] custom_len,

    // Message X
    input  logic [MSG_BYTES*8-1:0] msg_in,
    input  logic [$clog2(MSG_BYTES+1)-1:0] msg_len,

    // Requested KMAC output length: kmac_pkg::KMAC_L_128 / KMAC_L_256.
    // Selects right_encode(L) in block 2. NOT a truncation control.
    input  logic out_len_sel,

    // Encoded 168-byte block
    output logic [167:0][7:0] block_data,

    // Block handshake
    output logic block_valid,
    input  logic block_ready,

    // Last encoded block indicator
    output logic block_last,

    // Encoder status
    output logic busy,
    output logic done
);

    // ============================================================
    // KMAC128 parameters
    // ============================================================

    localparam int RATE_BYTES = 168;

    // Number of encoded blocks:
    //   Block 0 = cSHAKE function-name/customization prefix
    //   Block 1 = bytepad(encode_string(K))
    //   Block 2 = message + right_encode(L)
    localparam int NUM_BLOCKS = 3;

    typedef enum logic [2:0] {
        ENC_IDLE  = 3'b000,
        ENC_BLOCK0 = 3'b001,
        ENC_BLOCK1 = 3'b010,
        ENC_BLOCK2 = 3'b011,
        ENC_DONE   = 3'b100
    } enc_state_e;

    enc_state_e state;

    // ============================================================
    // Latched inputs
    // ============================================================

    logic [KEY_BYTES*8-1:0]    key_reg;
    logic [CUSTOM_BYTES*8-1:0] custom_reg;
    logic [MSG_BYTES*8-1:0]    msg_reg;

    logic [$clog2(KEY_BYTES+1)-1:0]    key_len_reg;
    logic [$clog2(CUSTOM_BYTES+1)-1:0] custom_len_reg;
    logic [$clog2(MSG_BYTES+1)-1:0]    msg_len_reg;

    logic out_len_sel_reg;

    // ============================================================
    // Sequential controller
    // ============================================================

    always_ff @(posedge clk) begin

        if (!rst_n) begin

            state <= ENC_IDLE;

            key_reg        <= '0;
            custom_reg     <= '0;
            msg_reg        <= '0;

            key_len_reg    <= '0;
            custom_len_reg <= '0;
            msg_len_reg    <= '0;

            out_len_sel_reg <= 1'b0;

        end

        else begin

            case (state)

                // ------------------------------------------------
                // IDLE
                // ------------------------------------------------

                ENC_IDLE: begin

                    if (start) begin

                        key_reg        <= key_in;
                        custom_reg     <= custom_in;
                        msg_reg        <= msg_in;

                        key_len_reg    <= key_len;
                        custom_len_reg <= custom_len;
                        msg_len_reg    <= msg_len;

                        out_len_sel_reg <= out_len_sel;

                        state <= ENC_BLOCK0;

                    end

                end


                // ------------------------------------------------
                // BLOCK 0
                // ------------------------------------------------
                //
                // bytepad(
                //     encode_string("KMAC") ||
                //     encode_string(S),
                //     168
                // )
                //
                // left_encode(168) = 01 A8
                //
                // encode_string("KMAC"):
                //     left_encode(32) = 01 20
                //     "KMAC"         = 4B 4D 41 43
                //
                // ------------------------------------------------

                ENC_BLOCK0: begin

                    if (block_valid && block_ready) begin
                        state <= ENC_BLOCK1;
                    end

                end


                // ------------------------------------------------
                // BLOCK 1
                // ------------------------------------------------
                //
                // bytepad(
                //     encode_string(K),
                //     168
                // )
                //
                // left_encode(168) = 01 A8
                //
                // encode_string(K):
                //     left_encode(key_len * 8)
                //     key bytes
                //
                // ------------------------------------------------

                ENC_BLOCK1: begin

                    if (block_valid && block_ready) begin
                        state <= ENC_BLOCK2;
                    end

                end


                // ------------------------------------------------
                // BLOCK 2
                // ------------------------------------------------
                //
                // X || right_encode(L)
                //
                // L = 256 bits
                //
                // right_encode(256):
                //     01 00 02
                //
                // ------------------------------------------------

                ENC_BLOCK2: begin

                    if (block_valid && block_ready) begin
                        state <= ENC_DONE;
                    end

                end


                // ------------------------------------------------
                // DONE
                // ------------------------------------------------

                ENC_DONE: begin
                    state <= ENC_IDLE;
                end


                default: begin
                    state <= ENC_IDLE;
                end

            endcase

        end

    end


    // ============================================================
    // Combinational block generation
    // ============================================================

    always_comb begin

        // Defaults
        block_data  = '0;
        block_valid = 1'b0;
        block_last  = 1'b0;

        case (state)

            // ====================================================
            // BLOCK 0
            // ====================================================

            ENC_BLOCK0: begin

                block_valid = 1'b1;
                block_last  = 1'b0;

                // --------------------------------------------
                // byte 0-1:
                // left_encode(168)
                //
                // 168 decimal = 0xA8
                // --------------------------------------------

                block_data[0] = 8'h01;
                block_data[1] = 8'hA8;


                // --------------------------------------------
                // encode_string("KMAC")
                //
                // left_encode(32) = 01 20
                // --------------------------------------------

                block_data[2] = 8'h01;
                block_data[3] = 8'h20;

                block_data[4] = 8'h4B; // K
                block_data[5] = 8'h4D; // M
                block_data[6] = 8'h41; // A
                block_data[7] = 8'h43; // C


                // --------------------------------------------
                // encode_string(S)
                //
                // S length is in bits.
                //
                // For S <= 16 bytes:
                // left_encode(S_bits) is:
                //
                //   S_bits <= 255:
                //       01 XX
                //
                //   S_bits >= 256:
                //       02 XX XX
                //
                // Since max S = 16 bytes = 128 bits,
                // only the first case is required.
                // --------------------------------------------

                block_data[8] = 8'h01;
                block_data[9] = custom_len_reg * 8;


                // --------------------------------------------
                // Copy customization bytes
                // --------------------------------------------

                for (int i = 0; i < CUSTOM_BYTES; i++) begin

                    if (i < custom_len_reg) begin

                        block_data[10 + i] =
                            custom_reg[i*8 +: 8];

                    end

                end

                // Remaining bytes are already zero.
            end


            // ====================================================
            // BLOCK 1
            // ====================================================

            ENC_BLOCK1: begin

                block_valid = 1'b1;
                block_last  = 1'b0;

                // --------------------------------------------
                // bytepad prefix
                //
                // left_encode(168) = 01 A8
                // --------------------------------------------

                block_data[0] = 8'h01;
                block_data[1] = 8'hA8;


                // --------------------------------------------
                // encode_string(K)
                //
                // key_len <= 32 bytes
                //
                // Maximum:
                //
                // key_len = 32 bytes
                // key_bits = 256
                //
                // left_encode(256)
                //     = 02 01 00
                // --------------------------------------------

                if ((key_len_reg * 8) < 256) begin

                    block_data[2] = 8'h01;
                    block_data[3] = key_len_reg * 8;

                    // Key begins at byte 4
                    for (int i = 0; i < KEY_BYTES; i++) begin

                        if (i < key_len_reg) begin

                            block_data[4 + i] =
                                key_reg[i*8 +: 8];

                        end

                    end

                end

                else begin

                    // left_encode(256) = 02 01 00

                    block_data[2] = 8'h02;
                    block_data[3] = 8'h01;
                    block_data[4] = 8'h00;

                    // Key begins at byte 5
                    for (int i = 0; i < KEY_BYTES; i++) begin

                        if (i < key_len_reg) begin

                            block_data[5 + i] =
                                key_reg[i*8 +: 8];

                        end

                    end

                end

            end


            // ====================================================
            // BLOCK 2
            // ====================================================

            ENC_BLOCK2: begin

                block_valid = 1'b1;
                block_last  = 1'b1;

                // --------------------------------------------
                // Message X
                // --------------------------------------------

                for (int i = 0; i < MSG_BYTES; i++) begin

                    if (i < msg_len_reg) begin

                        block_data[i] =
                            msg_reg[i*8 +: 8];

                    end

                end


                // --------------------------------------------
                // right_encode(L)
                //
                // Value first, length last.
                //
                // L = 256:
                //     256 = 0x0100, encoded in 2 bytes
                //     right_encode(256) = 01 00 02     (3 bytes)
                //
                // L = 128:
                //     128 = 0x80, encoded in 1 byte
                //     right_encode(128) = 80 01        (2 bytes)
                //
                // The lengths differ, so the KMAC domain byte that
                // kmac128 writes immediately after this also moves.
                // --------------------------------------------

                if (out_len_sel_reg == kmac_pkg::KMAC_L_256) begin

                    block_data[msg_len_reg + 0] = 8'h01;
                    block_data[msg_len_reg + 1] = 8'h00;
                    block_data[msg_len_reg + 2] = 8'h02;

                end
                else begin

                    block_data[msg_len_reg + 0] = 8'h80;
                    block_data[msg_len_reg + 1] = 8'h01;

                end

            end


            default: begin
                block_data  = '0;
                block_valid = 1'b0;
                block_last  = 1'b0;
            end

        endcase

    end


    // ============================================================
    // Status
    // ============================================================

    assign busy =
        (state != ENC_IDLE) &&
        (state != ENC_DONE);

    assign done =
        (state == ENC_DONE);

endmodule