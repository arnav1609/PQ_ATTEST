`timescale 1ns/1ps

module pq_kdf_message_builder
    import pq_kdf_pkg::*;
(
    input  logic [TILE_ID_ENCODED_BITS-1:0]
        encoded_tile_id,

    input  logic [EPOCH_ENCODED_BITS-1:0]
        encoded_epoch,

    input  logic [CONTEXT_ENCODED_BITS-1:0]
        encoded_context,

    input  logic [CONTEXT_LEN_BITS-1:0]
        context_len,

    output logic [KDF_MESSAGE_MAX_BITS-1:0]
        kdf_message,

    output logic [5:0]
        kdf_message_len
);

    integer i;

    always_comb begin

        // --------------------------------------------------------
        // Default output
        // --------------------------------------------------------

        kdf_message     = '0;
        kdf_message_len = 6'd0;


        // --------------------------------------------------------
        // TILE_ID
        //
        // encoded_tile_id[7:0]   = first encoded byte
        // encoded_tile_id[15:8]  = second encoded byte
        // ...
        //
        // Copy into KDF message beginning at byte 0.
        // --------------------------------------------------------

        for (i = 0; i < TILE_ID_ENCODED_BYTES; i = i + 1) begin

            kdf_message[i*8 +: 8] =
                encoded_tile_id[i*8 +: 8];

        end


        // --------------------------------------------------------
        // EPOCH
        //
        // Starts immediately after the 10-byte encoded TILE_ID.
        // --------------------------------------------------------

        for (i = 0; i < EPOCH_ENCODED_BYTES; i = i + 1) begin

            kdf_message[
                (TILE_ID_ENCODED_BYTES + i)*8 +: 8
            ] =
                encoded_epoch[i*8 +: 8];

        end


        // --------------------------------------------------------
        // CONTEXT
        //
        // Valid encoded context length:
        //
        //     2 + context_len
        //
        // Only those bytes are copied.
        // --------------------------------------------------------

        for (i = 0; i < CONTEXT_ENCODED_BYTES; i = i + 1) begin

            if (i < (2 + context_len)) begin

                kdf_message[
                    (TILE_ID_ENCODED_BYTES +
                     EPOCH_ENCODED_BYTES +
                     i)*8 +: 8
                ] =
                    encoded_context[i*8 +: 8];

            end

        end


        // --------------------------------------------------------
        // Total valid message length
        //
        // 10-byte TILE_ID
        // + 12-byte EPOCH
        // + 2-byte context encoding
        // + context data
        // --------------------------------------------------------

        kdf_message_len =
            TILE_ID_ENCODED_BYTES +
            EPOCH_ENCODED_BYTES +
            2 +
            context_len;

    end

endmodule