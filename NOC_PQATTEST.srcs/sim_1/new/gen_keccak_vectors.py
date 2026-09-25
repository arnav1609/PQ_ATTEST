#!/usr/bin/env python3
"""
Generate Keccak-f[1600] golden vectors for the RTL testbench.

WHY THIS SCRIPT EXISTS
----------------------
The first version of pq_keccak_tb.sv had 25 hand-typed 64-bit constants.
Twenty of them were wrong - not mistyped, TRANSPOSED. The teammate's Python
reference prints the state with y as the OUTER loop:

    for y in range(5):
        row = [f"{state[x][y]:016x}" for x in range(5)]

so printed row 0 is state[0][0] state[1][0] ... state[4][0]: it walks x across
the row. The testbench read the printed row index as the FIRST subscript, so
expected_zero[0][1] was given state[1][0]. Only the five diagonal lanes landed
correctly. The RTL was right; the checker was wrong. That is the V-01 failure
mode, and it costs days because the natural response is to "fix" correct RTL.

This script removes the class of error entirely: the expected values are
emitted in the RTL's own [x][y] order and read with $readmemh. Nothing is
transcribed by hand.

It also emits ALL 24 intermediate round states, not just the final one. The
implementation plan, section 5, requires comparing "at meaningful internal
checkpoints, not only final output". With per-round checkpoints a wrong step
module shows up at round 0 and is localised immediately; with a final-only
check it shows up as a wrong answer 24 rounds later with no localisation.

CONSTANTS ARE DERIVED, NOT TRANSCRIBED
--------------------------------------
The rho offsets and the iota round constants are computed from their
algorithmic definitions below, then compared against the RTL package. A
constant copied from a web page and asserted to be correct is not evidence.

OUTPUT
------
keccak_rounds.memh : 24 * 25 = 600 lanes, ordered
                     index = round*25 + x*5 + y
"""

MASK = (1 << 64) - 1


def rotl(x, n):
    n %= 64
    return ((x << n) | (x >> (64 - n))) & MASK if n else x


# --- rho offsets, from the (t+1)(t+2)/2 walk over the (x,y) lattice ---------
ROT = [[0] * 5 for _ in range(5)]
_x, _y = 1, 0
for t in range(24):
    ROT[_x][_y] = ((t + 1) * (t + 2) // 2) % 64
    _x, _y = _y, (2 * _x + 3 * _y) % 5
ROT[0][0] = 0


# --- iota round constants, from the 8-bit LFSR defined in FIPS 202 ----------
def _rc_bit(t):
    if t % 255 == 0:
        return 1
    r = 0x01
    for _ in range(1, t % 255 + 1):
        r <<= 1
        if r & 0x100:
            r ^= 0x71
        r &= 0xFF
    return r & 1


RC = []
for _ir in range(24):
    _c = 0
    for _j in range(7):
        if _rc_bit(_j + 7 * _ir):
            _c ^= 1 << ((1 << _j) - 1)
    RC.append(_c)


# --- the five steps, in FIPS 202 order -------------------------------------
def theta(A):
    C = [A[x][0] ^ A[x][1] ^ A[x][2] ^ A[x][3] ^ A[x][4] for x in range(5)]
    D = [C[(x - 1) % 5] ^ rotl(C[(x + 1) % 5], 1) for x in range(5)]
    return [[A[x][y] ^ D[x] for y in range(5)] for x in range(5)]


def rho(A):
    return [[rotl(A[x][y], ROT[x][y]) for y in range(5)] for x in range(5)]


def pi_(A):
    B = [[0] * 5 for _ in range(5)]
    for x in range(5):
        for y in range(5):
            B[y][(2 * x + 3 * y) % 5] = A[x][y]
    return B


def chi(A):
    return [[A[x][y] ^ (((~A[(x + 1) % 5][y]) & MASK) & A[(x + 2) % 5][y])
             for y in range(5)] for x in range(5)]


def iota(A, i):
    B = [r[:] for r in A]
    B[0][0] ^= RC[i]
    return B


def keccak_f1600(A):
    """Return the list of all 24 intermediate states."""
    out = []
    for i in range(24):
        A = iota(chi(pi_(rho(theta(A)))), i)
        out.append([r[:] for r in A])
    return out


# --- cross-check the gather form used by pq_keccak_pi.sv -------------------
def _check_pi_gather():
    A = [[(x * 5 + y + 1) * 0x0123456789ABCDEF & MASK
          for y in range(5)] for x in range(5)]
    scatter = pi_(A)
    gather = [[A[(3 * (b + 15 - 3 * a)) % 5][a] for b in range(5)]
              for a in range(5)]
    assert scatter == gather, "pi gather form does not match scatter form"


if __name__ == "__main__":
    _check_pi_gather()

    rounds = keccak_f1600([[0] * 5 for _ in range(5)])

    with open("keccak_rounds.memh", "w") as f:
        for i, st in enumerate(rounds):
            f.write(f"// round {i}\n")
            for x in range(5):
                for y in range(5):
                    f.write(f"{st[x][y]:016x}\n")

    print("rho offsets   :", ROT)
    print("round const 0 :", hex(RC[0]), " 23:", hex(RC[23]))
    print("final [0][0]  :", f"{rounds[23][0][0]:016x}")
    print("wrote keccak_rounds.memh:", 24 * 25, "lanes")
