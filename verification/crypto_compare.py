"""
PQ-Attest P0-2 Crypto Golden Vector Comparator

Compares frozen Python golden vectors against RTL result vectors.

Golden format:
[
    {
        "vector_id": "V01",
        "input": "...",
        "expected_output": "..."
    }
]

RTL format:
[
    {
        "vector_id": "V01",
        "rtl_output": "..."
    }
]

Optional RTL input:
[
    {
        "vector_id": "V01",
        "input": "...",
        "rtl_output": "..."
    }
]

Exit codes:
    0 = PASS
    1 = comparison FAIL
    2 = file/schema/format error
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ============================================================================
# Result structure
# ============================================================================

@dataclass
class ComparisonResult:
    golden_vectors: int = 0
    rtl_vectors: int = 0

    matched: int = 0

    missing_rtl: int = 0
    extra_rtl: int = 0
    duplicate_rtl: int = 0
    reordered: int = 0

    malformed_golden: int = 0
    malformed_rtl: int = 0

    input_mismatches: int = 0
    width_mismatches: int = 0
    output_mismatches: int = 0
    missing_rtl_result: int = 0

    issues: list[str] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return (
            self.missing_rtl == 0
            and self.extra_rtl == 0
            and self.duplicate_rtl == 0
            and self.reordered == 0
            and self.malformed_golden == 0
            and self.malformed_rtl == 0
            and self.input_mismatches == 0
            and self.width_mismatches == 0
            and self.output_mismatches == 0
            and self.missing_rtl_result == 0
        )


# ============================================================================
# JSON loading
# ============================================================================

def load_json_vectors(path: Path) -> list[dict[str, Any]]:
    """
    Load either:

        [...]
    
    or:

        {"vectors": [...]}
    """

    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError as exc:
        raise ValueError(f"file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(
            f"invalid JSON in {path}: {exc}"
        ) from exc

    if isinstance(data, list):
        vectors = data

    elif isinstance(data, dict) and isinstance(data.get("vectors"), list):
        vectors = data["vectors"]

    else:
        raise ValueError(
            f"{path}: expected a JSON array or "
            f'{{"vectors": [...]}}'
        )

    for index, vector in enumerate(vectors):
        if not isinstance(vector, dict):
            raise ValueError(
                f"{path}: vector at index {index} is not an object"
            )

    return vectors


# ============================================================================
# Hex validation
# ============================================================================

def validate_hex(
    value: Any,
    field_name: str,
    *,
    allow_empty: bool = False,
) -> str | None:
    """
    Validate a hexadecimal string.

    Empty input is valid for algorithms such as SHA3-256 because
    the empty message is a legitimate test vector.

    Empty output is never valid.
    """

    if not isinstance(value, str):
        return f"{field_name} must be a string"

    if value == "":
        if allow_empty:
            return None

        return f"{field_name} is empty"

    if value.startswith(("0x", "0X")):
        return f"{field_name} must not contain 0x prefix"

    if any(character.isspace() for character in value):
        return f"{field_name} contains whitespace"

    if len(value) % 2 != 0:
        return (
            f"{field_name} must contain an even number "
            f"of hex characters"
        )

    try:
        int(value, 16)
    except ValueError:
        return f"{field_name} contains non-hex characters"

    return None


# ============================================================================
# Vector validation
# ============================================================================

def validate_golden_vectors(
    vectors: list[dict[str, Any]],
    result: ComparisonResult,
) -> dict[str, dict[str, Any]]:
    """
    Validate and index golden vectors.
    """

    indexed: dict[str, dict[str, Any]] = {}

    for vector in vectors:
        vector_id = vector.get("vector_id")

        if not isinstance(vector_id, str) or not vector_id:
            result.malformed_golden += 1
            result.issues.append(
                "MALFORMED_GOLDEN: missing or invalid vector_id"
            )
            continue

        if vector_id in indexed:
            result.malformed_golden += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_GOLDEN: duplicate vector_id"
            )
            continue

        if "input" not in vector:
            result.malformed_golden += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_GOLDEN: missing input"
            )
            continue

        if "expected_output" not in vector:
            result.malformed_golden += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_GOLDEN: "
                f"missing expected_output"
            )
            continue

        # IMPORTANT:
        # Empty input is valid.
        error = validate_hex(
            vector["input"],
            "input",
            allow_empty=True,
        )

        if error:
            result.malformed_golden += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_GOLDEN: {error}"
            )
            continue

        error = validate_hex(
            vector["expected_output"],
            "expected_output",
            allow_empty=False,
        )

        if error:
            result.malformed_golden += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_GOLDEN: {error}"
            )
            continue

        indexed[vector_id] = vector

    return indexed


def validate_rtl_vectors(
    vectors: list[dict[str, Any]],
    result: ComparisonResult,
) -> tuple[
    dict[str, dict[str, Any]],
    Counter[str],
]:
    """
    Validate and index RTL vectors.

    Duplicate IDs are retained in the Counter so they can be reported
    explicitly.
    """

    indexed: dict[str, dict[str, Any]] = {}
    ids = Counter(
        vector.get("vector_id")
        for vector in vectors
        if isinstance(vector.get("vector_id"), str)
    )

    for vector in vectors:
        vector_id = vector.get("vector_id")

        if not isinstance(vector_id, str) or not vector_id:
            result.malformed_rtl += 1
            result.issues.append(
                "MALFORMED_RTL: missing or invalid vector_id"
            )
            continue

        if "rtl_output" not in vector:
            result.missing_rtl_result += 1
            result.issues.append(
                f"[{vector_id}] MISSING_RTL_RESULT"
            )
            continue

        # Empty RTL output is never valid.
        error = validate_hex(
            vector["rtl_output"],
            "rtl_output",
            allow_empty=False,
        )

        if error:
            result.malformed_rtl += 1
            result.issues.append(
                f"[{vector_id}] MALFORMED_RTL: {error}"
            )
            continue

        # Optional RTL input.
        if "input" in vector:
            error = validate_hex(
                vector["input"],
                "input",
                allow_empty=True,
            )

            if error:
                result.malformed_rtl += 1
                result.issues.append(
                    f"[{vector_id}] MALFORMED_RTL: {error}"
                )
                continue

        # Keep first occurrence for comparison.
        if vector_id not in indexed:
            indexed[vector_id] = vector

    return indexed, ids


# ============================================================================
# Comparison
# ============================================================================

def compare_vectors(
    golden_vectors: list[dict[str, Any]],
    rtl_vectors: list[dict[str, Any]],
) -> ComparisonResult:

    result = ComparisonResult(
        golden_vectors=len(golden_vectors),
        rtl_vectors=len(rtl_vectors),
    )

    golden = validate_golden_vectors(
        golden_vectors,
        result,
    )

    rtl, rtl_counts = validate_rtl_vectors(
        rtl_vectors,
        result,
    )

    # ------------------------------------------------------------------------
    # Duplicate RTL IDs
    # ------------------------------------------------------------------------

    for vector_id, count in rtl_counts.items():
        if count > 1:
            result.duplicate_rtl += count - 1

            result.issues.append(
                f"[{vector_id}] DUPLICATE_RTL: "
                f"{count} occurrences"
            )

    # ------------------------------------------------------------------------
    # Missing / extra vectors
    # ------------------------------------------------------------------------

    golden_ids = list(golden.keys())
    rtl_ids = list(rtl.keys())

    golden_set = set(golden_ids)
    rtl_set = set(rtl_ids)

    missing_ids = golden_set - rtl_set
    extra_ids = rtl_set - golden_set

    for vector_id in missing_ids:
        result.missing_rtl += 1
        result.issues.append(
            f"[{vector_id}] MISSING_RTL_RESULT"
        )

    for vector_id in extra_ids:
        result.extra_rtl += 1
        result.issues.append(
            f"[{vector_id}] EXTRA_RTL"
        )

    # ------------------------------------------------------------------------
    # Ordering
    # ------------------------------------------------------------------------

    common_golden = [
        vector_id
        for vector_id in golden_ids
        if vector_id in rtl_set
    ]

    common_rtl = [
        vector_id
        for vector_id in rtl_ids
        if vector_id in golden_set
    ]

    if common_golden != common_rtl:
        result.reordered = 1
        result.issues.append(
            "REORDERED: common vector IDs are in different order"
        )

    # ------------------------------------------------------------------------
    # Per-vector comparison
    # ------------------------------------------------------------------------

    for vector_id in golden_ids:

        if vector_id not in rtl:
            continue

        golden_vector = golden[vector_id]
        rtl_vector = rtl[vector_id]

        # ------------------------------------------------------------
        # Optional input comparison
        # ------------------------------------------------------------

        if "input" in rtl_vector:

            golden_input = golden_vector["input"]
            rtl_input = rtl_vector["input"]

            if golden_input.lower() != rtl_input.lower():
                result.input_mismatches += 1

                result.issues.append(
                    f"[{vector_id}] INPUT_MISMATCH: "
                    f"golden={golden_input} "
                    f"rtl={rtl_input}"
                )

                continue

        # ------------------------------------------------------------
        # Output width
        # ------------------------------------------------------------

        expected_output = golden_vector["expected_output"]
        rtl_output = rtl_vector["rtl_output"]

        if len(expected_output) != len(rtl_output):
            result.width_mismatches += 1

            result.issues.append(
                f"[{vector_id}] WIDTH_MISMATCH: "
                f"expected {len(expected_output)} hex characters, "
                f"got {len(rtl_output)}"
            )

            continue

        # ------------------------------------------------------------
        # Output comparison
        # ------------------------------------------------------------

        if expected_output.lower() != rtl_output.lower():
            result.output_mismatches += 1

            result.issues.append(
                f"[{vector_id}] OUTPUT_MISMATCH: "
                f"expected={expected_output} "
                f"rtl={rtl_output}"
            )

            continue

        result.matched += 1

    return result


# ============================================================================
# Text report
# ============================================================================

def print_report(result: ComparisonResult) -> None:

    print()
    print("=" * 68)
    print("PQ-ATTEST CRYPTO VECTOR COMPARISON")
    print("=" * 68)

    print(
        f"STATUS              : "
        f"{'PASS' if result.passed else 'FAIL'}"
    )

    print(
        f"GOLDEN VECTORS      : "
        f"{result.golden_vectors}"
    )

    print(
        f"RTL VECTORS         : "
        f"{result.rtl_vectors}"
    )

    print(
        f"MATCHED             : "
        f"{result.matched}"
    )

    print(
        f"MISSING RTL         : "
        f"{result.missing_rtl}"
    )

    print(
        f"EXTRA RTL           : "
        f"{result.extra_rtl}"
    )

    print(
        f"DUPLICATE RTL       : "
        f"{result.duplicate_rtl}"
    )

    print(
        f"REORDERED           : "
        f"{result.reordered}"
    )

    print(
        f"MALFORMED GOLDEN    : "
        f"{result.malformed_golden}"
    )

    print(
        f"MALFORMED RTL       : "
        f"{result.malformed_rtl}"
    )

    print(
        f"INPUT MISMATCHES    : "
        f"{result.input_mismatches}"
    )

    print(
        f"WIDTH MISMATCHES    : "
        f"{result.width_mismatches}"
    )

    print(
        f"OUTPUT MISMATCHES   : "
        f"{result.output_mismatches}"
    )

    print(
        f"MISSING RTL RESULT  : "
        f"{result.missing_rtl_result}"
    )

    if result.issues:
        print()
        print("ISSUES:")

        for issue in result.issues:
            print(f"  - {issue}")

    print("=" * 68)


# ============================================================================
# JSON report
# ============================================================================

def result_to_dict(result: ComparisonResult) -> dict[str, Any]:
    return {
        "status": "PASS" if result.passed else "FAIL",
        "golden_vectors": result.golden_vectors,
        "rtl_vectors": result.rtl_vectors,
        "matched": result.matched,
        "missing_rtl": result.missing_rtl,
        "extra_rtl": result.extra_rtl,
        "duplicate_rtl": result.duplicate_rtl,
        "reordered": result.reordered,
        "malformed_golden": result.malformed_golden,
        "malformed_rtl": result.malformed_rtl,
        "input_mismatches": result.input_mismatches,
        "width_mismatches": result.width_mismatches,
        "output_mismatches": result.output_mismatches,
        "missing_rtl_result": result.missing_rtl_result,
        "issues": result.issues,
    }


# ============================================================================
# CLI
# ============================================================================

def build_argument_parser() -> argparse.ArgumentParser:

    parser = argparse.ArgumentParser(
        description=(
            "Compare PQ-Attest golden crypto vectors "
            "against RTL results."
        )
    )

    parser.add_argument(
        "--golden",
        required=True,
        help="Golden/reference vector file",
    )

    parser.add_argument(
        "--rtl",
        required=True,
        help="RTL result vector file",
    )

    parser.add_argument(
        "--json",
        action="store_true",
        help="Print result as JSON",
    )

    return parser


def main() -> int:

    parser = build_argument_parser()
    args = parser.parse_args()

    golden_path = Path(args.golden)
    rtl_path = Path(args.rtl)

    try:
        golden_vectors = load_json_vectors(
            golden_path
        )

        rtl_vectors = load_json_vectors(
            rtl_path
        )

    except ValueError as exc:
        print(
            f"FORMAT ERROR: {exc}",
            file=sys.stderr,
        )

        return 2

    result = compare_vectors(
        golden_vectors,
        rtl_vectors,
    )

    if args.json:
        print(
            json.dumps(
                result_to_dict(result),
                indent=2,
            )
        )
    else:
        print_report(result)

    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())