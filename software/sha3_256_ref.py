import hashlib
from keccak_ref import (
    create_state,
    state_to_hex,
    keccak_f1600
)

RATE_BYTES = 136
OUTPUT_BYTES = 32


def sha3_pad(message):
    """
    Apply SHA3 padding.

    SHA3 domain suffix = 0x06
    Final bit is included in the last byte.
    """

    padded = bytearray(message)

    padded.append(0x06)

    while len(padded) % RATE_BYTES != 0:
        padded.append(0x00)

    padded[-1] |= 0x80

    return bytes(padded)


def absorb_block(state, block):
    """
    Absorb one 136-byte SHA3-256 block
    into the Keccak state.
    """

    for i in range(17):

        lane = int.from_bytes(
            block[i * 8:(i + 1) * 8],
            byteorder="little"
        )

        x = i % 5
        y = i // 5

        state[x][y] ^= lane
def squeeze(state, output_bytes):
    """
    Extract output bytes from the Keccak state.

    SHA3 uses little-endian byte ordering within
    each 64-bit lane.
    """

    output = bytearray()

    for i in range(25):
        x = i % 5
        y = i // 5

        lane_bytes = state[x][y].to_bytes(
            8,
            byteorder="little"
        )

        output.extend(lane_bytes)

        if len(output) >= output_bytes:
            break

    return bytes(output[:output_bytes])


if __name__ == "__main__":

    test_messages = [
        b"",
        b"abc",
        b"hello world",
        b"a" * 135,
        b"a" * 136,
        b"a" * 137,
    ]

    for message in test_messages:

        padded = sha3_pad(message)

        state = create_state()

        # Absorb every 136-byte block
        for offset in range(0, len(padded), RATE_BYTES):
            block = padded[offset:offset + RATE_BYTES]

            absorb_block(state, block)

            state = keccak_f1600(state)

        digest = squeeze(state, OUTPUT_BYTES)

        expected = hashlib.sha3_256(message).digest()

        print(f"Message length: {len(message)}")
        print(f"Our SHA3-256 : {digest.hex()}")
        print(f"hashlib      : {expected.hex()}")

        if digest == expected:
            print("PASS\n")
        else:
            print("FAIL\n")