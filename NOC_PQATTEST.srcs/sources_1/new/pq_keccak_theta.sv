`timescale 1ns/1ps
module keccak_theta
    import keccak_pkg::*;
(
    input  state_t state_in,
    output state_t state_out
);

    // ------------------------------------------------------------
    // Column parity
    //
    // C[x] = A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4]
    // ------------------------------------------------------------

    lane_t C [0:STATE_DIM-1];

    // ------------------------------------------------------------
    // Theta correction
    //
    // D[x] = C[x-1] ^ ROTL64(C[x+1], 1)
    // ------------------------------------------------------------

    lane_t D [0:STATE_DIM-1];


    always_comb begin

        // --------------------------------------------------------
        // Step 1: Calculate column parities
        // --------------------------------------------------------

        for (int x = 0; x < STATE_DIM; x++) begin
            C[x] = state_in[x][0] ^
                   state_in[x][1] ^
                   state_in[x][2] ^
                   state_in[x][3] ^
                   state_in[x][4];
        end


        // --------------------------------------------------------
        // Step 2: Calculate D[x]
        //
        // Explicit wraparound:
        //
        // x = 0 → x-1 = 4
        // x = 4 → x+1 = 0
        // --------------------------------------------------------

        for (int x = 0; x < STATE_DIM; x++) begin
            D[x] = C[(x == 0) ? 4 : (x - 1)] ^
                   rotl64(
                       C[(x == 4) ? 0 : (x + 1)],
                       1
                   );
        end


        // --------------------------------------------------------
        // Step 3: Apply Theta
        //
        // A'[x][y] = A[x][y] ^ D[x]
        // --------------------------------------------------------

        for (int x = 0; x < STATE_DIM; x++) begin
            for (int y = 0; y < STATE_DIM; y++) begin
                state_out[x][y] = state_in[x][y] ^ D[x];
            end
        end

    end

endmodule