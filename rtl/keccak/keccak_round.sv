`timescale 1ns/1ps

// ============================================================
// KECCAK-F[1600] ROUND
// ============================================================

module keccak_round (
    input  logic [1599:0] state_in,
    input  logic [4:0]    round_idx,
    output logic [1599:0] state_out
);

    logic [63:0] A [0:4][0:4];
    logic [63:0] B [0:4][0:4];
    logic [63:0] C [0:4];
    logic [63:0] D [0:4];

    integer x, y;
    integer nx, ny;

    function automatic [63:0] rotl64(
        input [63:0] v,
        input integer n
    );
        begin
            if (n == 0)
                rotl64 = v;
            else
                rotl64 = (v << n) | (v >> (64-n));
        end
    endfunction

    // Keccak rho offsets
    function automatic integer rho_offset(
        input integer xx,
        input integer yy
    );
        begin
            case (xx + 5*yy)
                0:  rho_offset = 0;
                1:  rho_offset = 1;
                2:  rho_offset = 62;
                3:  rho_offset = 28;
                4:  rho_offset = 27;

                5:  rho_offset = 36;
                6:  rho_offset = 44;
                7:  rho_offset = 6;
                8:  rho_offset = 55;
                9:  rho_offset = 20;

                10: rho_offset = 3;
                11: rho_offset = 10;
                12: rho_offset = 43;
                13: rho_offset = 25;
                14: rho_offset = 39;

                15: rho_offset = 41;
                16: rho_offset = 45;
                17: rho_offset = 15;
                18: rho_offset = 21;
                19: rho_offset = 8;

                20: rho_offset = 18;
                21: rho_offset = 2;
                22: rho_offset = 61;
                23: rho_offset = 56;
                24: rho_offset = 14;

                default: rho_offset = 0;
            endcase
        end
    endfunction

    // Keccak round constants
    function automatic [63:0] round_constant(
        input integer r
    );
        begin
            case (r)
                0:  round_constant = 64'h0000000000000001;
                1:  round_constant = 64'h0000000000008082;
                2:  round_constant = 64'h800000000000808A;
                3:  round_constant = 64'h8000000080008000;
                4:  round_constant = 64'h000000000000808B;
                5:  round_constant = 64'h0000000080000001;
                6:  round_constant = 64'h8000000080008081;
                7:  round_constant = 64'h8000000000008009;
                8:  round_constant = 64'h000000000000008A;
                9:  round_constant = 64'h0000000000000088;
                10: round_constant = 64'h0000000080008009;
                11: round_constant = 64'h000000008000000A;
                12: round_constant = 64'h000000008000808B;
                13: round_constant = 64'h800000000000008B;
                14: round_constant = 64'h8000000000008089;
                15: round_constant = 64'h8000000000008003;
                16: round_constant = 64'h8000000000008002;
                17: round_constant = 64'h8000000000000080;
                18: round_constant = 64'h000000000000800A;
                19: round_constant = 64'h800000008000000A;
                20: round_constant = 64'h8000000080008081;
                21: round_constant = 64'h8000000000008080;
                22: round_constant = 64'h0000000080000001;
                23: round_constant = 64'h8000000080008008;

                default: round_constant = 64'h0;
            endcase
        end
    endfunction

    always @* begin

        // ----------------------------------------------------
        // Unpack state
        // ----------------------------------------------------

        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin
                A[x][y] =
                    state_in[(x + 5*y)*64 +: 64];
            end
        end

        // ----------------------------------------------------
        // THETA
        // ----------------------------------------------------

        for (x = 0; x < 5; x = x + 1) begin
            C[x] =
                A[x][0] ^
                A[x][1] ^
                A[x][2] ^
                A[x][3] ^
                A[x][4];
        end

        for (x = 0; x < 5; x = x + 1) begin
            D[x] =
                C[(x+4)%5] ^
                rotl64(C[(x+1)%5], 1);
        end

        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin
                A[x][y] =
                    A[x][y] ^ D[x];
            end
        end

        // ----------------------------------------------------
        // RHO + PI
        // ----------------------------------------------------

        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin

                nx = y;
                ny = (2*x + 3*y) % 5;

                B[nx][ny] =
                    rotl64(
                        A[x][y],
                        rho_offset(x,y)
                    );

            end
        end

        // ----------------------------------------------------
        // CHI
        // ----------------------------------------------------

        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin

                A[x][y] =
                    B[x][y] ^
                    ((~B[(x+1)%5][y]) &
                      B[(x+2)%5][y]);

            end
        end

        // ----------------------------------------------------
        // IOTA
        // ----------------------------------------------------

        A[0][0] =
            A[0][0] ^
            round_constant(round_idx);

        // ----------------------------------------------------
        // Pack state
        // ----------------------------------------------------

        for (x = 0; x < 5; x = x + 1) begin
            for (y = 0; y < 5; y = y + 1) begin
                state_out[(x + 5*y)*64 +: 64] =
                    A[x][y];
            end
        end

    end

endmodule
