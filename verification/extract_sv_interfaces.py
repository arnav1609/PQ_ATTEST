#!/usr/bin/env python3

"""
PQ-ATTEST P3-0
SystemVerilog Interface Inventory Extractor

Purpose:
    Extract authoritative module-level interfaces from the current RTL.

Important:
    - Does NOT modify RTL.
    - Does NOT infer internal connections.
    - Preserves SystemVerilog package-qualified types.
    - Preserves unpacked array dimensions.
    - Handles ANSI-style declarations with multiple ports
      on the same line.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path(
    "NOC_PQATTEST.srcs"
) / "sources_1" / "new"

DEFAULT_OUTPUT = Path(
    "verification"
) / "sv_interface_inventory.json"


# These are the actual filenames in the current RTL tree.
TARGET_MODULES = {
    "noc_network_interface.sv",
    "noc_router.sv",
    "NOC_XY_ROUTING.sv",
    "noc_credit_counter.sv",
    "noc_addr_decoder.sv",
}


MODULE_RE = re.compile(
    r"""
    \bmodule
    \s+
    (?P<name>[A-Za-z_][A-Za-z0-9_]*)
    \s*
    (?:\#\s*
        \(
            (?P<params>.*?)
        \)
    )?
    \s*
    \(
        (?P<ports>.*?)
    \)
    \s*;
    """,
    re.VERBOSE | re.DOTALL,
)


def strip_comments(text: str) -> str:
    """
    Remove // and /* */ comments while preserving newlines.
    """

    text = re.sub(
        r"/\*.*?\*/",
        lambda m: "\n" * m.group(0).count("\n"),
        text,
        flags=re.DOTALL,
    )

    text = re.sub(
        r"//[^\n]*",
        "",
        text,
    )

    return text


def split_port_declarations(
    port_block: str,
) -> list[str]:
    """
    Split an ANSI-style port list on top-level commas.

    Commas inside:
        []
        ()
    are ignored.
    """

    declarations: list[str] = []

    current: list[str] = []

    square_depth = 0
    paren_depth = 0
    curly_depth = 0

    for char in port_block:

        if char == "[":
            square_depth += 1

        elif char == "]":
            square_depth -= 1

        elif char == "(":
            paren_depth += 1

        elif char == ")":
            paren_depth -= 1

        elif char == "{":
            curly_depth += 1

        elif char == "}":
            curly_depth -= 1

        if (
            char == ","
            and square_depth == 0
            and paren_depth == 0
            and curly_depth == 0
        ):
            declaration = "".join(current).strip()

            if declaration:
                declarations.append(declaration)

            current = []

        else:
            current.append(char)

    declaration = "".join(current).strip()

    if declaration:
        declarations.append(declaration)

    return declarations


# Examples handled:
#
# input logic clk
# output logic out_valid
# input noc_pkg::coord_t current_coord
# input logic [NUM_VC-1:0] credit_return [NUM_PORTS]
# output noc_pkg::flit_t out_flit_north
#
PORT_DECL_RE = re.compile(
    r"""
    ^\s*
    (?P<direction>
        input
        |
        output
        |
        inout
    )
    \s+
    (?P<type>
        .*?
    )
    \s+
    (?P<name>
        [A-Za-z_][A-Za-z0-9_]*
    )
    \s*
    (?P<unpacked>
        (?:
            \[
                [^\]]+
            \]
            \s*
        )+
    )?
    \s*$
    """,
    re.VERBOSE | re.DOTALL,
)


def parse_module_ports(
    text: str,
    source_name: str,
) -> tuple[str, list[dict[str, Any]]]:

    clean = strip_comments(text)

    match = MODULE_RE.search(clean)

    if match is None:
        raise ValueError(
            f"No ANSI module declaration found "
            f"in {source_name}"
        )

    module_name = match.group("name")
    port_block = match.group("ports")

    declarations = split_port_declarations(
        port_block
    )

    ports: list[dict[str, Any]] = []

    for declaration in declarations:

        declaration = " ".join(
            declaration.split()
        )

        match = PORT_DECL_RE.match(
            declaration
        )

        if match is None:
            raise ValueError(
                "Could not parse port declaration "
                f"in {source_name}:\n"
                f"    {declaration}"
            )

        direction = match.group(
            "direction"
        )

        type_text = match.group(
            "type"
        ).strip()

        name = match.group(
            "name"
        )

        unpacked = match.group(
            "unpacked"
        )

        ports.append(
            {
                "name": name,
                "direction": direction,
                "type": type_text,
                "unpacked": (
                    unpacked.strip()
                    if unpacked
                    else None
                ),
            }
        )

    if not ports:
        raise ValueError(
            f"No ports parsed from {source_name}"
        )

    return module_name, ports


def parse_file(
    path: Path,
) -> dict[str, Any]:

    text = path.read_text(
        encoding="utf-8"
    )

    module_name, ports = parse_module_ports(
        text,
        str(path),
    )

    return {
        "file": str(path),
        "module": module_name,
        "ports": ports,
        "port_count": len(ports),
    }


def validate_module_name(
    filename: str,
    module_name: str,
) -> None:

    # These are the expected module names
    # for the current RTL.
    expected = {
        "noc_network_interface.sv":
            "noc_network_interface",

        "noc_router.sv":
            "noc_router",

        "NOC_XY_ROUTING.sv":
            "noc_xy_routing",

        "noc_credit_counter.sv":
            "noc_credit_control",

        "noc_addr_decoder.sv":
            "noc_addr_decoder",
    }

    expected_module = expected.get(filename)

    if expected_module is None:
        return

    if module_name != expected_module:
        raise ValueError(
            f"Module/file mismatch:\n"
            f"  FILE   : {filename}\n"
            f"  EXPECT : {expected_module}\n"
            f"  ACTUAL : {module_name}"
        )


def build_inventory(
    root: Path,
) -> dict[str, Any]:

    results: list[dict[str, Any]] = []

    missing: list[str] = []

    parse_errors: list[str] = []

    for filename in sorted(
        TARGET_MODULES,
        key=str.lower,
    ):

        path = root / filename

        if not path.exists():
            missing.append(
                str(path)
            )
            continue

        try:
            result = parse_file(path)

            validate_module_name(
                filename,
                result["module"],
            )

            results.append(result)

        except Exception as exc:
            parse_errors.append(
                f"{path}: {exc}"
            )

    if missing:
        raise RuntimeError(
            "Required RTL file(s) missing:\n"
            + "\n".join(
                f"  {item}"
                for item in missing
            )
        )

    if parse_errors:
        raise RuntimeError(
            "RTL interface parsing failed:\n"
            + "\n".join(
                f"  {item}"
                for item in parse_errors
            )
        )

    modules = {
        item["module"]
        for item in results
    }

    if len(modules) != len(results):
        raise RuntimeError(
            "Duplicate module names detected "
            "in interface inventory."
        )

    return {
        "tool": "PQ-ATTEST P3-0",
        "format_version": 1,
        "root": str(root),
        "module_count": len(results),
        "modules": results,
    }


def print_inventory(
    inventory: dict[str, Any],
) -> None:

    print(
        "PQ-ATTEST P3-0 "
        "SV INTERFACE INVENTORY"
    )

    print(
        f"ROOT: {inventory['root']}"
    )

    print()

    for module in inventory["modules"]:

        print(
            f"FILE   : {module['file']}"
        )

        print(
            f"MODULE : {module['module']}"
        )

        print(
            f"PORTS  : {module['port_count']}"
        )

        for port in module["ports"]:

            unpacked = (
                f" {port['unpacked']}"
                if port["unpacked"]
                else ""
            )

            print(
                f"  "
                f"{port['direction']:6} "
                f"{port['type']:45} "
                f"{port['name']}"
                f"{unpacked}"
            )

        print()

    print(
        f"STATUS : PASS "
        f"({inventory['module_count']}/"
        f"{len(TARGET_MODULES)} modules parsed)"
    )


def main() -> int:

    parser = argparse.ArgumentParser(
        description=(
            "Extract authoritative "
            "SystemVerilog module interfaces."
        )
    )

    parser.add_argument(
        "--root",
        type=Path,
        default=DEFAULT_ROOT,
        help=(
            "RTL source directory "
            f"(default: {DEFAULT_ROOT})"
        ),
    )

    parser.add_argument(
        "--json",
        type=Path,
        default=None,
        help=(
            "Write interface inventory "
            "to JSON file."
        ),
    )

    args = parser.parse_args()

    root = args.root

    if not root.exists():
        print(
            f"ERROR: RTL root does not exist: "
            f"{root}",
            file=sys.stderr,
        )

        return 2

    try:
        inventory = build_inventory(
            root
        )

    except Exception as exc:

        print(
            f"STATUS : FAIL\n"
            f"ERROR  : {exc}",
            file=sys.stderr,
        )

        return 1

    print_inventory(
        inventory
    )

    if args.json is not None:

        args.json.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        args.json.write_text(
            json.dumps(
                inventory,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        print()
        print(
            f"JSON   : {args.json}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(
        main()
    )