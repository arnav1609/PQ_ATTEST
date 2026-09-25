`timescale 1ns/1ps
module keccak_rho
    import keccak_pkg::*;
(
    input  state_t state_in,
    output state_t state_out
);

    // ------------------------------------------------------------
    // Rho transformation
    //
    // B[x][y] = ROTL64(A[x][y], ROTATION_OFFSETS[x][y])
    // ------------------------------------------------------------

    always_comb begin

        for (int x = 0; x < STATE_DIM; x++) begin
            for (int y = 0; y < STATE_DIM; y++) begin

                state_out[x][y] =
                    rotl64(
                        state_in[x][y],
                        ROTATION_OFFSETS[x][y]
                    );

            end
        end

    end

endmodule