`timescale 1ns/1ps
module keccak_chi
    import keccak_pkg::*;
(
    input  state_t state_in,
    output state_t state_out
);

    // ------------------------------------------------------------
    // Chi transformation
    //
    // A'[x][y] =
    //     A[x][y] ^
    //     ((~A[x+1][y]) & A[x+2][y])
    //
    // The x coordinate wraps around 0 -> 4.
    // ------------------------------------------------------------

    always_comb begin

        for (int x = 0; x < STATE_DIM; x++) begin
            for (int y = 0; y < STATE_DIM; y++) begin

                state_out[x][y] =
                    state_in[x][y] ^
                    (
                        (~state_in[
                            (x == 4) ? 0 : (x + 1)
                        ][y])
                        &
                        state_in[
                            (x >= 3) ? (x - 3) : (x + 2)
                        ][y]
                    );

            end
        end

    end

endmodule