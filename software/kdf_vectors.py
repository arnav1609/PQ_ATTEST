from kmac128_ref import derive_tile_key


# ============================================================
# PQ-Attest KMAC-based KDF Golden Test Vectors
# ============================================================

ROOT_SECRET = bytes.fromhex(
    "000102030405060708090a0b0c0d0e0f"
    "101112131415161718191a1b1c1d1e1f"
)


TEST_CASES = [

    {
        "name": "V01_basic",
        "tile_id": b"TILE_01",
        "epoch": b"EPOCH_0001",
        "context": b"PQ-ATTEST-KDF",
        "key_bytes": 16,
    },

    {
        "name": "V02_tile_change",
        "tile_id": b"TILE_02",
        "epoch": b"EPOCH_0001",
        "context": b"PQ-ATTEST-KDF",
        "key_bytes": 16,
    },

    {
        "name": "V03_epoch_change",
        "tile_id": b"TILE_01",
        "epoch": b"EPOCH_0002",
        "context": b"PQ-ATTEST-KDF",
        "key_bytes": 16,
    },

    {
        "name": "V04_context_change",
        "tile_id": b"TILE_01",
        "epoch": b"EPOCH_0001",
        "context": b"PQ-ATTEST-AUTH",
        "key_bytes": 16,
    },

    {
        "name": "V05_empty_context",
        "tile_id": b"TILE_01",
        "epoch": b"EPOCH_0001",
        "context": b"",
        "key_bytes": 16,
    },

    {
        "name": "V06_256bit_key",
        "tile_id": b"TILE_01",
        "epoch": b"EPOCH_0001",
        "context": b"PQ-ATTEST-KDF",
        "key_bytes": 32,
    },
]


# ============================================================
# Generate Vectors
# ============================================================

def generate_vectors():

    vectors = []

    for case in TEST_CASES:

        derived_key = derive_tile_key(
            root_secret=ROOT_SECRET,
            tile_id=case["tile_id"],
            epoch=case["epoch"],
            context=case["context"],
            key_bytes=case["key_bytes"],
        )

        vector = {
            "name": case["name"],
            "root_secret": ROOT_SECRET.hex(),
            "tile_id": case["tile_id"].hex(),
            "epoch": case["epoch"].hex(),
            "context": case["context"].hex(),
            "key_bytes": case["key_bytes"],
            "expected_key": derived_key.hex(),
        }

        vectors.append(vector)

    return vectors


# ============================================================
# Print Vectors
# ============================================================

def print_vectors(vectors):

    print()
    print("=" * 80)
    print("PQ-Attest KMAC-based KDF Golden Test Vectors")
    print("=" * 80)

    for vector in vectors:

        print()
        print(f"[{vector['name']}]")
        print(f"ROOT_SECRET  = {vector['root_secret']}")
        print(f"TILE_ID      = {vector['tile_id']}")
        print(f"EPOCH        = {vector['epoch']}")
        print(f"CONTEXT      = {vector['context']}")
        print(f"KEY_BYTES    = {vector['key_bytes']}")
        print(f"EXPECTED_KEY = {vector['expected_key']}")

    print()
    print("=" * 80)


# ============================================================
# Verify Frozen Golden Values
# ============================================================

def verify_expected_vectors(vectors):

    expected = {

        "V01_basic":
            "9c699e785af03e632e2da3cbe9ede27c",

        "V02_tile_change":
            "f30ddb5b98f18616cfd5869f773fe53a",

        "V03_epoch_change":
            "6b166b7c1e131c6b418ee284cd674677",

        "V04_context_change":
            "ff09225456dd309555bd6bd4a890b279",

        "V05_empty_context":
            "92aea90b633ab5b0f512e4115ad2b4c1",

        "V06_256bit_key":
            "f3d22e09c5b0ba3b0e5a7c85ab7703fc"
            "95d5e5dd5bebd9044a3dd2a4824d6989",
    }

    print()
    print("Golden-vector verification:")

    all_pass = True

    for vector in vectors:

        actual = vector["expected_key"]
        expected_key = expected[vector["name"]]

        if actual == expected_key:

            print(
                f"{vector['name']}: PASS"
            )

        else:

            print(
                f"{vector['name']}: FAIL"
            )

            print(
                f"  Expected: {expected_key}"
            )

            print(
                f"  Actual:   {actual}"
            )

            all_pass = False

    print()

    if all_pass:

        print("ALL KDF GOLDEN VECTORS PASS")

    else:

        print("KDF GOLDEN VECTOR VERIFICATION FAILED")

    return all_pass


# ============================================================
# Write SystemVerilog Vector File
# ============================================================

def write_sv_vectors(
    vectors,
    filename="software/kdf_vectors.txt"
):

    """
    Write pipe-separated vectors for later RTL verification.
    """

    with open(filename, "w") as f:

        f.write(
            "# PQ-Attest KMAC-based KDF Golden Vectors\n"
        )

        f.write("#\n")

        f.write("# Format:\n")

        f.write(
            "# ROOT_SECRET | TILE_ID | EPOCH | "
            "CONTEXT | KEY_BYTES | EXPECTED_KEY\n"
        )

        f.write("#\n")

        for vector in vectors:

            f.write(
                f"{vector['root_secret']} | "
                f"{vector['tile_id']} | "
                f"{vector['epoch']} | "
                f"{vector['context']} | "
                f"{vector['key_bytes']} | "
                f"{vector['expected_key']}\n"
            )

    print(
        f"\nVector file written to: {filename}"
    )


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":

    vectors = generate_vectors()

    print_vectors(vectors)

    if not verify_expected_vectors(vectors):

        raise SystemExit(1)

    write_sv_vectors(vectors)

    print("\nDone.")