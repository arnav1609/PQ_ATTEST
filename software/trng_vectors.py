from trng_conditioning_ref import keccak_condition, generate_nonce


# ============================================================
# PQ-Attest TRNG Conditioning Golden Test Vectors
# ============================================================

TEST_CASES = [
    {
        "name": "V01_incrementing",
        "raw_entropy": bytes(range(256)) * 2,
    },

    {
        "name": "V02_all_zero",
        "raw_entropy": bytes(512),
    },

    {
        "name": "V03_all_ff",
        "raw_entropy": bytes([0xFF]) * 512,
    },

    {
        "name": "V04_alternating",
        "raw_entropy": bytes([0xAA, 0x55]) * 256,
    },

    {
        "name": "V05_alternating_reverse",
        "raw_entropy": bytes([0x55, 0xAA]) * 256,
    },
]


def generate_vectors():
    vectors = []

    for case in TEST_CASES:

        raw_entropy = case["raw_entropy"]

        conditioned = keccak_condition(raw_entropy)
        nonce = generate_nonce(raw_entropy)

        vector = {
            "name": case["name"],
            "raw_entropy": raw_entropy.hex(),
            "conditioned_256": conditioned.hex(),
            "nonce_128": nonce.hex(),
        }

        vectors.append(vector)

    return vectors


def print_vectors(vectors):

    print()
    print("=" * 80)
    print("PQ-Attest TRNG Conditioning Golden Test Vectors")
    print("=" * 80)

    for v in vectors:

        print()
        print(f"[{v['name']}]")

        print(f"RAW_ENTROPY    = {v['raw_entropy']}")
        print(f"CONDITIONED_256 = {v['conditioned_256']}")
        print(f"NONCE_128       = {v['nonce_128']}")

    print()
    print("=" * 80)


def write_vectors(vectors, filename="trng_vectors.txt"):

    with open(filename, "w") as f:

        f.write("# PQ-Attest TRNG Conditioning Golden Vectors\n")
        f.write("#\n")
        f.write("# Format:\n")
        f.write("# TEST_ID | RAW_ENTROPY | CONDITIONED_256 | NONCE_128\n")
        f.write("#\n")

        for v in vectors:

            f.write(
                f"{v['name']} | "
                f"{v['raw_entropy']} | "
                f"{v['conditioned_256']} | "
                f"{v['nonce_128']}\n"
            )

    print(f"\nVector file written to: {filename}")


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":

    vectors = generate_vectors()

    print_vectors(vectors)

    write_vectors(vectors)

    print("\nTRNG vector generation complete.")