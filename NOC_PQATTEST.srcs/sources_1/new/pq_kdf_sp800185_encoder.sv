`timescale 1ns/1ps

module pq_kdf_sp800185_encoder
    import pq_kdf_pkg::*;
(
    // ============================================================
    // INPUTS
    // ============================================================

    input logic [TILE_ID_BITS-1:0]
        tile_id,

    input logic [EPOCH_BITS-1:0]
        epoch,

    input logic [CONTEXT_MAX_BITS-1:0]
        context,

    input logic [CONTEXT_LEN_BITS-1:0]
        context_len,


    // ============================================================
    // OUTPUTS
    // ============================================================

    output logic [TILE_ID_ENCODED_BITS-1:0]
        encoded_tile_id,

    output logic [EPOCH_ENCODED_BITS-1:0]
        encoded_epoch,

    output logic [CONTEXT_ENCODED_BITS-1:0]
        encoded_context,

    output logic [4:0]
        encoded_context_len
);


    // ============================================================
    // COMBINATIONAL ENCODER
    // ============================================================

    always_comb begin

        // --------------------------------------------------------
        // Defaults
        // --------------------------------------------------------

        encoded_tile_id     = '0;
        encoded_epoch       = '0;
        encoded_context     = '0;

        encoded_context_len = 5'd2;


        // ========================================================
        // TILE ID
        //
        // len = 7 bytes = 56 bits
        //
        // left_encode(56)
        //
        //     01 38
        //
        // followed by 7 data bytes.
        // ========================================================

        encoded_tile_id[7:0]  = 8'h01;
        encoded_tile_id[15:8] = 8'h38;

        for (int i = 0; i < TILE_ID_BYTES; i++) begin

            encoded_tile_id[(i + 2)*8 +: 8] =
                tile_id[i*8 +: 8];

        end


        // ========================================================
        // EPOCH
        //
        // len = 10 bytes = 80 bits
        //
        // left_encode(80)
        //
        //     01 50
        //
        // followed by 10 data bytes.
        // ========================================================

        encoded_epoch[7:0]  = 8'h01;
        encoded_epoch[15:8] = 8'h50;

        for (int i = 0; i < EPOCH_BYTES; i++) begin

            encoded_epoch[(i + 2)*8 +: 8] =
                epoch[i*8 +: 8];

        end


        // ========================================================
        // CONTEXT
        //
        // context_len = number of valid bytes.
        //
        // left_encode(context_len * 8)
        //
        // Supported range = 0..14 bytes.
        // ========================================================

        encoded_context[7:0] = 8'h01;

        case (context_len)

            4'd0:  encoded_context[15:8] = 8'h00;
            4'd1:  encoded_context[15:8] = 8'h08;
            4'd2:  encoded_context[15:8] = 8'h10;
            4'd3:  encoded_context[15:8] = 8'h18;
            4'd4:  encoded_context[15:8] = 8'h20;
            4'd5:  encoded_context[15:8] = 8'h28;
            4'd6:  encoded_context[15:8] = 8'h30;
            4'd7:  encoded_context[15:8] = 8'h38;
            4'd8:  encoded_context[15:8] = 8'h40;
            4'd9:  encoded_context[15:8] = 8'h48;
            4'd10: encoded_context[15:8] = 8'h50;
            4'd11: encoded_context[15:8] = 8'h58;
            4'd12: encoded_context[15:8] = 8'h60;
            4'd13: encoded_context[15:8] = 8'h68;
            4'd14: encoded_context[15:8] = 8'h70;

            default:
                encoded_context[15:8] = 8'h00;

        endcase


        // --------------------------------------------------------
        // Copy context bytes.
        //
        // Unused bytes remain zero.
        // --------------------------------------------------------

        for (int i = 0; i < CONTEXT_MAX_BYTES; i++) begin

            if (i < context_len) begin

                encoded_context[(i + 2)*8 +: 8] =
                    context[i*8 +: 8];

            end
            else begin

                encoded_context[(i + 2)*8 +: 8] =
                    8'h00;

            end

        end


        // --------------------------------------------------------
        // Actual encoded context length
        //
        // 2-byte length encoding + context bytes
        // --------------------------------------------------------

        if (context_len <= CONTEXT_MAX_BYTES)

            encoded_context_len =
                5'd2 + context_len;

        else

            encoded_context_len = 5'd2;

    end

endmodule