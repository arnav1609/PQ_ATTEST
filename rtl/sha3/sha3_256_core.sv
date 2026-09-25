`timescale 1ns/1ps

// ============================================================
// SHA3-256 MULTI-BLOCK CORE
//
// Supports messages from 0 to 272 bytes.
//
// message_block[7:0]       = byte 0
// message_block[15:8]      = byte 1
// ...
//
// First 136 bytes:
//   message_block[1087:0]
//
// Second 136 bytes:
//   message_block[2175:1088]
//
// message_len:
//   0 ... 272 bytes
//
// SHA3-256 rate = 1088 bits = 136 bytes
// SHA3 suffix  = 0x06
// ============================================================

module sha3_256_core (

    input  logic          clk,
    input  logic          rst,
    input  logic          start,

    input  logic [2175:0] message_block,
    input  logic [8:0]    message_len,

    output logic [255:0]  digest,
    output logic          busy,
    output logic          done

);

    localparam integer RATE_BITS  = 1088;
    localparam integer RATE_BYTES = 136;

    localparam logic [7:0] SHA3_SUFFIX = 8'h06;

    // --------------------------------------------------------
    // FSM
    // --------------------------------------------------------

    typedef enum logic [2:0] {
        S_IDLE,
        S_ABSORB,
        S_KECCAK,
        S_SQUEEZE,
        S_DONE
    } sha_state_t;

    sha_state_t state;

    // --------------------------------------------------------
    // Sponge state
    // --------------------------------------------------------

    logic [1599:0] sponge_state;

    // 0 = first block
    // 1 = second block

    logic block_index;

    // 1 or 2 blocks

    logic [1:0] total_blocks;

    // --------------------------------------------------------
    // Keccak interface
    // --------------------------------------------------------

    logic [1599:0] keccak_input;
    logic [1599:0] keccak_output;

    logic keccak_start;
    logic keccak_busy;
    logic keccak_done;

    // --------------------------------------------------------
    // Current padded rate block
    // --------------------------------------------------------

    logic [1087:0] padded_block;

    integer i;
    integer byte_index;
    integer base_byte;
    integer remaining_bytes;

    // --------------------------------------------------------
    // Keccak instance
    // --------------------------------------------------------

    keccak_f1600_core keccak_inst (

        .clk       (clk),
        .rst       (rst),

        .start     (keccak_start),
        .state_in  (keccak_input),

        .state_out (keccak_output),

        .busy      (keccak_busy),
        .done      (keccak_done)

    );

    // --------------------------------------------------------
    // Calculate number of blocks
    //
    // IMPORTANT:
    //
    // 0..135 bytes  -> 1 block
    // 136..272      -> 2 blocks
    //
    // 136 bytes MUST use a second padding block.
    // --------------------------------------------------------

    always @* begin

        if (message_len < RATE_BYTES)
            total_blocks = 2'd1;
        else
            total_blocks = 2'd2;

    end

    // --------------------------------------------------------
    // Build current 1088-bit block
    // --------------------------------------------------------

    always @* begin

        padded_block = 1088'b0;

        base_byte = block_index * RATE_BYTES;

        // ----------------------------------------------------
        // Copy message bytes belonging to this block
        // ----------------------------------------------------

        for (i = 0; i < RATE_BYTES; i = i + 1) begin

            byte_index = base_byte + i;

            if (byte_index < message_len) begin

                padded_block[i*8 +: 8] =
                    message_block[byte_index*8 +: 8];

            end

        end

        // ----------------------------------------------------
        // Padding ONLY on the final block
        // ----------------------------------------------------

        if (block_index == total_blocks - 1) begin

            remaining_bytes =
                message_len - base_byte;

            // ------------------------------------------------
            // SHA3 domain separation suffix
            // ------------------------------------------------

            padded_block[remaining_bytes*8 +: 8] =
                SHA3_SUFFIX;

            // ------------------------------------------------
            // Final bit
            //
            // Equivalent to OR-ing 0x80 into final byte.
            // ------------------------------------------------

            padded_block[1087] = 1'b1;

        end

    end

    // --------------------------------------------------------
    // Sponge absorption input
    // --------------------------------------------------------

    always @* begin

        keccak_input = sponge_state;

        for (i = 0; i < RATE_BITS; i = i + 1) begin

            keccak_input[i] =
                sponge_state[i] ^
                padded_block[i];

        end

    end

    // --------------------------------------------------------
    // Start Keccak during absorb state
    // --------------------------------------------------------

    always @* begin

        if (state == S_ABSORB)
            keccak_start = 1'b1;
        else
            keccak_start = 1'b0;

    end

    // --------------------------------------------------------
    // SHA3 FSM
    // --------------------------------------------------------

    always_ff @(posedge clk) begin

        if (rst) begin

            state        <= S_IDLE;
            sponge_state <= 1600'b0;

            block_index  <= 1'b0;

            digest       <= 256'b0;

            busy         <= 1'b0;
            done         <= 1'b0;

        end

        else begin

            done <= 1'b0;

            case (state)

                // =================================================
                // IDLE
                // =================================================

                S_IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        // New message
                        sponge_state <= 1600'b0;

                        // Begin with block 0
                        block_index <= 1'b0;

                        busy <= 1'b1;

                        state <= S_ABSORB;

                    end

                end


                // =================================================
                // ABSORB
                // =================================================

                S_ABSORB: begin

                    // keccak_start is HIGH during this state.
                    //
                    // keccak_input =
                    //
                    //     sponge_state XOR padded_block
                    //

                    state <= S_KECCAK;

                end


                // =================================================
                // KECCAK
                // =================================================

                S_KECCAK: begin

                    if (keccak_done) begin

                        // Update sponge state
                        sponge_state <= keccak_output;

                        // ------------------------------------------------
                        // If this was the final block, squeeze.
                        // ------------------------------------------------

                        if (block_index == total_blocks - 1) begin

                            state <= S_SQUEEZE;

                        end

                        // ------------------------------------------------
                        // Otherwise absorb next block.
                        // ------------------------------------------------

                        else begin

                            block_index <= block_index + 1'b1;

                            state <= S_ABSORB;

                        end

                    end

                end


                // =================================================
                // SQUEEZE
                // =================================================

                S_SQUEEZE: begin

                    // ------------------------------------------------
                    // First 256 bits of Keccak state.
                    //
                    // Internal Keccak byte ordering is little-endian
                    // within each lane. Convert to conventional SHA3
                    // hexadecimal digest ordering.
                    // ------------------------------------------------

                    digest[255:248] <= sponge_state[7:0];
                    digest[247:240] <= sponge_state[15:8];
                    digest[239:232] <= sponge_state[23:16];
                    digest[231:224] <= sponge_state[31:24];

                    digest[223:216] <= sponge_state[39:32];
                    digest[215:208] <= sponge_state[47:40];
                    digest[207:200] <= sponge_state[55:48];
                    digest[199:192] <= sponge_state[63:56];

                    digest[191:184] <= sponge_state[71:64];
                    digest[183:176] <= sponge_state[79:72];
                    digest[175:168] <= sponge_state[87:80];
                    digest[167:160] <= sponge_state[95:88];

                    digest[159:152] <= sponge_state[103:96];
                    digest[151:144] <= sponge_state[111:104];
                    digest[143:136] <= sponge_state[119:112];
                    digest[135:128] <= sponge_state[127:120];

                    digest[127:120] <= sponge_state[135:128];
                    digest[119:112] <= sponge_state[143:136];
                    digest[111:104] <= sponge_state[151:144];
                    digest[103:96]  <= sponge_state[159:152];

                    digest[95:88]   <= sponge_state[167:160];
                    digest[87:80]   <= sponge_state[175:168];
                    digest[79:72]   <= sponge_state[183:176];
                    digest[71:64]   <= sponge_state[191:184];

                    digest[63:56]   <= sponge_state[199:192];
                    digest[55:48]   <= sponge_state[207:200];
                    digest[47:40]   <= sponge_state[215:208];
                    digest[39:32]   <= sponge_state[223:216];

                    digest[31:24]   <= sponge_state[231:224];
                    digest[23:16]   <= sponge_state[239:232];
                    digest[15:8]    <= sponge_state[247:240];
                    digest[7:0]     <= sponge_state[255:248];

                    state <= S_DONE;

                end


                // =================================================
                // DONE
                // =================================================

                S_DONE: begin

                    done <= 1'b1;
                    busy <= 1'b0;

                    state <= S_IDLE;

                end


                // =================================================
                // DEFAULT
                // =================================================

                default: begin

                    state <= S_IDLE;

                    busy <= 1'b0;
                    done <= 1'b0;

                end

            endcase

        end

    end

endmodule
