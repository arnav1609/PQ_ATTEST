import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COMPARATOR = ROOT / "verification" / "crypto_compare.py"
TESTS = ROOT / "verification" / "tests"

GOLDEN = TESTS / "crypto_golden.json"


def run_case(
    rtl_file: str,
    expected_status: str,
    required_text: str,
):
    rtl_path = TESTS / rtl_file

    result = subprocess.run(
        [
            sys.executable,
            str(COMPARATOR),
            "--golden",
            str(GOLDEN),
            "--rtl",
            str(rtl_path),
        ],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )

    output = result.stdout + result.stderr

    assert result.returncode in (0, 1), (
        f"{rtl_file}: unexpected comparator exit code "
        f"{result.returncode}\n"
        f"Output:\n{output}"
    )

    assert expected_status in output, (
        f"{rtl_file}: expected {expected_status}\n"
        f"Output:\n{output}"
    )

    assert required_text in output, (
        f"{rtl_file}: expected '{required_text}'\n"
        f"Output:\n{output}"
    )


# ============================================================================
# Existing P0-2 regression tests
# ============================================================================

def test_clean_pass():
    run_case(
        "crypto_rtl_pass.json",
        "STATUS              : PASS",
        "MATCHED             : 3",
    )


def test_wrong_output():
    run_case(
        "crypto_rtl_bad.json",
        "STATUS              : FAIL",
        "OUTPUT_MISMATCH",
    )


def test_missing_rtl():
    run_case(
        "crypto_rtl_missing.json",
        "STATUS              : FAIL",
        "MISSING_RTL",
    )


def test_extra_rtl():
    run_case(
        "crypto_rtl_extra.json",
        "STATUS              : FAIL",
        "EXTRA_RTL",
    )


def test_duplicate_rtl():
    run_case(
        "crypto_rtl_duplicate.json",
        "STATUS              : FAIL",
        "DUPLICATE_RTL",
    )


def test_reordered_rtl():
    run_case(
        "crypto_rtl_reordered.json",
        "STATUS              : FAIL",
        "REORDERED",
    )


def test_malformed_rtl():
    run_case(
        "crypto_rtl_malformed.json",
        "STATUS              : FAIL",
        "MALFORMED_RTL",
    )


def test_wrong_width():
    run_case(
        "crypto_rtl_wrong_width.json",
        "STATUS              : FAIL",
        "WIDTH_MISMATCH",
    )


# ============================================================================
# Empty-input regression
# ============================================================================

def test_empty_input_is_valid():
    """
    SHA3-256 permits an empty message.

    Therefore:
        "input": ""

    must not be reported as MALFORMED_GOLDEN.
    """

    result = subprocess.run(
        [
            sys.executable,
            str(COMPARATOR),
            "--golden",
            str(TESTS / "crypto_empty_input_golden.json"),
            "--rtl",
            str(TESTS / "crypto_empty_input_rtl.json"),
        ],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )

    output = result.stdout + result.stderr

    assert "STATUS              : PASS" in output
    assert "MALFORMED GOLDEN    : 0" in output
    assert "MATCHED             : 1" in output