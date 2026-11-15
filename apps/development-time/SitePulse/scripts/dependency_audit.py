#!/usr/bin/env python3
"""Known-vulnerability audit of the SitePulse lock files against OSV (https://osv.dev).

Reads the exact versions pinned in `backend/Cargo.lock` (crates.io) and
`flutter/pubspec.lock` (pub.dev), asks the OSV database which of them have a
published advisory (RustSec, GitHub Security Advisories), and fails when an
advisory is not covered by an unexpired allowlist entry.

Only public package names and versions leave the machine. No toolchain is
needed: the script uses the Python standard library.

Allowlist (`scripts/dependency_audit_allowlist.json`), one entry per accepted
advisory, each with a reason and an expiry date after which it fails again:

    [{"id": "RUSTSEC-2024-0001", "package": "example", "reason": "...", "expires": "2027-01-31"}]

Usage:
    python3 scripts/dependency_audit.py            # human-readable
    python3 scripts/dependency_audit.py --json     # machine-readable
    python3 scripts/dependency_audit.py --offline  # parse lock files only (no network)

Exit code 0 when no unaccepted advisory applies, 1 when one does, 2 when the
audit could not run (OSV unreachable, unreadable lock file). A run that could
not reach OSV is never reported as passed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CARGO_LOCK = ROOT / "backend" / "Cargo.lock"
DEFAULT_PUBSPEC_LOCK = ROOT / "flutter" / "pubspec.lock"
DEFAULT_ALLOWLIST = ROOT / "scripts" / "dependency_audit_allowlist.json"
OSV_API = "https://api.osv.dev/v1"
BATCH_SIZE = 500
TIMEOUT_S = 30


@dataclass(frozen=True)
class Package:
    ecosystem: str
    name: str
    version: str


@dataclass
class Advisory:
    id: str
    ecosystem: str
    package: str
    version: str
    summary: str = ""
    severity: str = ""
    fixed: List[str] = field(default_factory=list)
    aliases: List[str] = field(default_factory=list)
    accepted: bool = False
    accepted_reason: str = ""


class AuditError(Exception):
    """The audit could not be carried out (as opposed to: it found advisories)."""


def parse_cargo_lock(text: str) -> List[Package]:
    """Registry packages of a Cargo.lock; path and git dependencies are skipped."""
    packages = []
    for block in text.split("[[package]]")[1:]:
        name = re.search(r'^name = "([^"]+)"', block, re.M)
        version = re.search(r'^version = "([^"]+)"', block, re.M)
        source = re.search(r'^source = "([^"]+)"', block, re.M)
        if name and version and source and source.group(1).startswith("registry+"):
            packages.append(Package("crates.io", name.group(1), version.group(1)))
    return packages


def parse_pubspec_lock(text: str) -> List[Package]:
    """Hosted packages of a pubspec.lock; sdk, path and git dependencies are skipped."""
    packages = []
    name: Optional[str] = None
    fields: Dict[str, str] = {}

    def flush() -> None:
        if name and fields.get("source") == "hosted" and fields.get("version"):
            packages.append(Package("Pub", name, fields["version"]))

    in_packages = False
    for line in text.splitlines():
        if not line.startswith(" "):
            flush()
            name, fields = None, {}
            in_packages = line.strip() == "packages:"
            continue
        if not in_packages:
            continue
        entry = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
        if entry:
            flush()
            name, fields = entry.group(1), {}
            continue
        attribute = re.match(r'^    (source|version):\s*"?([^"\s]+)"?\s*$', line)
        if attribute and name:
            fields[attribute.group(1)] = attribute.group(2)
    flush()
    return packages


def _post(url: str, payload: dict) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "dependency-audit"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise AuditError(f"OSV request failed ({url}): {error}") from error


def _get(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "dependency-audit"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            return json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise AuditError(f"OSV request failed ({url}): {error}") from error


def query_osv(packages: List[Package]) -> List[Tuple[Package, str]]:
    """(package, advisory id) pairs for every pinned version with a published advisory."""
    hits: List[Tuple[Package, str]] = []
    for start in range(0, len(packages), BATCH_SIZE):
        chunk = packages[start:start + BATCH_SIZE]
        queries = [
            {"package": {"name": p.name, "ecosystem": p.ecosystem}, "version": p.version} for p in chunk
        ]
        results = _post(f"{OSV_API}/querybatch", {"queries": queries}).get("results", [])
        if len(results) != len(chunk):
            raise AuditError("OSV returned an unexpected number of results")
        for package, result in zip(chunk, results):
            for vuln in result.get("vulns", []) or []:
                hits.append((package, vuln["id"]))
    return hits


def _fixed_versions(detail: dict, package: Package) -> List[str]:
    fixed = []
    for affected in detail.get("affected", []):
        if affected.get("package", {}).get("name") != package.name:
            continue
        for rng in affected.get("ranges", []):
            for event in rng.get("events", []):
                if "fixed" in event and event["fixed"] not in fixed:
                    fixed.append(event["fixed"])
    return fixed


def _severity(detail: dict) -> str:
    label = (detail.get("database_specific") or {}).get("severity")
    if label:
        return str(label).upper()
    for affected in detail.get("affected", []):
        for key in ("database_specific", "ecosystem_specific"):
            specific = affected.get(key) or {}
            if specific.get("severity"):
                return str(specific["severity"]).upper()
            if specific.get("informational"):
                return f"INFO ({specific['informational']})"
    return "UNKNOWN"


def describe(hits: Iterable[Tuple[Package, str]]) -> List[Advisory]:
    advisories = []
    details: Dict[str, dict] = {}
    for package, vuln_id in hits:
        if vuln_id not in details:
            details[vuln_id] = _get(f"{OSV_API}/vulns/{vuln_id}")
        detail = details[vuln_id]
        advisories.append(
            Advisory(
                id=vuln_id,
                ecosystem=package.ecosystem,
                package=package.name,
                version=package.version,
                summary=(detail.get("summary") or detail.get("details", "")).strip().splitlines()[0][:160]
                if (detail.get("summary") or detail.get("details"))
                else "",
                severity=_severity(detail),
                fixed=_fixed_versions(detail, package),
                aliases=list(detail.get("aliases", [])),
            )
        )
    return merge_aliases(advisories)


def merge_aliases(advisories: List[Advisory]) -> List[Advisory]:
    """One entry per vulnerability: a RustSec id and its GHSA alias describe the same flaw."""
    merged: List[Advisory] = []
    for advisory in advisories:
        ids = {advisory.id, *advisory.aliases}
        twin = next(
            (m for m in merged
             if m.package == advisory.package and m.version == advisory.version and ids & {m.id, *m.aliases}),
            None,
        )
        if twin is None:
            merged.append(advisory)
            continue
        twin.aliases = sorted(({twin.id, *twin.aliases} | ids) - {twin.id})
        if twin.severity == "UNKNOWN":
            twin.severity = advisory.severity
        twin.fixed = twin.fixed or advisory.fixed
    return merged


def load_allowlist(path: Path) -> List[dict]:
    if not path.exists():
        return []
    entries = json.loads(path.read_text())
    if not isinstance(entries, list):
        raise AuditError(f"{path} must contain a JSON list")
    for entry in entries:
        for key in ("id", "package", "reason", "expires"):
            if not str(entry.get(key, "")).strip():
                raise AuditError(f"{path}: every entry needs id, package, reason and expires ({entry})")
        try:
            dt.date.fromisoformat(entry["expires"])
        except ValueError as error:
            raise AuditError(f"{path}: invalid expires date in {entry}") from error
    return entries


def apply_allowlist(advisories: List[Advisory], allowlist: List[dict], today: dt.date) -> List[str]:
    """Marks accepted advisories; returns notes about expired or unused allowlist entries."""
    notes = []
    used = set()
    for advisory in advisories:
        ids = {advisory.id, *advisory.aliases}
        for index, entry in enumerate(allowlist):
            if entry["id"] in ids and entry["package"] == advisory.package:
                used.add(index)
                if dt.date.fromisoformat(entry["expires"]) >= today:
                    advisory.accepted = True
                    advisory.accepted_reason = entry["reason"]
                else:
                    notes.append(f"allowlist entry {entry['id']} ({entry['package']}) expired {entry['expires']}")
    for index, entry in enumerate(allowlist):
        if index not in used:
            notes.append(f"allowlist entry {entry['id']} ({entry['package']}) no longer applies; remove it")
    return notes


def read_packages(cargo_lock: Path, pubspec_lock: Path) -> List[Package]:
    packages: List[Package] = []
    for path, parser in ((cargo_lock, parse_cargo_lock), (pubspec_lock, parse_pubspec_lock)):
        if not path.exists():
            raise AuditError(f"lock file not found: {path}")
        parsed = parser(path.read_text())
        if not parsed:
            raise AuditError(f"no packages parsed from {path}")
        packages.extend(parsed)
    return sorted(set(packages), key=lambda p: (p.ecosystem, p.name, p.version))


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cargo-lock", type=Path, default=DEFAULT_CARGO_LOCK)
    parser.add_argument("--pubspec-lock", type=Path, default=DEFAULT_PUBSPEC_LOCK)
    parser.add_argument("--allowlist", type=Path, default=DEFAULT_ALLOWLIST)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--offline", action="store_true", help="parse the lock files only; exits 2 (not audited)")
    args = parser.parse_args(argv)

    try:
        packages = read_packages(args.cargo_lock, args.pubspec_lock)
        allowlist = load_allowlist(args.allowlist)
        if args.offline:
            message = f"{len(packages)} packages parsed; not audited (--offline)"
            print(json.dumps({"status": "NOT_AUDITED", "packages": len(packages)}) if args.json else message)
            return 2
        advisories = describe(query_osv(packages))
        notes = apply_allowlist(advisories, allowlist, dt.date.today())
    except AuditError as error:
        if args.json:
            print(json.dumps({"status": "ERROR", "error": str(error)}))
        else:
            print(f"dependency-audit: could not run: {error}", file=sys.stderr)
        return 2

    open_advisories = [a for a in advisories if not a.accepted]
    stale = [n for n in notes if "expired" in n]
    failed = bool(open_advisories or stale)
    if args.json:
        print(json.dumps({
            "status": "FAIL" if failed else "PASS",
            "packages": len(packages),
            "open": [asdict(a) for a in open_advisories],
            "accepted": [asdict(a) for a in advisories if a.accepted],
            "notes": notes,
        }, indent=2))
    else:
        print(f"dependency-audit: {len(packages)} pinned packages checked against OSV")
        for advisory in advisories:
            state = "accepted" if advisory.accepted else "OPEN"
            fixed = f" fixed in {', '.join(advisory.fixed)}" if advisory.fixed else " no fixed version"
            print(f"  [{state}] {advisory.id} {advisory.ecosystem}:{advisory.package} {advisory.version}"
                  f" [{advisory.severity}]{fixed}\n      {advisory.summary}")
        for note in notes:
            print(f"  note: {note}")
        print("FAIL" if failed else "PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
