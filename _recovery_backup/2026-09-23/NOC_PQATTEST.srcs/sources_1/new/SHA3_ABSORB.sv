module sha3_absorb
    import keccak_pkg::*;
    import sha3_pkg::*;
(
    input  state_t                    state_in,
    input  logic [RATE_BITS-1:0]      block_in,

    output state_t                    state_out
);

    // ========================================================================
    // SHA3-256 Absorption
    //
    // RATE = 1088 bits = 136 bytes = 17 × 64-bit lanes
    //
    // Each 64-bit lane is formed from 8 consecutive input bytes using
    // little-endian byte ordering, matching the Python reference model.
    //
    // The resulting 17 lanes are XORed into the rate portion of the
    // 1600-bit Keccak state.
    //
    // The remaining 8 lanes (512-bit capacity) are unchanged.
    // ========================================================================


    // ========================================================================
    // Combinational absorption
    // ========================================================================

    always_comb begin

        // --------------------------------------------------------------------
        // Default:
        //
        // Preserve the complete 1600-bit state.
        //
        // This automatically preserves the 512-bit capacity portion.
        // --------------------------------------------------------------------

        state_out = state_in;


        // --------------------------------------------------------------------
        // Absorb 17 rate lanes.
        //
        // Each iteration:
        //
        //   1. Extract 8 bytes from the 136-byte block.
        //   2. Interpret them as a little-endian 64-bit lane.
        //   3. XOR that lane into the corresponding Keccak state lane.
        //
        // Python equivalent:
        //
        //   lane = int.from_bytes(chunk, "little")
        //   state[x][y] ^= lane
        // --------------------------------------------------------------------

        for (int i = 0; i < RATE_LANES; i++) begin

            state_out[i % STATE_DIM][i / STATE_DIM] =
                state_in[i % STATE_DIM][i / STATE_DIM]
                ^ block_in[i*LANE_WIDTH +: LANE_WIDTH];

        end

    end

endmodule