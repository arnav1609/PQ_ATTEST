`timescale 1ns/1ps
//=============================================================================
// Module : keccak_round
// File   : pq_keccak_round.sv
//
// Purpose:
//   One complete Keccak-f[1600] round.
//
//       state_in -> THETA -> RHO -> PI -> CHI -> IOTA -> state_out
//
//   Purely combinational. No clock, no reset, no state.
//
// History:
//   K1  This module did not exist. keccak_f1600 instantiated it, so the
//       whole crypto lane failed to elaborate with an unresolved reference.
//       The five step modules existed but were never chained.
//
//   K2  The file previously named pq_keccak_round.sv contained module
//       keccak_f1600, so file name and module name disagreed (violates L-02).
//       keccak_f1600 now lives in pq_keccak_f1600.sv.
//
// Note on ordering:
//   The order below is fixed by FIPS 202. It is NOT interchangeable.
//   Swapping RHO and PI produces a permutation that still looks plausible
//   in waveforms and is wrong on every vector.
//=============================================================================

module keccak_round
    import keccak_pkg::*;
(
    input  state_t state_in,
    input  round_t round,
    output state_t state_out
);

    state_t theta_out;
    state_t rho_out;
    state_t pi_out;
    state_t chi_out;

    keccak_theta u_theta (
        .state_in  (state_in),
        .state_out (theta_out)
    );

    keccak_rho u_rho (
        .state_in  (theta_out),
        .state_out (rho_out)
    );

    keccak_pi u_pi (
        .state_in  (rho_out),
        .state_out (pi_out)
    );

    keccak_chi u_chi (
        .state_in  (pi_out),
        .state_out (chi_out)
    );

    keccak_iota u_iota (
        .state_in  (chi_out),
        .round     (round),
        .state_out (state_out)
    );

endmodule
