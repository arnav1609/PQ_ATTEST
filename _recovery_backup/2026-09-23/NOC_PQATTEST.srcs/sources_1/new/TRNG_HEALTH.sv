`timescale 1ns/1ps

module trng_health #(
    parameter int MAX_REPETITIONS = 32
)
(
    input  logic       clk,
    input  logic       rst_n,

    input  logic [7:0] entropy_byte,
    input  logic       entropy_valid,

    output logic       health_ok,
    output logic       health_fail
);

    // ============================================================
    // Parameter validation
    // ============================================================

    initial begin

        if (MAX_REPETITIONS < 1) begin

            $error(
                "trng_health: MAX_REPETITIONS must be >= 1"
            );

        end

    end


    // ============================================================
    // Counter width
    // ============================================================

    localparam int REP_COUNT_WIDTH =
        (MAX_REPETITIONS <= 1) ?
        1 :
        $clog2(MAX_REPETITIONS + 1);


    // ============================================================
    // State
    // ============================================================

    logic [7:0] last_byte;

    logic have_previous;

    logic [REP_COUNT_WIDTH-1:0] repetition_count;

    logic failure_sticky;


    // ============================================================
    // Health monitor
    // ============================================================

    always_ff @(posedge clk) begin

        if (!rst_n) begin

            last_byte        <= 8'h00;
            have_previous    <= 1'b0;
            repetition_count <= '0;
            failure_sticky   <= 1'b0;

        end

        else if (entropy_valid) begin

            // ----------------------------------------------------
            // First accepted entropy sample
            // ----------------------------------------------------

            if (!have_previous) begin

                last_byte        <= entropy_byte;
                have_previous    <= 1'b1;
                repetition_count <= 1;

                // For a threshold of one, the first sample itself
                // constitutes the complete repetition criterion.
                if (MAX_REPETITIONS == 1)
                    failure_sticky <= 1'b1;

            end

            // ----------------------------------------------------
            // Consecutive identical sample
            // ----------------------------------------------------

            else if (entropy_byte == last_byte) begin

                last_byte <= entropy_byte;

                if (repetition_count < MAX_REPETITIONS)
                    repetition_count <=
                        repetition_count + 1'b1;

                // Existing count represents the number of
                // identical samples already seen.
                //
                // Therefore old count == MAX-1 means this
                // accepted sample is the MAX-th repetition.

                if (repetition_count >=
                    MAX_REPETITIONS - 1)
                    failure_sticky <= 1'b1;

            end

            // ----------------------------------------------------
            // New entropy value
            // ----------------------------------------------------

            else begin

                last_byte <= entropy_byte;

                repetition_count <= 1;

            end

        end

    end


    // ============================================================
    // Outputs
    // ============================================================

    assign health_fail = failure_sticky;

    assign health_ok =
        !failure_sticky;

endmodule