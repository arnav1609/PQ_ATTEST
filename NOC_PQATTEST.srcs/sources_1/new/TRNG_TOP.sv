`timescale 1ns/1ps
module trng_top
    import trng_pkg::*;
(
    input  logic         clk,
    input  logic         rst_n,

    // ============================================================
    // Raw entropy input
    // ============================================================

    input  logic [63:0]  entropy_word,
    input  logic         entropy_valid,
    input  logic         entropy_last,
    output logic         entropy_ready,

    // ============================================================
    // Conditioned entropy output
    // ============================================================

    output logic [255:0] conditioned_out,
    output logic [127:0] nonce_out,

    output logic         conditioned_valid,
    input  logic         conditioned_ready,

    // ============================================================
    // Status
    // ============================================================

    output logic         busy,
    output logic         health_ok,
    output logic         health_fail,
    output logic         error
);


    // ============================================================
    // Entropy handshake
    // ============================================================

    logic entropy_fire;

    assign entropy_fire =
        entropy_valid &&
        entropy_ready;


    // ============================================================
    // Health-test signals
    //
    // Eight independent byte lanes are monitored.
    // Each lane observes one byte of the 64-bit entropy word.
    // ============================================================

    logic [7:0] health_fail_lanes;
    logic [7:0] health_ok_lanes;


    generate

        for (
            genvar i = 0;
            i < 8;
            i = i + 1
        ) begin : GEN_HEALTH

            trng_health #(
                .MAX_REPETITIONS(
                    DEFAULT_MAX_REPETITIONS
                )
            ) u_health (

                .clk (
                    clk
                ),

                .rst_n (
                    rst_n
                ),

                .entropy_byte (
                    entropy_word[i*8 +: 8]
                ),

                .entropy_valid (
                    entropy_fire
                ),

                .health_ok (
                    health_ok_lanes[i]
                ),

                .health_fail (
                    health_fail_lanes[i]
                )

            );

        end

    endgenerate


    // ============================================================
    // Aggregate health status
    // ============================================================

    assign health_fail =
        |health_fail_lanes;

    assign health_ok =
        !health_fail;


    // ============================================================
    // TRNG conditioner
    //
    // health_fail acts as a synchronous abort/zeroization request
    // inside the conditioner.
    // ============================================================

    trng_conditioner u_conditioner (

        .clk (
            clk
        ),

        .rst_n (
            rst_n
        ),

        .abort (
            health_fail
        ),

        .entropy_valid (
            entropy_valid
        ),

        .entropy_word (
            entropy_word
        ),

        .entropy_last (
            entropy_last
        ),

        .entropy_ready (
            entropy_ready
        ),

        .conditioned_out (
            conditioned_out
        ),

        .nonce_out (
            nonce_out
        ),

        .valid (
            conditioned_valid
        ),

        .ready (
            conditioned_ready
        ),

        .busy (
            busy
        )

    );


    // ============================================================
    // Error output
    //
    // For v1, any TRNG health-test failure is reported as error.
    // ============================================================

    assign error =
        health_fail;


endmodule