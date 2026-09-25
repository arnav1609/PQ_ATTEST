`timescale 1ns/1ps
//=============================================================================
// File   : pq_measurement.sv
// Module : pq_measurement          PQ-Attest Stage 6 - Tile Measurement
//
//   M = SHA3-256( TILE_ID || CONFIG || IMEM )
//
// Per software/measurement_ref.py: RAW CONCATENATION. No separators, no
// length fields, no encode_string(). Stage 5 length-prefixes its fields;
// Stage 6 deliberately does not, because the reference does not.
//
//-----------------------------------------------------------------------------
// HEADER STYLE - matches sha3_256, pq_kdf, kmac128, keccak_f1600
//
//   Package imports in the header, NO parameter port list. Vivado rejects
//   `import pkg::*;` combined with #(...), and rejects a scoped pkg::PARAM
//   inside an ANSI port declaration. Constants live in pq_measurement_pkg.
//
//-----------------------------------------------------------------------------
// BYTE ORDER
//   Every interface is byte i at [i*8 +: 8].
//   sha3_256 returns digest[i*8 +: 8] = digest byte i, so the measurement
//   passes straight to Stage 7's KMAC with NO byte swap.
//
//-----------------------------------------------------------------------------
// TWO SHA3 CONTRACTS THIS MODULE EXISTS TO HONOUR
//
//  1. sha3_256 reads `is_final` LIVE in its KECCAK_WAIT state, ~26 cycles
//     after start - it has no latch of its own. So is_final is driven here
//     from a REGISTER, set at accept and held until the next request.
//
//  2. sha3_pad only pads when valid_bytes < RATE_BYTES. A full 136-byte
//     final block gets NO padding and yields a silently wrong digest.
//     MEASURE_MSG_MAX_BYTES = 135 makes that unreachable; assertions below
//     enforce it if that ever changes.
//
//-----------------------------------------------------------------------------
// SCOPE: SINGLE BLOCK ONLY
//   All six reference vectors are <= 135 bytes (max is V06 at 7+64+64).
//   No multi-block path is implemented, because no vector would test it.
//   An over-length request is REJECTED: the FSM stays in S_IDLE and never
//   asserts done, so the caller hangs and the assertion fires. Extend to
//   multi-block only when a golden vector exists that needs it.
//=============================================================================

module pq_measurement
    import pq_measurement_pkg::*;
    import sha3_pkg::*;
(
    input  logic clk,
    input  logic rst_n,                       // ACTIVE LOW, synchronous

    input  logic start,

    // Byte i of each field is at [i*8 +: 8].
    input  logic [TILE_ID_BITS-1:0]      tile_id,

    input  logic [CONFIG_MAX_BITS-1:0]   config_data,   // 'config' is reserved
    input  logic [CONFIG_LEN_BITS-1:0]   config_len,    // 0 .. 64

    input  logic [IMEM_MAX_BITS-1:0]     imem,
    input  logic [IMEM_LEN_BITS-1:0]     imem_len,      // 0 .. 64

    output logic [MEASUREMENT_BITS-1:0]  measurement,
    output logic                         busy,

    // done pulses for one cycle while state_q is already S_IDLE, so busy is
    // LOW on the done cycle. A consumer must not gate its next request on
    // !busy alone.
    output logic                         done
);

    // Must match sha3_256's valid_bytes width exactly.
    localparam int LEN_W = $clog2(RATE_BYTES + 1);   // 8

    //-------------------------------------------------------------------------
    // Latched request
    //-------------------------------------------------------------------------
    logic [TILE_ID_BITS-1:0]    tile_id_q;
    logic [CONFIG_MAX_BITS-1:0] config_q;
    logic [IMEM_MAX_BITS-1:0]   imem_q;
    logic [CONFIG_LEN_BITS-1:0] config_len_q;
    logic [IMEM_LEN_BITS-1:0]   imem_len_q;

    //-------------------------------------------------------------------------
    // SHA3 interface registers
    //
    // sha3_valid_bytes_q and sha3_is_final_q are REGISTERS, not wires, and
    // are held stable from accept to done. See contract 1 in the header.
    //-------------------------------------------------------------------------
    logic                   sha3_start_q;
    logic [LEN_W-1:0]       sha3_valid_bytes_q;
    logic                   sha3_is_final_q;

    logic [DIGEST_BITS-1:0] sha3_digest;
    logic                   sha3_busy;
    logic                   sha3_done;

    //-------------------------------------------------------------------------
    // Message block - combinational, built from the LATCHED request.
    //
    // Width is RATE_BITS (1088). Do NOT hard-code it: a narrow register
    // leaves the top byte of the block undriven and the port connection
    // silently zero-extends.
    //-------------------------------------------------------------------------
    logic [RATE_BITS-1:0] msg_block;

    always_comb begin
        msg_block = '0;

        // TILE_ID at bytes 0 .. TILE_ID_BYTES-1
        for (int i = 0; i < TILE_ID_BYTES; i++) begin
            msg_block[i*8 +: 8] = tile_id_q[i*8 +: 8];
        end

        // CONFIG immediately follows TILE_ID
        for (int i = 0; i < CONFIG_MAX_BYTES; i++) begin
            if (i < int'(config_len_q)) begin
                msg_block[(TILE_ID_BYTES + i)*8 +: 8] = config_q[i*8 +: 8];
            end
        end

        // IMEM immediately follows CONFIG
        for (int i = 0; i < IMEM_MAX_BYTES; i++) begin
            if (i < int'(imem_len_q)) begin
                msg_block[(TILE_ID_BYTES + int'(config_len_q) + i)*8 +: 8] =
                    imem_q[i*8 +: 8];
            end
        end
    end

    //-------------------------------------------------------------------------
    // Accept-time length check, on the LIVE inputs
    //-------------------------------------------------------------------------
    logic [15:0] req_len;
    logic        req_len_ok;

    always_comb begin
        req_len    = TILE_ID_BYTES + config_len + imem_len;
        req_len_ok = (req_len <= MEASURE_MSG_MAX_BYTES);
    end

    //-------------------------------------------------------------------------
    // SHA3-256 - Stage 2, verified. Reused, not reimplemented.
    //-------------------------------------------------------------------------
    sha3_256 u_sha3 (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (sha3_start_q),
        .msg_block_in (msg_block),
        .valid_bytes  (sha3_valid_bytes_q),
        .is_final     (sha3_is_final_q),
        .digest       (sha3_digest),
        .busy         (sha3_busy),
        .done         (sha3_done)
    );

    //-------------------------------------------------------------------------
    // Control FSM
    //-------------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_SHA3 = 2'd1,      // one-cycle start pulse to sha3_256
        S_WAIT = 2'd2,
        S_DONE = 2'd3
    } state_e;

    state_e state_q;

    assign busy = (state_q == S_SHA3) || (state_q == S_WAIT);

    always_ff @(posedge clk) begin

        if (!rst_n) begin
            state_q            <= S_IDLE;

            tile_id_q          <= '0;
            config_q           <= '0;
            imem_q             <= '0;
            config_len_q       <= '0;
            imem_len_q         <= '0;

            sha3_start_q       <= 1'b0;
            sha3_valid_bytes_q <= '0;
            sha3_is_final_q    <= 1'b0;

            measurement        <= '0;
            done               <= 1'b0;
        end
        else begin

            // Defaults. BOTH non-blocking - never mix = and <= on the same
            // variable inside one always_ff; IEEE 1800 forbids it.
            sha3_start_q <= 1'b0;
            done         <= 1'b0;

            case (state_q)

                //-------------------------------------------------------------
                // Accept. A start while busy cannot reach here, so the
                // in-flight request is untouched.
                //-------------------------------------------------------------
                S_IDLE: begin
                    if (start && req_len_ok) begin
                        tile_id_q          <= tile_id;
                        config_q           <= config_data;
                        imem_q             <= imem;
                        config_len_q       <= config_len;
                        imem_len_q         <= imem_len;

                        sha3_valid_bytes_q <= req_len[LEN_W-1:0];
                        sha3_is_final_q    <= 1'b1;   // held until next accept

                        state_q            <= S_SHA3;
                    end
                end

                S_SHA3: begin
                    sha3_start_q <= 1'b1;
                    state_q      <= S_WAIT;
                end

                S_WAIT: begin
                    if (sha3_done) begin
                        measurement <= sha3_digest;
                        state_q     <= S_DONE;
                    end
                end

                S_DONE: begin
                    done    <= 1'b1;
                    state_q <= S_IDLE;
                end

                default: state_q <= S_IDLE;

            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Elaboration checks - the two packages must agree
    //-------------------------------------------------------------------------
    // synthesis translate_off
    initial begin
        if (MEASUREMENT_BITS != DIGEST_BITS) begin
            $fatal(1, "pq_measurement: MEASUREMENT_BITS=%0d != sha3_pkg::DIGEST_BITS=%0d",
                   MEASUREMENT_BITS, DIGEST_BITS);
        end
        if (MEASURE_MSG_MAX_BYTES >= RATE_BYTES) begin
            $fatal(1, "pq_measurement: MEASURE_MSG_MAX_BYTES=%0d must be < RATE_BYTES=%0d - a full final block gets NO padding",
                   MEASURE_MSG_MAX_BYTES, RATE_BYTES);
        end
        if ((TILE_ID_BYTES + CONFIG_MAX_BYTES + IMEM_MAX_BYTES) != MEASURE_MSG_MAX_BYTES) begin
            $fatal(1, "pq_measurement: field maxima (%0d) do not sum to MEASURE_MSG_MAX_BYTES (%0d)",
                   TILE_ID_BYTES + CONFIG_MAX_BYTES + IMEM_MAX_BYTES, MEASURE_MSG_MAX_BYTES);
        end
    end
    // synthesis translate_on

    //-------------------------------------------------------------------------
    // Runtime assertions
    //-------------------------------------------------------------------------
    // synthesis translate_off

    a_no_full_final_block:
        assert property (@(posedge clk) disable iff (!rst_n)
            !(sha3_start_q && sha3_is_final_q &&
              (sha3_valid_bytes_q == RATE_BYTES)))
        else $error("pq_measurement: full final block gets NO padding");

    a_request_within_limit:
        assert property (@(posedge clk) disable iff (!rst_n)
            start |-> req_len_ok)
        else $error("pq_measurement: request %0d bytes exceeds %0d",
                    req_len, MEASURE_MSG_MAX_BYTES);

    a_done_one_cycle:
        assert property (@(posedge clk) disable iff (!rst_n)
            done |=> !done)
        else $error("pq_measurement: done is not a one-cycle pulse");

    // synthesis translate_on

endmodule