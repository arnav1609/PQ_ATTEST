# PQ-Attest
# Keccak-f[1600] Python Reference Model
# Phase 1: Basic state and 64-bit operations

MASK64 = (1 << 64) - 1


def rotl64(x, n):
    """
    64-bit left rotation.
    """
    x &= MASK64

    if n == 0:
        return x

    return ((x << n) | (x >> (64 - n))) & MASK64


def create_state():
    """
    Create a Keccak state consisting of 25 lanes.
    
    State organization:
        A[x][y]
    
    where x,y = 0..4
    and each lane is 64 bits.
    """
    return [[0 for y in range(5)] for x in range(5)]
def theta(state):
    """
    Keccak-f[1600] Theta transformation.

    C[x] = A[x,0] XOR A[x,1] XOR A[x,2] XOR A[x,3] XOR A[x,4]

    D[x] = C[x-1] XOR ROTL64(C[x+1], 1)

    A'[x,y] = A[x,y] XOR D[x]
    """

    C = [0] * 5
    D = [0] * 5

    # Step 1: Column parities
    for x in range(5):
        C[x] = (
            state[x][0]
            ^ state[x][1]
            ^ state[x][2]
            ^ state[x][3]
            ^ state[x][4]
        )

    # Step 2: Calculate D
    for x in range(5):
        D[x] = C[(x - 1) % 5] ^ rotl64(C[(x + 1) % 5], 1)

    # Step 3: XOR D[x] into every lane of column x
    new_state = create_state()

    for x in range(5):
        for y in range(5):
            new_state[x][y] = state[x][y] ^ D[x]

    return new_state


def state_to_hex(state):
    """
    Print the 25 lanes in hexadecimal.
    """
    for y in range(5):
        row = []

        for x in range(5):
            row.append(f"{state[x][y]:016x}")

        print(" ".join(row))
# Keccak-f[1600] rotation offsets
ROTATION_OFFSETS = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14]
]
# --------------------------------------------------
# Keccak-f[1600] round constants
# --------------------------------------------------

ROUND_CONSTANTS = [
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808A,
    0x8000000080008000,
    0x000000000000808B,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008A,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000A,
    0x000000008000808B,
    0x800000000000008B,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800A,
    0x800000008000000A,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008
]
def rho(state):
    """
    Keccak-f[1600] Rho transformation.

    Rotates every 64-bit lane by its
    corresponding rotation offset.
    """

    new_state = create_state()

    for x in range(5):
        for y in range(5):
            offset = ROTATION_OFFSETS[x][y]
            new_state[x][y] = rotl64(state[x][y], offset)

    return new_state
def pi(state):
    """
    Keccak-f[1600] Pi transformation.

    Moves each lane according to:

        A'[y][2*x + 3*y] = A[x][y]

    with coordinates taken modulo 5.
    """

    new_state = create_state()

    for x in range(5):
        for y in range(5):
            new_x = y
            new_y = (2 * x + 3 * y) % 5

            new_state[new_x][new_y] = state[x][y]

    return new_state
def chi(state):
    """
    Keccak-f[1600] Chi transformation.

    For every row y:

        A'[x,y] =
            A[x,y] XOR
            ((NOT A[x+1,y]) AND A[x+2,y])

    All operations are performed on 64-bit lanes.
    """

    new_state = create_state()

    for x in range(5):
        for y in range(5):

            current = state[x][y]

            next_lane = state[(x + 1) % 5][y]

            next_next_lane = state[(x + 2) % 5][y]

            new_state[x][y] = (
                current
                ^ ((~next_lane) & next_next_lane)
            ) & MASK64

    return new_state
def iota(state, round_number):
    """
    Keccak-f[1600] Iota transformation.

    XORs the round constant into A[0][0].
    """

    new_state = create_state()

    # Copy the state
    for x in range(5):
        for y in range(5):
            new_state[x][y] = state[x][y]

    # Apply round constant
    new_state[0][0] ^= ROUND_CONSTANTS[round_number]

    # Keep it 64-bit
    new_state[0][0] &= MASK64

    return new_state
def keccak_f1600(state):
    """
    Complete Keccak-f[1600] permutation.

    Performs 24 rounds.
    Each round:
        Theta -> Rho -> Pi -> Chi -> Iota
    """

    for round_number in range(24):

        state = theta(state)

        state = rho(state)

        state = pi(state)

        state = chi(state)

        state = iota(state, round_number)

    return state



if __name__ == "__main__":

    state = create_state()

    print("Input State:")
    state_to_hex(state)

    state = keccak_f1600(state)

    print("\nOutput State:")
    state_to_hex(state)