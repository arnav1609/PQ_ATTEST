`timescale 1ns/1ps

module trng_pad
(
    input  logic [6:0] word_index,

    output logic [63:0] pad_word
);

    always_comb begin

        pad_word = 64'h0000_0000_0000_0000;

        case (word_index)

            // 512-byte raw entropy = words 0..63
            // Padding starts at word 64.

            7'd64:
                pad_word =
                    64'h0000_0000_0000_0001;

            7'd65:
                pad_word =
                    64'h0000_0000_0000_0000;

            7'd66:
                pad_word =
                    64'h0000_0000_0000_0000;

            7'd67:
                pad_word =
                    64'h8000_0000_0000_0000;

            default:
                pad_word =
                    64'h0000_0000_0000_0000;

        endcase

    end

endmodule