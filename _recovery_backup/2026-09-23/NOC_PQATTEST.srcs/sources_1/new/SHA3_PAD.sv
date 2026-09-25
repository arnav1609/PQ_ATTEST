module sha3_pad
    import sha3_pkg::*;
(
    input  logic [RATE_BYTES*8-1:0] msg_block_in,
    input  logic [$clog2(RATE_BYTES+1)-1:0] valid_bytes,
    input  logic                       is_final,

    output logic [RATE_BYTES*8-1:0] padded_block
);

    always_comb begin

        padded_block = msg_block_in;

        if (is_final) begin

            if (valid_bytes < RATE_BYTES) begin

                for (int i = valid_bytes; i < RATE_BYTES; i++) begin
                    padded_block[i*8 +: 8] = 8'h00;
                end

                padded_block[valid_bytes*8 +: 8] =
                    SHA3_DOMAIN;

                padded_block[(RATE_BYTES-1)*8 + 7] =
                    1'b1;

            end

        end

    end

endmodule