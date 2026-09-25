// V-10 (final): last design unit in the project without a timescale.
`timescale 1ns/1ps

package keccak_pkg;

    // ============================================================
    // Parameters
    // ============================================================

    localparam int LANE_WIDTH = 64;
    localparam int STATE_DIM  = 5;
    localparam int NUM_LANES  = STATE_DIM * STATE_DIM;
    localparam int STATE_SIZE = NUM_LANES * LANE_WIDTH;
    localparam int NUM_ROUNDS = 24;


    // ============================================================
    // Basic Types
    // ============================================================

    typedef logic [LANE_WIDTH-1:0] lane_t;

    typedef lane_t state_t [STATE_DIM][STATE_DIM];


    // ============================================================
    // Keccak Controller States
    // Used later by keccak_f1600.sv
    // ============================================================

    typedef enum logic [1:0] {
        KECCAK_IDLE = 2'b00,
        KECCAK_LOAD = 2'b01,
        KECCAK_RUN  = 2'b10,
        KECCAK_DONE = 2'b11
    } keccak_state_e;


    // ============================================================
    // Round Index
    // ============================================================

    typedef logic [4:0] round_t;


    // ============================================================
    // 64-bit Rotate Left
    //
    // Python equivalent:
    //
    // ((x << n) | (x >> (64-n))) & MASK64
    //
    // Function is automatic and purely combinational.
    // ============================================================

    function automatic lane_t rotl64(
        input lane_t x,
        input int    n
    );

        if (n == 0) begin
            rotl64 = x;
        end
        else begin
            rotl64 = (x << n) | (x >> (LANE_WIDTH - n));
        end

    endfunction


    // ============================================================
    // Rho Rotation Offsets
    // ============================================================

    localparam int ROTATION_OFFSETS [STATE_DIM][STATE_DIM] = '{
        '{ 0, 36,  3, 41, 18},
        '{ 1, 44, 10, 45,  2},
        '{62,  6, 43, 15, 61},
        '{28, 55, 25, 21, 56},
        '{27, 20, 39,  8, 14}
    };


    // ============================================================
    // Iota Round Constants
    // ============================================================

    localparam lane_t ROUND_CONSTANTS [NUM_ROUNDS] = '{
        64'h0000_0000_0000_0001,
        64'h0000_0000_0000_8082,
        64'h8000_0000_0000_808A,
        64'h8000_0000_8000_8000,
        64'h0000_0000_0000_808B,
        64'h0000_0000_8000_0001,
        64'h8000_0000_8000_8081,
        64'h8000_0000_0000_8009,
        64'h0000_0000_0000_008A,
        64'h0000_0000_0000_0088,
        64'h0000_0000_8000_8009,
        64'h0000_0000_8000_000A,
        64'h0000_0000_8000_808B,
        64'h8000_0000_0000_008B,
        64'h8000_0000_0000_8089,
        64'h8000_0000_0000_8003,
        64'h8000_0000_0000_8002,
        64'h8000_0000_0000_0080,
        64'h0000_0000_0000_800A,
        64'h8000_0000_8000_000A,
        64'h8000_0000_8000_8081,
        64'h8000_0000_0000_8080,
        64'h0000_0000_8000_0001,
        64'h8000_0000_8000_8008
    };

endpackage