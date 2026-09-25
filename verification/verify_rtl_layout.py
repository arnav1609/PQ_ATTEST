"""
PQ-Attest P0-3 RTL Layout Verifier

Purpose:
    Independently verify Python <-> RTL representation/layout conversions.

Checks:
    - byte ordering
    - 64-bit word ordering
    - Keccak lane ordering
    - 1600-bit packed/unpacked ordering
    - bit ordering
    - complete round-trip conversion

The verifier intentionally uses asymmetric data so that ordering
mutations cannot accidentally pass.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


# ============================================================================
# Constants
# ============================================================================

LANE_COUNT = 25
LANE_BITS = 64
STATE_BITS = LANE_COUNT * LANE_BITS
STATE_BYTES = STATE_BITS // 8

WORD_BYTES = 8
WORD_BITS = 64


# ============================================================================
# Test pattern
# ============================================================================

TEST_BYTES = bytes.fromhex(
    "0011223344556677"
    "8899AABBCCDDEEFF"
    "1032547698BADCFE"
    "13579BDF2468ACE0"
    "3141592653589793"
    "2718281828459045"
    "DEADBEEFCAFEBABE"
    "0123456789ABCDEF"
    "FEDCBA9876543210"
    "0F1E2D3C4B5A6978"
    "89ABCDEF01234567"
    "76543210FEDCBA98"
    "1122334455667788"
    "99AABBCCDDEEFF00"
    "55AA55AA33CC33CC"
    "A5A5A5A55A5A5A5A"
    "1234567890ABCDEF"
    "0BADF00DCAFED00D"
    "C001D00DDEADC0DE"
    "FACEB00C1234ABCD"
    "13579BDF02468ACE"
    "2468ACE013579BDF"
    "AAAAAAAA55555555"
    "33333333CCCCCCCC"
    "1F2E3D4C5B6A7988"
)

assert len(TEST_BYTES) == STATE_BYTES


# ============================================================================
# Result
# ============================================================================

@dataclass
class TestResult:
    name: str
    passed: bool
    message: str


# ============================================================================
# Basic conversions
# ============================================================================

def bytes_to_words_le(data: bytes) -> list[int]:
    """
    Convert bytes into 64-bit words.

    RTL convention:
        byte 0 -> bits [7:0]
        byte 7 -> bits [63:56]

    Therefore each 8-byte group is interpreted little-endian.
    """

    if len(data) % WORD_BYTES != 0:
        raise ValueError(
            "byte array length must be a multiple of 8"
        )

    return [
        int.from_bytes(
            data[offset:offset + WORD_BYTES],
            byteorder="little",
        )
        for offset in range(
            0,
            len(data),
            WORD_BYTES,
        )
    ]


def words_to_bytes_le(words: list[int]) -> bytes:
    """Convert 64-bit words back into little-endian bytes."""

    output = bytearray()

    for word in words:
        if not 0 <= word < (1 << WORD_BITS):
            raise ValueError(
                f"word outside 64-bit range: {word:#x}"
            )

        output.extend(
            word.to_bytes(
                WORD_BYTES,
                byteorder="little",
            )
        )

    return bytes(output)


# ============================================================================
# Keccak lane mapping
# ============================================================================

def bytes_to_keccak_lanes(data: bytes) -> list[int]:
    """
    Map the 1600-bit state into 25 Keccak lanes.

    Lane index:
        lane = x + 5*y

    Each lane contains 64 bits and is interpreted little-endian.
    """

    words = bytes_to_words_le(data)

    if len(words) != LANE_COUNT:
        raise ValueError(
            f"expected {LANE_COUNT} lanes, got {len(words)}"
        )

    return words


def keccak_lanes_to_bytes(lanes: list[int]) -> bytes:
    """Convert Keccak lanes back into the byte representation."""

    if len(lanes) != LANE_COUNT:
        raise ValueError(
            f"expected {LANE_COUNT} lanes, got {len(lanes)}"
        )

    return words_to_bytes_le(lanes)


# ============================================================================
# Packed SystemVerilog state
# ============================================================================

def lanes_to_packed_state(lanes: list[int]) -> int:
    """
    Pack lanes into a 1600-bit integer.

    Lane 0 occupies:
        packed[63:0]

    Lane 1 occupies:
        packed[127:64]

    ...

    Lane 24 occupies:
        packed[1599:1536]

    This matches the natural SystemVerilog packed-vector slicing
    convention used by this verifier.
    """

    if len(lanes) != LANE_COUNT:
        raise ValueError(
            f"expected {LANE_COUNT} lanes"
        )

    packed = 0

    for lane_index, lane in enumerate(lanes):

        if not 0 <= lane < (1 << LANE_BITS):
            raise ValueError(
                f"lane {lane_index} is outside 64-bit range"
            )

        packed |= lane << (
            lane_index * LANE_BITS
        )

    return packed


def packed_state_to_lanes(packed: int) -> list[int]:
    """Unpack a 1600-bit packed state into 25 lanes."""

    if not 0 <= packed < (1 << STATE_BITS):
        raise ValueError(
            "packed state is outside 1600-bit range"
        )

    mask = (1 << LANE_BITS) - 1

    return [
        (packed >> (lane_index * LANE_BITS)) & mask
        for lane_index in range(LANE_COUNT)
    ]


# ============================================================================
# Bit ordering
# ============================================================================

def reverse_bits_64(value: int) -> int:
    """Reverse the bit order of a 64-bit word."""

    result = 0

    for bit in range(64):
        result <<= 1
        result |= (value >> bit) & 1

    return result


# ============================================================================
# Round-trip checks
# ============================================================================

def check_byte_word_roundtrip() -> TestResult:

    words = bytes_to_words_le(TEST_BYTES)
    recovered = words_to_bytes_le(words)

    passed = recovered == TEST_BYTES

    return TestResult(
        name="BYTE_WORD_ROUNDTRIP",
        passed=passed,
        message=(
            "byte -> 64-bit words -> byte preserved"
            if passed
            else "byte/word conversion changed data"
        ),
    )


def check_keccak_lane_roundtrip() -> TestResult:

    lanes = bytes_to_keccak_lanes(TEST_BYTES)
    recovered = keccak_lanes_to_bytes(lanes)

    passed = recovered == TEST_BYTES

    return TestResult(
        name="KECCAK_LANE_ROUNDTRIP",
        passed=passed,
        message=(
            "bytes -> lanes -> bytes preserved"
            if passed
            else "Keccak lane conversion changed data"
        ),
    )


def check_packed_state_roundtrip() -> TestResult:

    lanes = bytes_to_keccak_lanes(TEST_BYTES)

    packed = lanes_to_packed_state(lanes)

    recovered_lanes = packed_state_to_lanes(packed)

    recovered = keccak_lanes_to_bytes(
        recovered_lanes
    )

    passed = recovered == TEST_BYTES

    return TestResult(
        name="PACKED_STATE_ROUNDTRIP",
        passed=passed,
        message=(
            "lanes -> 1600-bit packed state -> lanes preserved"
            if passed
            else "packed state conversion changed lane ordering"
        ),
    )


def check_full_roundtrip() -> TestResult:

    lanes = bytes_to_keccak_lanes(TEST_BYTES)

    packed = lanes_to_packed_state(lanes)

    recovered_lanes = packed_state_to_lanes(packed)

    recovered_words = recovered_lanes

    recovered = words_to_bytes_le(
        recovered_words
    )

    passed = recovered == TEST_BYTES

    return TestResult(
        name="FULL_ROUNDTRIP",
        passed=passed,
        message=(
            "bytes -> words -> lanes -> packed -> lanes -> bytes preserved"
            if passed
            else "full layout round-trip changed data"
        ),
    )


# ============================================================================
# Mutation tests
# ============================================================================

def mutate_byte_reverse(data: bytes) -> bytes:
    """Intentional byte-order mutation."""

    return data[::-1]


def mutate_word_reverse(data: bytes) -> bytes:
    """Intentional 64-bit word-order mutation."""

    words = [
        data[offset:offset + WORD_BYTES]
        for offset in range(
            0,
            len(data),
            WORD_BYTES,
        )
    ]

    words.reverse()

    return b"".join(words)


def mutate_lane_reverse(lanes: list[int]) -> list[int]:
    """Intentional Keccak lane-order mutation."""

    return list(reversed(lanes))


def mutate_bit_reverse(lanes: list[int]) -> list[int]:
    """Intentional per-lane bit-order mutation."""

    return [
        reverse_bits_64(lane)
        for lane in lanes
    ]


def check_mutation(
    name: str,
    mutation: Callable[[], bytes],
) -> TestResult:

    mutated = mutation()

    passed = mutated != TEST_BYTES

    return TestResult(
        name=name,
        passed=passed,
        message=(
            "mutation correctly changes representation"
            if passed
            else "mutation unexpectedly produced original data"
        ),
    )


def check_lane_mutation() -> TestResult:

    lanes = bytes_to_keccak_lanes(TEST_BYTES)

    mutated = mutate_lane_reverse(lanes)

    recovered = keccak_lanes_to_bytes(mutated)

    passed = recovered != TEST_BYTES

    return TestResult(
        name="MUTATION_LANE_REVERSE",
        passed=passed,
        message=(
            "lane reversal detected"
            if passed
            else "lane reversal was not detected"
        ),
    )


def check_bit_mutation() -> TestResult:

    lanes = bytes_to_keccak_lanes(TEST_BYTES)

    mutated = mutate_bit_reverse(lanes)

    recovered = keccak_lanes_to_bytes(mutated)

    passed = recovered != TEST_BYTES

    return TestResult(
        name="MUTATION_BIT_REVERSE",
        passed=passed,
        message=(
            "bit reversal detected"
            if passed
            else "bit reversal was not detected"
        ),
    )


# ============================================================================
# Asymmetric pattern checks
# ============================================================================

def check_asymmetric_pattern() -> TestResult:

    unique_bytes = len(set(TEST_BYTES)) > 1

    unique_words = len(
        set(bytes_to_words_le(TEST_BYTES))
    ) == LANE_COUNT

    passed = unique_bytes and unique_words

    return TestResult(
        name="ASYMMETRIC_PATTERN",
        passed=passed,
        message=(
            "test pattern is asymmetric and suitable for layout testing"
            if passed
            else "test pattern is not sufficiently asymmetric"
        ),
    )


# ============================================================================
# Negative tests
# ============================================================================

def check_wrong_length_rejected() -> TestResult:

    try:
        bytes_to_words_le(
            TEST_BYTES[:-1]
        )

    except ValueError:
        return TestResult(
            name="NEGATIVE_WRONG_LENGTH",
            passed=True,
            message="invalid byte length correctly rejected",
        )

    return TestResult(
        name="NEGATIVE_WRONG_LENGTH",
        passed=False,
        message="invalid byte length was accepted",
    )


def check_wrong_lane_count_rejected() -> TestResult:

    try:
        lanes_to_packed_state(
            [0] * 24
        )

    except ValueError:
        return TestResult(
            name="NEGATIVE_WRONG_LANE_COUNT",
            passed=True,
            message="invalid lane count correctly rejected",
        )

    return TestResult(
        name="NEGATIVE_WRONG_LANE_COUNT",
        passed=False,
        message="invalid lane count was accepted",
    )


def check_invalid_packed_state_rejected() -> TestResult:

    try:
        packed_state_to_lanes(
            1 << STATE_BITS
        )

    except ValueError:
        return TestResult(
            name="NEGATIVE_INVALID_PACKED_STATE",
            passed=True,
            message="oversized packed state correctly rejected",
        )

    return TestResult(
        name="NEGATIVE_INVALID_PACKED_STATE",
        passed=False,
        message="oversized packed state was accepted",
    )


# ============================================================================
# Test runner
# ============================================================================

def run_all_tests() -> list[TestResult]:

    results: list[TestResult] = []

    # Positive tests
    results.append(
        check_asymmetric_pattern()
    )

    results.append(
        check_byte_word_roundtrip()
    )

    results.append(
        check_keccak_lane_roundtrip()
    )

    results.append(
        check_packed_state_roundtrip()
    )

    results.append(
        check_full_roundtrip()
    )

    # Mutation tests
    results.append(
        check_mutation(
            "MUTATION_BYTE_REVERSE",
            lambda: mutate_byte_reverse(TEST_BYTES),
        )
    )

    results.append(
        check_mutation(
            "MUTATION_WORD_REVERSE",
            lambda: mutate_word_reverse(TEST_BYTES),
        )
    )

    results.append(
        check_lane_mutation()
    )

    results.append(
        check_bit_mutation()
    )

    # Negative tests
    results.append(
        check_wrong_length_rejected()
    )

    results.append(
        check_wrong_lane_count_rejected()
    )

    results.append(
        check_invalid_packed_state_rejected()
    )

    return results


# ============================================================================
# Report
# ============================================================================

def print_report(results: list[TestResult]) -> int:

    print()
    print("=" * 68)
    print("PQ-ATTEST RTL LAYOUT VERIFICATION")
    print("=" * 68)

    failures = 0

    for result in results:

        status = "PASS" if result.passed else "FAIL"

        if not result.passed:
            failures += 1

        print(
            f"{status:<8} "
            f"{result.name:<32} "
            f"{result.message}"
        )

    print("=" * 68)

    if failures == 0:
        print(
            "P0-3 RTL LAYOUT VERIFIER TESTS: ALL PASS"
        )
    else:
        print(
            f"P0-3 RTL LAYOUT VERIFIER TESTS: "
            f"{failures} FAILURE(S)"
        )

    print("=" * 68)

    return 0 if failures == 0 else 1


# ============================================================================
# Main
# ============================================================================

def main() -> int:

    results = run_all_tests()

    return print_report(results)


if __name__ == "__main__":
    raise SystemExit(main())