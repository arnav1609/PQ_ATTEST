`timescale 1ns/1ps
//=============================================================================
// Module : keccak_f1600
// File   : pq_keccak_f1600.sv
//
// Purpose:
//   Iterative Keccak-f[1600] permutation. One round per clock, 24 rounds.
//
// Interface contract:
//   start     pulse for one cycle while IDLE. state_in is captured on that
//             edge and may change afterwards.
//   busy      high while rounds are executing.
//   done      high for exactly ONE cycle. state_out is the final permutation
//             result on that cycle and remains stable until the next start.
//
// History:
//   K2  Module moved out of pq_keccak_round.sv so that file name and module
//       name agree (L-02). pq_keccak_round.sv now holds keccak_round.
//
//   K3  Reset changed from active-low rst_n to active-high synchronous rst,
//       matching the NoC convention. Two reset polarities in one SoC is a
//       silent integration bug waiting at the tile boundary; the plan's
//       Stage 0 exit gate requires one convention. Fixed at seven modules
//       rather than at thirty.
//
//   K4  Per-round observation ports added (round_valid / round_index).
//       The plan, section 5, requires comparing RTL against the Python
//       reference "at meaningful internal checkpoints, not only final
//       output". Without these ports a single wrong step module can only be
//       observed as a wrong answer 24 rounds later, with no localisation.
//       They are observation-only and synthesise away when unconnected.
//=============================================================================

module keccak_f1600
    import keccak_pkg::*;
(
    input  logic   clk,
    input  logic   rst,          // active-high, synchronous

    input  logic   start,
    input  state_t state_in,

    output state_t state_out,
    output logic   busy,
    output logic   done,

    //-------------------------------------------------------------------------
    // Per-round observation (verification checkpoints)
    //
    // round_valid pulses on every clock where state_out has just been updated
    // with the result of round round_index. Leave unconnected in synthesis.
    //-------------------------------------------------------------------------
    output logic   round_valid,
    output round_t round_index
);

    //-------------------------------------------------------------------------
    // Internal state
    //-------------------------------------------------------------------------

    state_t        state_reg;
    state_t        round_out;

    round_t        round_reg;
    keccak_state_e fsm_state;

    //-------------------------------------------------------------------------
    // One complete Keccak-f[1600] round (theta -> rho -> pi -> chi -> iota)
    //-------------------------------------------------------------------------

    keccak_round u_keccak_round (
        .state_in  (state_reg),
        .round     (round_reg),
        .state_out (round_out)
    );

    //-------------------------------------------------------------------------
    // Control FSM
    //-------------------------------------------------------------------------

    always_ff @(posedge clk) begin

        if (rst) begin

            state_reg   <= '{default:'0};
            round_reg   <= '0;
            fsm_state   <= KECCAK_IDLE;
            round_valid <= 1'b0;
            round_index <= '0;

        end
        else begin

            // Default: no round committed this cycle.
            round_valid <= 1'b0;

            case (fsm_state)

                //-------------------------------------------------------------
                // IDLE : capture the input state on start.
                //-------------------------------------------------------------
                KECCAK_IDLE: begin

                    if (start) begin
                        state_reg <= state_in;
                        round_reg <= '0;
                        fsm_state <= KECCAK_RUN;
                    end

                end

                //-------------------------------------------------------------
                // RUN : one complete round committed per clock.
                //
                //   round_reg = 0  -> round 0
                //   ...
                //   round_reg = 23 -> round 23
                //
                // Exactly NUM_ROUNDS rounds are executed.
                //-------------------------------------------------------------
                KECCAK_RUN: begin

                    state_reg   <= round_out;

                    round_valid <= 1'b1;
                    round_index <= round_reg;

                    if (round_reg == round_t'(NUM_ROUNDS - 1)) begin
                        fsm_state <= KECCAK_DONE;
                    end
                    else begin
                        round_reg <= round_reg + round_t'(1);
                    end

                end

                //-------------------------------------------------------------
                // DONE : result held in state_reg, one-cycle done pulse.
                //-------------------------------------------------------------
                KECCAK_DONE: begin
                    fsm_state <= KECCAK_IDLE;
                end

                //-------------------------------------------------------------
                // Defensive default.
                //-------------------------------------------------------------
                default: begin
                    state_reg <= '{default:'0};
                    round_reg <= '0;
                    fsm_state <= KECCAK_IDLE;
                end

            endcase

        end

    end

    //-------------------------------------------------------------------------
    // Outputs
    //-------------------------------------------------------------------------

    assign state_out = state_reg;
    assign busy      = (fsm_state == KECCAK_RUN);
    assign done      = (fsm_state == KECCAK_DONE);

    //-------------------------------------------------------------------------
    // SVA
    //
    // K5: round_t is 5 bits and indexes a 24-entry constant array inside
    //     keccak_iota. An out-of-range read is X in simulation and undefined
    //     in synthesis. The FSM is supposed to keep it in range; this is the
    //     check that says so out loud rather than assuming it.
    //-------------------------------------------------------------------------

    a_round_index_in_range:
        assert property (
            @(posedge clk) disable iff (rst)
            ($isunknown(round_reg) || (round_reg < round_t'(NUM_ROUNDS)))
        )
        else $error("keccak_f1600: round_reg=%0d exceeds NUM_ROUNDS", round_reg);

    a_done_is_single_cycle:
        assert property (
            @(posedge clk) disable iff (rst)
            done |=> !done
        )
        else $error("keccak_f1600: done asserted for more than one cycle");

    // A "start while busy" assertion was drafted here and deleted: busy is
    // defined as (fsm_state == KECCAK_RUN), so the property was a tautology
    // and could never fail. Per V-07, an assertion that cannot fail is worse
    // than no assertion - it reads as coverage that does not exist.
    // The real contract (start is ignored while busy) belongs in the
    // testbench, where the caller's behaviour can actually be varied.

endmodule
