"""
PQ-Attest P1-1 Crypto Golden Vector Generator

Uses the existing frozen Python reference implementations.

DO NOT implement cryptography here.
This file only generates stable test vectors from:

    sha3_256_ref.py
    kmac128_ref.py

Coverage:
    SHA3-256
        - empty
        - short
        - 135 bytes
        - 136 bytes
        - 137 bytes
        - multi-block
        - deterministic random

    KMAC128
        - NIST SP 800-185 vectors
        - empty message
        - short message
        - 168-byte boundary
        - multi-block
        - deterministic random

Output:
    software/crypto_vectors.json
"""

from __future__ import annotations

import hashlib
import json
import random
from pathlib import Path

from measurement_ref import sha3_256_reference
from kmac128_ref import kmac128


SEED = 0x50414154  # "PAAT"

OUTPUT_FILE = Path(__file__).resolve().parent / "crypto_vectors.json"


# ============================================================================
# Helpers
# ============================================================================

def make_vector(
    vector_id: str,
    input_data: bytes,
    expected_output: bytes,
) -> dict:
    return {
        "vector_id": vector_id,
        "input": input_data.hex(),
        "expected_output": expected_output.hex(),
    }


def deterministic_bytes(
    rng: random.Random,
    length: int,
) -> bytes:
    return bytes(
        rng.getrandbits(8)
        for _ in range(length)
    )


# ============================================================================
# SHA3-256 vectors
# ============================================================================

def generate_sha3_vectors() -> list[dict]:

    vectors = []

    test_messages = [
        ("SHA3_V01_empty", b""),
        ("SHA3_V02_abc", b"abc"),
        ("SHA3_V03_short", b"hello world"),
        ("SHA3_V04_135_bytes", b"a" * 135),
        ("SHA3_V05_136_bytes", b"a" * 136),
        ("SHA3_V06_137_bytes", b"a" * 137),

        (
            "SHA3_V07_multiblock",
            bytes(
                range(256)
            ) * 2,
        ),
    ]

    rng = random.Random(SEED)

    for index, length in enumerate(
        [1, 17, 64, 135, 136, 137, 272, 273, 511],
        start=8,
    ):
        test_messages.append(
            (
                f"SHA3_V{index:02d}_random_{length}",
                deterministic_bytes(rng, length),
            )
        )

    for vector_id, message in test_messages:

        # Existing frozen reference is the source of truth.
        expected = sha3_256_reference(message)

        # Independent consistency check against hashlib.
        hashlib_expected = hashlib.sha3_256(
            message
        ).digest()

        if expected != hashlib_expected:
            raise RuntimeError(
                f"{vector_id}: reference mismatch against hashlib"
            )

        vectors.append(
            make_vector(
                vector_id,
                message,
                expected,
            )
        )

    return vectors


# ============================================================================
# KMAC128 vectors
# ============================================================================

def generate_kmac_vectors() -> list[dict]:

    vectors = []

    key_nist = bytes(
        range(0x40, 0x60)
    )

    # ------------------------------------------------------------------------
    # NIST SP 800-185 vectors
    # ------------------------------------------------------------------------

    nist_vectors = [
        (
            "KMAC_V01_NIST_empty_customization",
            key_nist,
            bytes([0x00, 0x01, 0x02, 0x03]),
            b"",
            32,
        ),

        (
            "KMAC_V02_NIST_tagged_application",
            key_nist,
            bytes([0x00, 0x01, 0x02, 0x03]),
            b"My Tagged Application",
            32,
        ),

        (
            "KMAC_V03_NIST_200_byte_message",
            key_nist,
            bytes(range(200)),
            b"My Tagged Application",
            32,
        ),
    ]

    # ------------------------------------------------------------------------
    # Boundary / project coverage
    # ------------------------------------------------------------------------

    project_key = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f"
        "101112131415161718191a1b1c1d1e1f"
    )

    boundary_vectors = [
        (
            "KMAC_V04_empty_message",
            project_key,
            b"",
            b"",
            32,
        ),

        (
            "KMAC_V05_short_message",
            project_key,
            b"abc",
            b"",
            32,
        ),

        (
            "KMAC_V06_167_byte_message",
            project_key,
            bytes(range(167)),
            b"",
            32,
        ),

        (
            "KMAC_V07_168_byte_message",
            project_key,
            bytes(range(168)),
            b"",
            32,
        ),

        (
            "KMAC_V08_169_byte_message",
            project_key,
            bytes(range(169)),
            b"",
            32,
        ),

        (
            "KMAC_V09_multiblock_message",
            project_key,
            bytes(range(256)) * 2,
            b"PQ-ATTEST",
            32,
        ),

        (
            "KMAC_V10_128_bit_output",
            project_key,
            b"PQ-ATTEST",
            b"",
            16,
        ),
    ]

    all_vectors = (
        nist_vectors
        + boundary_vectors
    )

    # ------------------------------------------------------------------------
    # Deterministic random vectors
    # ------------------------------------------------------------------------

    rng = random.Random(
        SEED ^ 0x4B4D4143
    )

    for index, length in enumerate(
        [1, 7, 32, 167, 168, 169, 300, 511],
        start=11,
    ):

        message = deterministic_bytes(
            rng,
            length,
        )

        key = deterministic_bytes(
            rng,
            16,
        )

        customization = deterministic_bytes(
            rng,
            5,
        )

        all_vectors.append(
            (
                f"KMAC_V{index:02d}_random_{length}",
                key,
                message,
                customization,
                32,
            )
        )

    # ------------------------------------------------------------------------
    # Generate
    # ------------------------------------------------------------------------

    for (
        vector_id,
        key,
        message,
        customization,
        output_bytes,
    ) in all_vectors:

        expected = kmac128(
            key=key,
            message=message,
            output_bytes=output_bytes,
            customization=customization,
        )

        vectors.append(
            {
                "vector_id": vector_id,
                "key": key.hex(),
                "input": message.hex(),
                "customization": customization.hex(),
                "output_bytes": output_bytes,
                "expected_output": expected.hex(),
            }
        )

    return vectors


# ============================================================================
# Generate complete vector set
# ============================================================================

def generate_all_vectors() -> dict:

    sha3_vectors = generate_sha3_vectors()
    kmac_vectors = generate_kmac_vectors()

    return {
        "schema_version": "1.0",
        "generator": "software/crypto_vectors.py",
        "seed": SEED,
        "sha3_256": sha3_vectors,
        "kmac128": kmac_vectors,
    }


# ============================================================================
# Validation
# ============================================================================

def validate_vectors(data: dict) -> None:

    if data["schema_version"] != "1.0":
        raise RuntimeError(
            "unexpected vector schema version"
        )

    if not data["sha3_256"]:
        raise RuntimeError(
            "SHA3 vector set is empty"
        )

    if not data["kmac128"]:
        raise RuntimeError(
            "KMAC vector set is empty"
        )

    # Ensure vector IDs are globally unique.
    ids = []

    for vector in data["sha3_256"]:
        ids.append(vector["vector_id"])

    for vector in data["kmac128"]:
        ids.append(vector["vector_id"])

    if len(ids) != len(set(ids)):
        raise RuntimeError(
            "duplicate vector_id detected"
        )


# ============================================================================
# Main
# ============================================================================

def main() -> int:

    data = generate_all_vectors()

    validate_vectors(data)

    OUTPUT_FILE.write_text(
        json.dumps(
            data,
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )
    SHA3_OUTPUT_FILE = OUTPUT_FILE.parent / "sha3_vectors.json"
    KMAC_OUTPUT_FILE = OUTPUT_FILE.parent / "kmac_vectors.json"

    SHA3_OUTPUT_FILE.write_text(
        json.dumps(
            data["sha3_256"],
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    KMAC_OUTPUT_FILE.write_text(
        json.dumps(
            data["kmac128"],
            indent=2,
        ) + "\n",
        encoding="utf-8",
    )

    print("=" * 68)
    print("PQ-ATTEST CRYPTO GOLDEN VECTOR GENERATION")
    print("=" * 68)

    print(
        f"SHA3-256 VECTORS : "
        f"{len(data['sha3_256'])}"
    )

    print(
        f"KMAC128 VECTORS  : "
        f"{len(data['kmac128'])}"
    )

    print(
        f"TOTAL VECTORS    : "
        f"{len(data['sha3_256']) + len(data['kmac128'])}"
    )

    print(
        f"SEED             : "
        f"0x{SEED:08X}"
    )

    print(
        f"OUTPUT           : "
        f"{OUTPUT_FILE}"
    )
    print(
        f"SHA3 OUTPUT      : "
        f"{SHA3_OUTPUT_FILE}"
    )

    print(
        f"KMAC OUTPUT      : "
        f"{KMAC_OUTPUT_FILE}"
    )

    print("=" * 68)
    print("CRYPTO VECTOR GENERATION: PASS")
    print("=" * 68)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())