`timescale 1ns/1ps

module kmac_absorb
    import keccak_pkg::*;
    import kmac_pkg::*;
(
    input  state_t              state_in,
    input  logic [RATE_BITS-1:0] block_in,
    input  logic                absorb_en,

    output state_t              state_out
);

    // ============================================================
    // KMAC128
    //
    // Rate     = 1344 bits
    // Rate     = 21 × 64-bit lanes
    // Capacity = 256 bits
    //
    // Only the rate portion is XORed with the input block.
    // ============================================================

    always_comb begin

        // Preserve entire state by default.
        state_out = state_in;


        if (absorb_en) begin

            for (int i = 0; i < RATE_LANES; i++) begin

                state_out[i % STATE_DIM][i / STATE_DIM] =
                    state_in[i % STATE_DIM][i / STATE_DIM]
                    ^
                    block_in[i*LANE_WIDTH +: LANE_WIDTH];

            end

        end

    end

endmodule