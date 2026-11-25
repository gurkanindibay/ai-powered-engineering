#!/usr/bin/env python3
"""Validate tenant applicability classifications against OpenAPI and Rust routes.

Each inventory entry describes how an operation relates to tenant scope and
lists any mapped runtime tests. A mapped test is written as
``e2e/<file>.py::<test function>`` and must exist; it is counted without assuming
it has run or passed. Only module-level test functions resolve, not methods of a
test class.
"""
from __future__ import annotations

import argparse
import ast
from collections import Counter
from functools import lru_cache
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
METHODS = frozenset({"GET", "PUT", "POST", "DELETE", "OPTIONS", "HEAD", "PATCH", "TRACE"})
APPLICABILITY = ("tenant_reference", "implicit_tenant_scope", "outside_scope")
RUNTIME_EVIDENCE_REQUIRED = frozenset({"tenant_reference", "implicit_tenant_scope"})
ROUTE_BLOCK = re.compile(r"^routes!\s*\{(?P<routes>.*?)^\}", re.MULTILINE | re.DOTALL)
ROUTE_ENTRY = re.compile(r'^\s*(?P<method>[a-z]+)\s+"(?P<path>[^"]+)"\s*=>', re.MULTILINE)

Operation = tuple[str, str]


def _operation_name(operation: Operation) -> str:
    return " ".join(operation)


def _names(operations) -> list[str]:
    return [_operation_name(operation) for operation in sorted(operations)]


def _unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _load_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object)


def openapi_operations(document: object) -> set[Operation]:
    if not isinstance(document, dict) or not isinstance(document.get("paths"), dict):
        raise ValueError("OpenAPI document must contain a paths object")
    operations = set()
    for path, item in document["paths"].items():
        if path.startswith("x-"):
            continue
        if not path.startswith("/") or not isinstance(item, dict):
            raise ValueError(f"invalid OpenAPI path item {path!r}")
        if "$ref" in item:
            raise ValueError(f"unresolved OpenAPI path item reference at {path}")
        for method, operation in item.items():
            if method.upper() not in METHODS:
                continue
            if method != method.lower() or not isinstance(operation, dict):
                raise ValueError(f"invalid OpenAPI operation {method} {path}")
            operations.add((method.upper(), path))
    if not operations:
        raise ValueError("OpenAPI document has no operations")
    return operations


def registered_operations(source: str) -> Counter[Operation]:
    block = ROUTE_BLOCK.search(source)
    if block is None:
        raise ValueError("could not find the routes! declaration block")
    operations = Counter()
    for entry in ROUTE_ENTRY.finditer(block["routes"]):
        method = entry["method"].upper()
        if method not in METHODS:
            raise ValueError(f"unsupported registered method {method}")
        # Match the generator's conversion of legacy :param path segments.
        path = "/".join(f"{{{part[1:]}}}" if part.startswith(":") else part
                        for part in entry["path"].split("/"))
        operations[method, path] += 1
    if not operations:
        raise ValueError("routes! block has no registered operations")
    return operations


@lru_cache(maxsize=None)
def _test_functions(path: Path) -> frozenset[str]:
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as error:
        raise ValueError(f"syntax error in {path}, line {error.lineno}: {error.msg}") from error
    return frozenset(
        node.name for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_")
    )


def _resolves(reference: str, test_root: Path) -> bool:
    """Whether ``e2e/<file>.py::<test function>`` names a test under ``test_root``."""
    file_name, separator, function = reference.partition("::")
    if not separator or not file_name.startswith("e2e/") or not file_name.endswith(".py"):
        return False
    path = (test_root / file_name).resolve()
    if not path.is_relative_to((test_root / "e2e").resolve()) or not path.is_file():
        return False
    return function in _test_functions(path)


def _inventory_rows(document: object) -> list[object]:
    if (not isinstance(document, dict) or type(document.get("version")) is not int
            or document["version"] != 1 or not isinstance(document.get("operations"), list)):
        raise ValueError("inventory must contain version 1 and an operations array")
    return document["operations"]


def validate(document: object, spec: set[Operation], routes: Counter[Operation], *,
             require_runtime_evidence: bool = False, test_root: Path | None = None) -> dict:
    inventory = Counter()
    classified: dict[Operation, str] = {}
    with_runtime_tests: set[Operation] = set()
    invalid = []
    unresolved = []
    for number, row in enumerate(_inventory_rows(document), start=1):
        if not isinstance(row, dict):
            invalid.append(f"row {number}: expected an object")
            continue
        method, path = row.get("method"), row.get("path")
        if (not isinstance(method, str) or method not in METHODS
                or not isinstance(path, str) or not path.startswith("/")):
            invalid.append(f"row {number}: expected an uppercase HTTP method and absolute path")
            continue
        operation = (method, path)
        inventory[operation] += 1
        name = _operation_name(operation)
        applicability = row.get("applicability")
        before = len(invalid)
        if applicability not in APPLICABILITY:
            invalid.append(f"{name}: invalid applicability {applicability!r}")
        for field in ("reason", "evidence"):
            value = row.get(field)
            if not isinstance(value, str) or not value.strip():
                invalid.append(f"{name}: {field} must be a nonempty string")
        runtime_tests = row.get("runtime_tests")
        if not isinstance(runtime_tests, list) or any(
            not isinstance(reference, str) or not reference.strip() for reference in runtime_tests
        ):
            invalid.append(f"{name}: runtime_tests must be an array of nonempty test references")
        elif len({reference.strip() for reference in runtime_tests}) != len(runtime_tests):
            invalid.append(f"{name}: runtime_tests contains duplicate references")
        if len(invalid) == before:
            classified[operation] = applicability
            broken = [] if test_root is None else [
                reference for reference in runtime_tests if not _resolves(reference, test_root)
            ]
            unresolved.extend(f"{name}: {reference}" for reference in broken)
            if runtime_tests and not broken:
                with_runtime_tests.add(operation)

    valid_operations = {operation for operation in spec & classified.keys() if inventory[operation] == 1}
    counts = Counter(classified[operation] for operation in valid_operations)
    tested = Counter(classified[operation] for operation in valid_operations & with_runtime_tests)
    runtime_evidence_missing = _names(
        operation for operation in valid_operations - with_runtime_tests
        if classified[operation] in RUNTIME_EVIDENCE_REQUIRED
    )
    result = {
        "openapi_operations": len(spec),
        "registered_operations": len(routes),
        "inventory_rows": sum(inventory.values()),
        "applicability_counts": {kind: counts[kind] for kind in APPLICABILITY},
        "runtime_coverage": {
            kind: {"tested": tested[kind], "uncovered": counts[kind] - tested[kind]}
            for kind in APPLICABILITY
        },
        "runtime_evidence_required": require_runtime_evidence,
        "runtime_evidence_missing": runtime_evidence_missing,
        "missing": _names(spec - inventory.keys()),
        "stale": _names(inventory.keys() - spec),
        "duplicates": _names(operation for operation, count in inventory.items() if count > 1),
        "invalid": invalid,
        "unresolved_runtime_tests": unresolved,
        "routes_missing_from_openapi": _names(routes.keys() - spec),
        "openapi_missing_from_routes": _names(spec - routes.keys()),
        "duplicate_registered_routes": _names(operation for operation, count in routes.items() if count > 1),
    }
    result["ok"] = not any(result[key] for key in (
        "missing", "stale", "duplicates", "invalid", "unresolved_runtime_tests",
        "routes_missing_from_openapi",
        "openapi_missing_from_routes", "duplicate_registered_routes",
    )) and (not require_runtime_evidence or not runtime_evidence_missing)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=ROOT / "e2e/nightly/tenant_operation_inventory.json",
                        help="tenant applicability inventory JSON")
    parser.add_argument("--openapi", type=Path, default=ROOT / "docs/api/openapi.json",
                        help="generated OpenAPI JSON file")
    parser.add_argument("--routes", type=Path, default=ROOT / "backend/src/app.rs",
                        help="Rust source containing the routes! declarations")
    parser.add_argument("--test-root", type=Path, default=ROOT,
                        help="directory the e2e/... runtime test references are relative to")
    parser.add_argument("--require-runtime-evidence", action="store_true",
                        help="require at least one mapped runtime test per applicable tenant operation")
    parser.add_argument("--json", action="store_true", help="emit the validation report as JSON")
    args = parser.parse_args(argv)
    try:
        spec = openapi_operations(_load_json(args.openapi))
        routes = registered_operations(args.routes.read_text(encoding="utf-8"))
        result = validate(_load_json(args.inventory), spec, routes,
                          require_runtime_evidence=args.require_runtime_evidence,
                          test_root=args.test_root)
    except (ValueError, OSError) as error:
        if args.json:
            print(json.dumps({"ok": False, "error": str(error)}, indent=2))
        else:
            print(f"tenant operation inventory: {error}", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status = "complete" if result["ok"] else "has validation findings"
        print(f"Tenant operation inventory {status}: {sum(result['applicability_counts'].values())}"
              f"/{result['openapi_operations']} OpenAPI operations classified.")
        for applicability, counts in result["runtime_coverage"].items():
            print(f"  {applicability}: {counts['tested']} mapped, {counts['uncovered']} uncovered")
        for category, entries in result.items():
            if category == "runtime_evidence_missing" and not args.require_runtime_evidence:
                continue
            if isinstance(entries, list) and entries:
                print(f"{category.replace('_', ' ')}: {len(entries)}", file=sys.stderr)
                for entry in entries:
                    print(f"  {entry}", file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
