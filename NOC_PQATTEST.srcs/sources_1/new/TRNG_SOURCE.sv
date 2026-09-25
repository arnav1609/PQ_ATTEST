`timescale 1ns/1ps

module trng_source
    import trng_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // Start generation of one 512-byte entropy sample
    input  logic                         start,

    // Deterministic raw-entropy test vector.
    // The TB loads exactly the same vector used by
    // trng_conditioning_ref.py.
    input  logic [RAW_ENTROPY_BYTES*8-1:0] entropy_vector,

    // Raw entropy output
    output logic [7:0]                   entropy_byte,
    output logic                         entropy_valid,
    output logic                         entropy_last,

    // Status
    output logic                         busy,
    output logic                         done
);

    // ============================================================
    // BYTE COUNTER
    // ============================================================

    logic [$clog2(RAW_ENTROPY_BYTES)-1:0] byte_count;

    logic active;


    // ============================================================
    // CONTROL
    // ============================================================

    always_ff @(posedge clk) begin

        if (!rst_n) begin

            byte_count    <= '0;
            active        <= 1'b0;

            entropy_byte  <= '0;
            entropy_valid <= 1'b0;
            entropy_last  <= 1'b0;

        end

        else begin

            // ----------------------------------------------------
            // Default pulse outputs
            // ----------------------------------------------------

            entropy_valid <= 1'b0;
            entropy_last  <= 1'b0;


            // ----------------------------------------------------
            // START
            // ----------------------------------------------------

            if (start && !active) begin

                byte_count <= '0;
                active     <= 1'b1;

            end


            // ----------------------------------------------------
            // OUTPUT ONE BYTE PER CLOCK
            // ----------------------------------------------------

            else if (active) begin

                entropy_byte <=
                    entropy_vector[byte_count*8 +: 8];

                entropy_valid <= 1'b1;


                // ------------------------------------------------
                // Last byte: byte 511
                // ------------------------------------------------

                if (byte_count == RAW_ENTROPY_BYTES - 1) begin

                    entropy_last <= 1'b1;
                    active       <= 1'b0;

                end

                else begin

                    byte_count <= byte_count + 1'b1;

                end

            end

        end

    end


    // ============================================================
    // STATUS
    // ============================================================

    assign busy = active;

    assign done = entropy_last;


endmodule