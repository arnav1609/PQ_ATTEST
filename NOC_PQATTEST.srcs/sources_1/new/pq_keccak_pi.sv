`timescale 1ns/1ps
//=============================================================================
// Module : keccak_pi
// File   : pq_keccak_pi.sv
//
// Purpose:
//   Keccak-f[1600] pi step. Pure lane permutation, no bit modification.
//
// History:
//   K6  Rewritten from scatter form to gather form.
//
//       The original wrote to a COMPUTED index:
//
//           state_out[y][(2*x + 3*y) % 5] = state_in[x][y];
//
//       The mapping is a bijection, so every one of the 25 outputs really is
//       written and simulation infers no latch. But a synthesis tool cannot
//       always prove full assignment through a computed left-hand index, and
//       an unproven always_comb is a latch warning at best and an inferred
//       latch at worst. The gather form below reads from a computed index and
//       writes every output unconditionally, so completeness is structural.
//
//       The two forms were checked to be identical at all 25 positions.
//
// Derivation of the inverse:
//   Forward :  out[y][(2x + 3y) mod 5] = in[x][y]
//   Let a = y, b = (2x + 3a) mod 5
//        => 2x = b - 3a           (mod 5)
//        => x  = 3 * (b - 3a)     (mod 5)     since 2 * 3 = 6 = 1 (mod 5)
//   Written as (b + 15 - 3a) to keep the argument non-negative; 15 = 0 (mod 5)
//   so the value is unchanged.
//
//   Gather :  out[a][b] = in[(3*(b + 15 - 3*a)) % 5][a]
//=============================================================================

module keccak_pi
    import keccak_pkg::*;
(
    input  state_t state_in,
    output state_t state_out
);

    always_comb begin

        for (int a = 0; a < STATE_DIM; a++) begin
            for (int b = 0; b < STATE_DIM; b++) begin

                state_out[a][b] =
                    state_in[ (3 * (b + 15 - 3*a)) % 5 ][a];

            end
        end

    end

endmodule
