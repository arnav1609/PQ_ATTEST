from keccak_ref import create_state, keccak_f1600


# ============================================================
# PQ-Attest TRNG Conditioning Reference
# ============================================================

RAW_BITS = 4096
RAW_BYTES = RAW_BITS // 8

CONDITIONED_BITS = 256
CONDITIONED_BYTES = CONDITIONED_BITS // 8

NONCE_BITS = 128
NONCE_BYTES = NONCE_BITS // 8

KECCAK_RATE_BYTES = 136


def keccak_condition(raw_entropy):
    """
    Condition 4096 bits of raw entropy using Keccak-f[1600].

    Input:
        raw_entropy : exactly 512 bytes

    Output:
        32 bytes = 256 conditioned bits
    """

    if len(raw_entropy) != RAW_BYTES:
        raise ValueError(
            f"Expected {RAW_BYTES} bytes of raw entropy, "
            f"got {len(raw_entropy)}"
        )

    # Keccak sponge input.
    #
    # For this project we use Keccak-256-style sponge
    # conditioning:
    #   rate = 1088 bits = 136 bytes
    #   capacity = 512 bits
    #   output = 256 bits
    #
    # Domain suffix 0x01 corresponds to Keccak padding.

    padded = bytearray(raw_entropy)

    padded.append(0x01)

    while len(padded) % KECCAK_RATE_BYTES != 0:
        padded.append(0x00)

    padded[-1] |= 0x80

    state = create_state()

    # Absorb
    for offset in range(0, len(padded), KECCAK_RATE_BYTES):

        block = padded[offset:offset + KECCAK_RATE_BYTES]

        for i in range(KECCAK_RATE_BYTES // 8):

            lane = int.from_bytes(
                block[i * 8:(i + 1) * 8],
                byteorder="little"
            )

            x = i % 5
            y = i // 5

            state[x][y] ^= lane

        state = keccak_f1600(state)

    # Squeeze 256 bits
    output = bytearray()

    for i in range(KECCAK_RATE_BYTES // 8):

        x = i % 5
        y = i // 5

        lane_bytes = state[x][y].to_bytes(
            8,
            byteorder="little"
        )

        output.extend(lane_bytes)

        if len(output) >= CONDITIONED_BYTES:
            break

    return bytes(output[:CONDITIONED_BYTES])


def generate_nonce(raw_entropy):
    """
    Generate a 128-bit nonce from conditioned entropy.
    """

    conditioned = keccak_condition(raw_entropy)

    nonce = conditioned[:NONCE_BYTES]

    return nonce


# ============================================================
# Simple test
# ============================================================

if __name__ == "__main__":

    # Deterministic test input.
    #
    # This is NOT intended to represent real entropy.
    # It is only used to verify the implementation.
    raw_entropy = bytes(range(256)) * 2

    conditioned = keccak_condition(raw_entropy)

    nonce = generate_nonce(raw_entropy)

    print("PQ-Attest TRNG Conditioning Test")
    print("--------------------------------")

    print(f"Raw entropy     : {len(raw_entropy)} bytes")
    print(f"Conditioned     : {len(conditioned)} bytes")
    print(f"Nonce           : {len(nonce)} bytes")

    print()
    print("Raw entropy:")
    print(raw_entropy.hex())

    print()
    print("Conditioned 256-bit output:")
    print(conditioned.hex())

    print()
    print("128-bit nonce:")
    print(nonce.hex())