`timescale 1ns/1ps
//=============================================================================
// Module : keccak_iota
// File   : pq_keccak_iota.sv
//
// Purpose:
//   Keccak-f[1600] iota step.
//
//       A'[0][0] = A[0][0] ^ ROUND_CONSTANTS[round]
//
//   Every other lane passes through unchanged.
//
// History:
//   K5  round_t is 5 bits (0..31) but ROUND_CONSTANTS has only NUM_ROUNDS=24
//       entries. An out-of-range read yields X in simulation and is undefined
//       in synthesis - the tool may fold it to zero, which would silently
//       turn iota into a no-op for that round instead of failing loudly.
//       The index is now clamped and the illegal case is asserted.
//=============================================================================

module keccak_iota
    import keccak_pkg::*;
(
    input  state_t state_in,
    input  round_t round,
    output state_t state_out
);

    //-------------------------------------------------------------------------
    // Bounds-safe round constant lookup.
    //-------------------------------------------------------------------------

    lane_t rc;

    always_comb begin
        if (round < round_t'(NUM_ROUNDS)) begin
            rc = ROUND_CONSTANTS[round];
        end
        else begin
            rc = '0;                    // defined, and caught by the assertion
        end
    end

    //-------------------------------------------------------------------------
    // Iota
    //-------------------------------------------------------------------------

    always_comb begin

        // Full-state copy first. This maps to wires, not logic.
        state_out       = state_in;

        // Then override lane [0][0]. Last assignment wins in always_comb.
        state_out[0][0] = state_in[0][0] ^ rc;

    end

    //-------------------------------------------------------------------------
    // Immediate assertion.
    //
    // Unclocked on purpose: this module is combinational and has no clock.
    // The check compares values produced inside THIS block from the same
    // input snapshot, so it cannot see an intermediate combinational state -
    // the delta-cycle race class that produced V-09 in noc_xy_routing does
    // not apply here.
    //-------------------------------------------------------------------------

    // The $isunknown guard is required, not cosmetic: before the first reset
    // the driving register is X, and "X < 24" evaluates false, which would
    // report a failure that has not occurred. That is the V-01 / V-09 class
    // of false failure and it is cheaper to exclude here than to debug later.
    always_comb begin
        a_round_in_range:
            assert ($isunknown(round) || (round < round_t'(NUM_ROUNDS)))
            else $error(
                "keccak_iota: round=%0d out of range (NUM_ROUNDS=%0d)",
                round, NUM_ROUNDS
            );
    end

endmodule
