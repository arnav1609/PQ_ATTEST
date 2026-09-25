`timescale 1ns/1ps

// ============================================================
// KECCAK-F[1600] ITERATIVE CORE
// ============================================================

module keccak_f1600_core (
    input  logic          clk,
    input  logic          rst,
    input  logic          start,
    input  logic [1599:0] state_in,

    output logic [1599:0] state_out,
    output logic          busy,
    output logic          done
);

    typedef enum logic [1:0] {
        IDLE,
        RUN,
        DONE
    } state_t;

    state_t state;

    logic [1599:0] current_state;
    logic [1599:0] next_state;

    logic [4:0] round_idx;

    keccak_round round_inst (
        .state_in  (current_state),
        .round_idx (round_idx),
        .state_out (next_state)
    );

    always_ff @(posedge clk) begin

        if (rst) begin

            state         <= IDLE;
            current_state <= 1600'b0;
            state_out     <= 1600'b0;
            round_idx     <= 5'd0;
            busy          <= 1'b0;
            done          <= 1'b0;

        end

        else begin

            done <= 1'b0;

            case (state)

                IDLE: begin

                    busy <= 1'b0;

                    if (start) begin

                        current_state <= state_in;
                        round_idx     <= 5'd0;
                        busy          <= 1'b1;

                        state <= RUN;

                    end

                end

                RUN: begin

                    current_state <= next_state;

                    if (round_idx == 5'd23) begin

                        state_out <= next_state;
                        busy      <= 1'b0;

                        state <= DONE;

                    end

                    else begin

                        round_idx <= round_idx + 1'b1;

                    end

                end

                DONE: begin

                    done  <= 1'b1;
                    state <= IDLE;
                    busy  <= 1'b0;
                end

                default: begin

                    state <= IDLE;
                    busy  <= 1'b0;
                    done  <= 1'b0;

                end

            endcase

        end

    end

endmodule
