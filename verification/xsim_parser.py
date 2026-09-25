#!/usr/bin/env python3

"""
PQ-Attest Engineer 4
P0-1: XSim Regression / Result Parser

Purpose:
    Parse Vivado/XSim logs and produce a trustworthy PASS/FAIL result.

The parser does NOT trust "RESULT: PASS" by itself.

A simulation is PASS only when:
    - RESULT exists and is PASS
    - TB check count exists and is > 0
    - TB error count exists and is 0
    - no $fatal is detected
    - no assertion failure is detected
    - no real simulator error/fatal is detected
    - simulation terminated normally
    - reported TB error count agrees with detected TB errors

Usage:
    python verification/xsim_parser.py <log>

JSON:
    python verification/xsim_parser.py <log> --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional


# ============================================================
# RESULT DATA
# ============================================================

@dataclass
class XSimResult:
    status: str = "FAIL"

    result: Optional[str] = None

    tb_checks: Optional[int] = None
    tb_errors: Optional[int] = None
    tb_errors_detected: int = 0

    fatal_count: int = 0
    assertion_failures: int = 0

    simulator_errors: int = 0
    simulator_fatals: int = 0

    warnings: int = 0

    terminated_normally: bool = False
    termination_status: str = "UNKNOWN"

    simulation_time: Optional[str] = None

    issues: list[str] = field(default_factory=list)

    detected_result_lines: list[str] = field(default_factory=list)
    detected_error_lines: list[str] = field(default_factory=list)
    detected_fatal_lines: list[str] = field(default_factory=list)


# ============================================================
# REGEX
# ============================================================

RESULT_PATTERNS = [
    re.compile(
        r"\bRESULT\s*[:=]\s*(PASS|FAIL)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bTEST\s+RESULT\s*[:=]\s*(PASS|FAIL)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bFINAL\s+RESULT\s*[:=]\s*(PASS|FAIL)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bSTATUS\s*[:=]\s*(PASS|FAIL)\b",
        re.IGNORECASE,
    ),
]


CHECK_PATTERNS = [
    re.compile(
        r"\bTB\s+CHECKS?\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bTOTAL\s+CHECKS?\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bPASSED\s+TESTS?\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bPASS(?:ED)?\s+COUNT\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
]


ERROR_COUNT_PATTERNS = [
    re.compile(
        r"\bTB\s+ERRORS?\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bFAILED\s+TESTS?\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bFAIL(?:ED)?\s+COUNT\s*[:=]\s*(\d+)\b",
        re.IGNORECASE,
    ),
]


SIM_TIME_PATTERNS = [
    re.compile(
        r"\bSIMULATION\s+TIME\s*[:=]\s*([^\r\n]+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"\bSIM\s+TIME\s*[:=]\s*([^\r\n]+)",
        re.IGNORECASE,
    ),
    re.compile(
        r"\$finish\s+at\s+time\s+([0-9]+(?:\.[0-9]+)?)",
        re.IGNORECASE,
    ),
    re.compile(
        r"\$stop\s+at\s+time\s+([0-9]+(?:\.[0-9]+)?)",
        re.IGNORECASE,
    ),
]


# ============================================================
# BASIC HELPERS
# ============================================================

def first_integer(
    lines: list[str],
    patterns: list[re.Pattern],
) -> Optional[int]:

    for line in lines:
        for pattern in patterns:
            match = pattern.search(line)

            if match:
                return int(match.group(1))

    return None


def collect_result(
    lines: list[str],
) -> tuple[Optional[str], list[str]]:

    results = []
    result_lines = []

    for line in lines:

        for pattern in RESULT_PATTERNS:

            match = pattern.search(line)

            if match:
                results.append(
                    match.group(1).upper()
                )

                result_lines.append(
                    line.strip()
                )

                break

    if not results:
        return None, result_lines

    # Multiple RESULT declarations must agree.
    if len(set(results)) != 1:
        return "MALFORMED", result_lines

    return results[0], result_lines


# ============================================================
# ERROR DETECTION
# ============================================================

def is_tb_error(line: str) -> bool:
    """
    Detect explicit testbench errors.

    Examples:
        $error(...)
        TB ERROR: ...
        TEST ERROR: ...
    """

    stripped = line.strip()

    if re.search(
        r"\$error\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    if re.search(
        r"^(TB|TESTBENCH|TEST)\s+ERROR\s*:",
        stripped,
        re.IGNORECASE,
    ):
        return True

    return False


def is_fatal(line: str) -> bool:
    """
    Detect actual fatal conditions.
    """

    stripped = line.strip()

    if re.search(
        r"\$fatal\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    if re.search(
        r"\bFATAL\s*:",
        stripped,
        re.IGNORECASE,
    ):
        return True

    if re.search(
        r"\bSIMULATOR\s+FATAL\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    # XSim severity:
    # xsim: *F,...
    if re.search(
        r"\bXSIM\b.*\*F,",
        stripped,
        re.IGNORECASE,
    ):
        return True

    return False


def is_assertion_failure(line: str) -> bool:
    """
    Detect assertion/property failures.
    """

    stripped = line.strip()

    patterns = [
        r"\bASSERTION\s+FAIL(?:ED|URE)?\b",
        r"\bASSERT(?:ION)?\s+FAIL(?:ED|URE)?\b",
        r"\bASSERT(?:ION)?\s+ERROR\b",
        r"\bSVA\b.*\bFAIL(?:ED|URE)?\b",
        r"\bPROPERTY\b.*\bFAIL(?:ED|URE)?\b",
        r"\bASSERTION_ERROR\b",
    ]

    return any(
        re.search(
            pattern,
            stripped,
            re.IGNORECASE,
        )
        for pattern in patterns
    )


def is_simulator_error(line: str) -> bool:
    """
    Detect actual simulator/tool errors.

    Testbench errors such as:
        TB ERROR: ...
        TESTBENCH ERROR: ...
        TEST ERROR: ...

    must NOT be classified as simulator errors.
    """

    stripped = line.strip()
    upper = stripped.upper()

    if not stripped:
        return False

    # Testbench-generated errors are NOT simulator errors.
    if re.match(
        r"^(TB|TESTBENCH|TEST)\s+ERROR\s*:",
        stripped,
        re.IGNORECASE,
    ):
        return False

    # SystemVerilog $error is treated as a TB/runtime error.
    if re.search(r"\$error\b", stripped, re.IGNORECASE):
        return False

    # ------------------------------------------------------------
    # Explicitly exclude testbench-generated errors
    # ------------------------------------------------------------
    if re.match(r"^(TB|TESTBENCH|TEST)\s+ERROR\s*:", stripped, re.IGNORECASE):
        return False

    # SystemVerilog $error is a TB/runtime error, not a simulator
    # tool error for our classification purposes.
    if re.search(r"\$error\b", stripped, re.IGNORECASE):
        return False

    # ------------------------------------------------------------
    # Actual simulator / tool error patterns
    # ------------------------------------------------------------

    # Generic explicit ERROR severity:
    # ERROR: something failed
    if re.match(r"^ERROR\s*:", stripped, re.IGNORECASE):
        return True

    # XSim severity format:
    # *E,...
    if re.match(r"^\*E[,:\s]", stripped):
        return True

    # Vivado/XSim/elaborator messages containing ERROR
    if re.search(
        r"\b(VRFC|XSIM|XELAB|USF-XSim)\b.*\bERROR\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    # Simulator/tool fatal-like error messages that are not already
    # handled by the fatal detector.
    if re.search(
        r"\bSIMULATOR\s+ERROR\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    return False
def is_warning(line: str) -> bool:
    """
    Detect simulator/tool warnings.

    Warnings are reported separately and do not cause a PASS
    to become FAIL by themselves.
    """

    stripped = line.strip()

    if not stripped:
        return False

    # XSim/Vivado warning severity.
    if re.match(
        r"^WARNING\s*:",
        stripped,
        re.IGNORECASE,
    ):
        return True

    # XSim warning severity.
    if re.match(
        r"^\*W[,:\s]",
        stripped,
        re.IGNORECASE,
    ):
        return True

    # Common Vivado/XSim tool warnings.
    if re.search(
        r"\b(VRFC|XSIM|XELAB|USF-XSim)\b.*\bWARNING\b",
        stripped,
        re.IGNORECASE,
    ):
        return True

    return False


# ============================================================
# SIMULATION TERMINATION
# ============================================================

def determine_termination(
    lines: list[str],
    result: XSimResult,
) -> None:

    text = "\n".join(lines)

    # Fatal takes priority.
    if result.fatal_count > 0 or result.simulator_fatals > 0:

        result.terminated_normally = False
        result.termination_status = "FATAL"

        return

    # Normal simulator completion.
    if re.search(
        r"\$finish\b",
        text,
        re.IGNORECASE,
    ):

        result.terminated_normally = True
        result.termination_status = "NORMAL"

        return

    # Other abnormal termination messages.
    if re.search(
        r"\b(?:ABORTED|CRASHED|TERMINATED\s+ABNORMALLY)\b",
        text,
        re.IGNORECASE,
    ):

        result.terminated_normally = False
        result.termination_status = "ABNORMAL"

        return

    result.terminated_normally = False
    result.termination_status = "UNKNOWN"


# ============================================================
# SIMULATION TIME
# ============================================================

def extract_simulation_time(
    lines: list[str],
) -> Optional[str]:

    for line in lines:

        for pattern in SIM_TIME_PATTERNS:

            match = pattern.search(line)

            if match:
                return match.group(1).strip()

    return None


# ============================================================
# MAIN PARSER
# ============================================================

def parse_xsim_log(text: str) -> XSimResult:

    result = XSimResult()

    lines = text.splitlines()

    # --------------------------------------------------------
    # RESULT
    # --------------------------------------------------------

    (
        result.result,
        result.detected_result_lines,
    ) = collect_result(lines)

    if result.result is None:

        result.issues.append(
            "missing RESULT"
        )

    elif result.result == "MALFORMED":

        result.issues.append(
            "malformed/inconsistent RESULT"
        )

    # --------------------------------------------------------
    # CHECK / ERROR COUNTS
    # --------------------------------------------------------

    result.tb_checks = first_integer(
        lines,
        CHECK_PATTERNS,
    )

    result.tb_errors = first_integer(
        lines,
        ERROR_COUNT_PATTERNS,
    )

    if result.tb_checks is None:

        result.issues.append(
            "missing TB check count"
        )

    elif result.tb_checks <= 0:

        result.issues.append(
            "invalid TB check count: "
            f"{result.tb_checks}"
        )

    if result.tb_errors is None:

        result.issues.append(
            "missing TB error count"
        )

    # --------------------------------------------------------
    # SCAN LOG
    # --------------------------------------------------------

    tb_error_lines = []
    fatal_lines = []
    assertion_lines = []
    simulator_error_lines = []
    simulator_fatal_lines = []

    for line in lines:

        if is_tb_error(line):
            tb_error_lines.append(
                line.strip()
            )

        if is_fatal(line):
            fatal_lines.append(
                line.strip()
            )

        if is_assertion_failure(line):
            assertion_lines.append(
                line.strip()
            )

        if is_simulator_error(line):
            simulator_error_lines.append(
                line.strip()
            )

        if is_warning(line):
            result.warnings += 1

    # --------------------------------------------------------
    # Separate simulator fatal from normal simulator errors
    # --------------------------------------------------------

    for line in simulator_error_lines:

        if re.search(
            r"\bFATAL\b|\*F,",
            line,
            re.IGNORECASE,
        ):
            simulator_fatal_lines.append(line)

    result.tb_errors_detected = len(
        tb_error_lines
    )

    result.fatal_count = len(
        fatal_lines
    )

    result.assertion_failures = len(
        assertion_lines
    )

    result.simulator_fatals = len(
        simulator_fatal_lines
    )

    result.simulator_errors = (
        len(simulator_error_lines)
        - result.simulator_fatals
    )

    result.detected_error_lines = (
        tb_error_lines
        + simulator_error_lines
        + assertion_lines
    )

    result.detected_fatal_lines = (
        fatal_lines
        + simulator_fatal_lines
    )

    # --------------------------------------------------------
    # ERROR COUNT CONSISTENCY
    # --------------------------------------------------------

    if result.tb_errors is not None:

        if (
            result.tb_errors
            != result.tb_errors_detected
        ):

            result.issues.append(
                "inconsistent TB error count: "
                f"reported={result.tb_errors}, "
                f"detected={result.tb_errors_detected}"
            )

    # --------------------------------------------------------
    # PASS CONSISTENCY
    # --------------------------------------------------------

    if result.result == "PASS":

        if result.tb_checks is not None:

            if result.tb_checks <= 0:

                result.issues.append(
                    "PASS reported with zero TB checks"
                )

        if result.tb_errors is not None:

            if result.tb_errors != 0:

                result.issues.append(
                    "RESULT PASS but TB error count "
                    "is non-zero"
                )

        if result.tb_errors_detected > 0:

            result.issues.append(
                "RESULT PASS but explicit TB error "
                "was detected"
            )

        if result.fatal_count > 0:

            result.issues.append(
                "RESULT PASS but fatal condition "
                "was detected"
            )

        if result.assertion_failures > 0:

            result.issues.append(
                "RESULT PASS but assertion failure "
                "was detected"
            )

        if result.simulator_errors > 0:

            result.issues.append(
                "RESULT PASS but simulator error "
                "was detected"
            )

        if result.simulator_fatals > 0:

            result.issues.append(
                "RESULT PASS but simulator fatal "
                "was detected"
            )

    # --------------------------------------------------------
    # TERMINATION
    # --------------------------------------------------------

    determine_termination(
        lines,
        result,
    )

    if (
        result.result == "PASS"
        and not result.terminated_normally
    ):

        result.issues.append(
            "RESULT PASS but simulation did not "
            "terminate normally"
        )

    # --------------------------------------------------------
    # SIMULATION TIME
    # --------------------------------------------------------

    result.simulation_time = (
        extract_simulation_time(lines)
    )

    # --------------------------------------------------------
    # FINAL STATUS
    # --------------------------------------------------------

    if result.issues:

        result.status = "FAIL"

    elif result.result == "FAIL":

        result.status = "FAIL"

    elif result.result == "PASS":

        result.status = "PASS"

    else:

        result.status = "FAIL"

    return result


# ============================================================
# FILE PARSER
# ============================================================

def parse_xsim_file(
    path: str | Path,
) -> XSimResult:

    path = Path(path)

    if not path.exists():

        result = XSimResult()

        result.issues.append(
            f"log file does not exist: {path}"
        )

        return result

    try:

        text = path.read_text(
            encoding="utf-8",
            errors="replace",
        )

    except OSError as exc:

        result = XSimResult()

        result.issues.append(
            f"unable to read log: {exc}"
        )

        return result

    return parse_xsim_log(text)


# ============================================================
# CLI
# ============================================================

def main() -> int:

    parser = argparse.ArgumentParser(
        description=(
            "Parse Vivado/XSim simulation logs "
            "for trustworthy PASS/FAIL results."
        )
    )

    parser.add_argument(
        "log",
        type=Path,
        help="Path to XSim simulation log",
    )

    parser.add_argument(
        "--json",
        action="store_true",
        help="Output machine-readable JSON",
    )

    args = parser.parse_args()

    result = parse_xsim_file(
        args.log
    )

    # --------------------------------------------------------
    # JSON
    # --------------------------------------------------------

    if args.json:

        print(
            json.dumps(
                asdict(result),
                indent=2,
            )
        )

    # --------------------------------------------------------
    # Human-readable
    # --------------------------------------------------------

    else:

        print()
        print("=" * 65)
        print("PQ-ATTEST XSIM REGRESSION RESULT")
        print("=" * 65)

        print(
            f"STATUS              : "
            f"{result.status}"
        )

        print(
            f"RESULT              : "
            f"{result.result}"
        )

        print(
            f"TB CHECKS           : "
            f"{result.tb_checks}"
        )

        print(
            f"TB ERRORS           : "
            f"{result.tb_errors}"
        )

        print(
            f"TB ERRORS DETECTED  : "
            f"{result.tb_errors_detected}"
        )

        print(
            f"FATAL COUNT         : "
            f"{result.fatal_count}"
        )

        print(
            f"ASSERTION FAILURES  : "
            f"{result.assertion_failures}"
        )

        print(
            f"SIMULATOR ERRORS    : "
            f"{result.simulator_errors}"
        )

        print(
            f"SIMULATOR FATALS    : "
            f"{result.simulator_fatals}"
        )

        print(
            f"WARNINGS            : "
            f"{result.warnings}"
        )

        print(
            f"TERMINATION         : "
            f"{result.termination_status}"
        )

        print(
            f"SIMULATION TIME     : "
            f"{result.simulation_time}"
        )

        if result.issues:

            print()
            print("ISSUES:")

            for issue in result.issues:

                print(
                    f"  - {issue}"
                )

        print("=" * 65)
        print()

    return (
        0
        if result.status == "PASS"
        else 1
    )


if __name__ == "__main__":
    sys.exit(main())