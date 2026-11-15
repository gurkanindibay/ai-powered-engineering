#!/usr/bin/env python3
"""Lint: the SitePulse Rust backend follows docs/standards/RUST_STANDARDS.md (sections 10-16).

Hard rules (any finding fails):
* `domain-purity`          `src/domain/` has no Axum, PostgreSQL, AppState, service, handler,
                           environment or tracing-subscriber dependency.
* `layering`               only `handlers`, `app.rs` and `main.rs` may import `crate::handlers`.
* `inline-email`           email values are normalized only by `domain::email`
                           (`NormalizedEmail::normalize` / `same_email`), never `email.to_lowercase()`.
* `inline-turkish-fold`    Turkish letters are folded only by `domain::text::fold_turkish`.
* `inline-iban-check`      IBANs are validated only by `domain::iban::TrIban`
                           (no hand-written `starts_with("TR")` / length checks).
* `regex-per-call`         `Regex::new` only inside a `static ...: LazyLock<...>` initializer.
* `implicit-rounding`      money is never rounded with `round_dp(..)` (implicit strategy);
                           use `round_dp_with_strategy` or `domain::apportion`.
* `float-money`            no `f32` / `f64` anywhere in `src/`.
* `ad-hoc-hash`            SHA-256 / HMAC only in `domain::fingerprint` (and the allow-listed
                           token hash in `auth.rs` and migration checksums in `migrations.rs`).
* `non-english-identifier` identifiers are ASCII English (Turkish text belongs in string literals).
* `domain-unformatted`     every file under `src/domain/` is `rustfmt`-clean.
* `query-flatten`          a struct extracted with `Query<T>` has no `#[serde(flatten)]` field:
                           flattening makes `serde_urlencoded` buffer values as strings, so
                           numeric parameters such as `page=1` fail with "expected i64".

Ratchet rules (counts may only go down; `--update-baseline` records a lower count):
* `unwrap`              `.unwrap()` outside test code.
* `expect`              `.expect(` outside test code.
* `string-error`        `Result<_, String>` signatures in `src/services/` (target: typed errors).
* `pool-branch`         `if let Some(pool)` / `state.pool` branches (target: repository ports).
* `unformatted-file`    files that `cargo fmt --check` would change.

Only code is checked: comments, string literals and `#[cfg(test)]` modules are ignored by the
pattern rules.

Usage:
    python3 scripts/rust_standards_lint.py                    # human-readable, exit 1 on findings
    python3 scripts/rust_standards_lint.py --json             # machine-readable
    python3 scripts/rust_standards_lint.py --update-baseline  # lower the ratchet after paying debt
    python3 scripts/rust_standards_lint.py --no-fmt           # skip the rustfmt-based rules
    python3 scripts/rust_standards_lint.py --root backend --baseline scripts/rust_standards_baseline.json
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BACKEND = ROOT / "backend"
DEFAULT_BASELINE = ROOT / "scripts" / "rust_standards_baseline.json"

DOMAIN_FORBIDDEN_RE = re.compile(
    r"\b(?:axum|tokio_postgres|deadpool_postgres|tracing_subscriber|reqwest)::"
    r"|\bcrate::(?:state|db|handlers|services|auth|app|scheduler)\b"
    r"|\bstd::env\b|\benv::var\("
)
HANDLERS_IMPORT_RE = re.compile(r"\bcrate::handlers\b")
INLINE_EMAIL_RE = re.compile(r"\b\w*email\w*(?:\.as_deref\(\)\.unwrap_or\(\"\"\))?(?:\.trim\(\))?\.to_lowercase\(\)")
TURKISH_LETTER_CHAR_RE = re.compile(r"'[ıİşŞğĞüÜöÖçÇ]'")
IBAN_CHECK_RE = re.compile(r"starts_with\(\"TR\"\)")
REGEX_NEW_RE = re.compile(r"\bRegex::new\(")
LAZY_REGEX_RE = re.compile(r"static\s+\w+[\s\S]*?=\s*LazyLock::new\(\|\|\s*(?:\{\s*)?Regex::new\(")
ROUND_DP_RE = re.compile(r"\.round_dp\(")
FLOAT_RE = re.compile(r"\b(?:f32|f64)\b")
HASH_RE = re.compile(r"\b(?:Sha256|Hmac)\b")
NON_ASCII_IDENT_RE = re.compile(r"[A-Za-z_]*[^\x00-\x7F\s][A-Za-z0-9_]*")
UNWRAP_RE = re.compile(r"\.unwrap\(\)")
EXPECT_RE = re.compile(r"\.expect\(")
STRING_ERROR_RE = re.compile(r"Result<[^;{]*,\s*String\s*>")
QUERY_TYPE_RE = re.compile(r"\bQuery<\s*(?:[A-Za-z_][A-Za-z0-9_]*::)*([A-Za-z_][A-Za-z0-9_]*)\s*>")
STRUCT_RE = re.compile(r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\b[^;{]*\{")
SERDE_FLATTEN_RE = re.compile(r"#\[serde\([^\]]*\bflatten\b")
POOL_BRANCH_RE = re.compile(r"if let Some\((?:ref )?pool\)|\bstate\.pool\b")

HASH_ALLOWED = ("src/domain/fingerprint.rs", "src/auth.rs", "src/migrations.rs")
FLOAT_ALLOWED = ("src/services/receipt_document.rs",)
HANDLERS_ALLOWED_PREFIX = ("src/handlers/", "src/app.rs", "src/main.rs")


@dataclass
class Finding:
    rule: str
    file: str
    line: int
    text: str


def blank_non_code(source: str) -> str:
    """Return `source` with comments, string/char literals and `#[cfg(test)]` modules blanked.

    The result has the same length and line structure, so offsets map to lines.
    String contents are replaced by spaces but the quotes are kept, so
    `starts_with("TR")` becomes `starts_with("  ")`; rules that need literal
    text use `strings_only` instead.
    """
    out = list(source)
    n = len(source)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif source[i] == "r" and re.match(r'r#*"', source[i:]) and (i == 0 or not (source[i - 1].isalnum() or source[i - 1] == "_")):
            hashes = len(re.match(r"r(#*)\"", source[i:]).group(1))
            close = '"' + "#" * hashes
            j = source.find(close, i + 2 + hashes)
            j = n if j < 0 else j + len(close)
            blank(i + 2 + hashes, j - len(close))
            i = j
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] != '"':
                j += 2 if source[j] == "\\" else 1
            blank(i + 1, j)
            i = j + 1
        elif source[i] == "'":
            # Char literal ('a', '\n', '\u{0307}', 'ı') versus lifetime ('a).
            m = re.match(r"'(?:\\u\{[0-9A-Fa-f]+\}|\\.|[^\\'\n])'", source[i:])
            if m:
                blank(i + 1, i + m.end() - 1)
                i += m.end()
            else:
                i += 1
        else:
            i += 1
    code = "".join(out)

    # Blank `#[cfg(test)] mod name { ... }` blocks (brace matching on code only).
    for m in list(re.finditer(r"#\[cfg\(test\)\]\s*mod\s+\w+\s*\{", code)):
        start, depth, j = m.start(), 1, m.end()
        while j < n and depth:
            if code[j] == "{":
                depth += 1
            elif code[j] == "}":
                depth -= 1
            j += 1
        blank(start, j)
        code = "".join(out)
    return code


def line_of(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def unformatted_files(backend: Path) -> list[str] | None:
    """Paths (relative to backend) that `cargo fmt --check` would change; None if unavailable."""
    if not shutil.which("cargo"):
        return None
    proc = subprocess.run(
        ["cargo", "fmt", "--check", "--", "--color", "never"],
        cwd=backend, capture_output=True, text=True, timeout=300,
    )
    if proc.returncode not in (0, 1):
        return None
    files = set()
    for line in proc.stdout.splitlines():
        m = re.match(r"Diff in (.+?)(?::\d+)?(?: at line \d+)?:?$", line.strip())
        if m:
            path = Path(m.group(1))
            try:
                files.add(path.resolve().relative_to(backend.resolve()).as_posix())
            except ValueError:
                files.add(path.as_posix())
    return sorted(files)


def lint(backend: Path, baseline_path: Path | None = None, check_fmt: bool = True) -> dict:
    findings: list[Finding] = []
    counts = {"unwrap": 0, "expect": 0, "string-error": 0, "pool-branch": 0}
    files = sorted((backend / "src").rglob("*.rs"))
    query_types: set[str] = set()
    structs: list[tuple[str, str, str, str, int, int]] = []  # name, rel, source, code, start, end

    for path in files:
        source = path.read_text(encoding="utf-8")
        code = blank_non_code(source)
        rel = path.relative_to(backend).as_posix()
        lines = source.split("\n")

        def add(rule: str, offset: int) -> None:
            ln = line_of(source, offset)
            findings.append(Finding(rule, rel, ln, lines[ln - 1].strip()[:160]))

        if rel.startswith("src/domain/"):
            for m in DOMAIN_FORBIDDEN_RE.finditer(code):
                add("domain-purity", m.start())
        if not rel.startswith(HANDLERS_ALLOWED_PREFIX):
            for m in HANDLERS_IMPORT_RE.finditer(code):
                add("layering", m.start())
        if rel != "src/db/person_repository.rs":
            for m in re.finditer(r"\bINSERT\s+INTO\s+persons\b", source, re.IGNORECASE):
                add("person-insert-location", m.start())
        if rel != "src/domain/email.rs":
            for m in INLINE_EMAIL_RE.finditer(code):
                add("inline-email", m.start())
        if rel != "src/domain/text.rs":
            # A `.replace(` whose pattern is a Turkish letter char literal.
            for m in TURKISH_LETTER_CHAR_RE.finditer(source):
                if code[m.start()] != "'":
                    continue  # inside a comment, string or test module
                line_start = code.rfind("\n", 0, m.start()) + 1
                if ".replace(" in code[line_start:m.start()]:
                    add("inline-turkish-fold", m.start())
        if rel != "src/domain/iban.rs":
            for m in IBAN_CHECK_RE.finditer(source):
                if code[m.start():m.start() + 11] == "starts_with":
                    add("inline-iban-check", m.start())
        lazy_starts = {m.end() - len("Regex::new(") for m in LAZY_REGEX_RE.finditer(code)}
        for m in REGEX_NEW_RE.finditer(code):
            if m.start() not in lazy_starts:
                add("regex-per-call", m.start())
        for m in ROUND_DP_RE.finditer(code):
            add("implicit-rounding", m.start())
        if rel not in FLOAT_ALLOWED:
            for m in FLOAT_RE.finditer(code):
                add("float-money", m.start())
        if rel not in HASH_ALLOWED:
            for m in HASH_RE.finditer(code):
                add("ad-hoc-hash", m.start())
        for m in NON_ASCII_IDENT_RE.finditer(code):
            add("non-english-identifier", m.start())

        query_types.update(m.group(1) for m in QUERY_TYPE_RE.finditer(code))
        for m in STRUCT_RE.finditer(code):
            depth, end = 1, m.end()
            while end < len(code) and depth:
                depth += {"{": 1, "}": -1}.get(code[end], 0)
                end += 1
            structs.append((m.group(1), rel, source, code, m.end(), end))

        counts["unwrap"] += len(UNWRAP_RE.findall(code))
        counts["expect"] += len(EXPECT_RE.findall(code))
        counts["pool-branch"] += len(POOL_BRANCH_RE.findall(code))
        if rel.startswith("src/services/"):
            counts["string-error"] += len(STRING_ERROR_RE.findall(code))

    for name, rel, source, code, start, end in structs:
        if name not in query_types:
            continue
        for m in SERDE_FLATTEN_RE.finditer(code, start, end):
            ln = line_of(source, m.start())
            text = source.split("\n")[ln - 1].strip()[:160]
            findings.append(Finding("query-flatten", rel, ln, f"{name}: {text}"))

    fmt_files = unformatted_files(backend) if check_fmt else None
    if fmt_files is not None:
        counts["unformatted-file"] = len(fmt_files)
        for f in fmt_files:
            if f.startswith("src/domain/"):
                findings.append(Finding("domain-unformatted", f, 1, "run `cargo fmt` (domain files must stay formatted)"))

    baseline = {}
    if baseline_path and baseline_path.exists():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    ratchet = []
    for rule, count in counts.items():
        allowed = baseline.get(rule)
        if allowed is not None and count > allowed:
            ratchet.append({"rule": rule, "count": count, "allowed": allowed})

    return {
        "passed": not findings and not ratchet,
        "files": len(files),
        "findings": [asdict(f) for f in findings],
        "counts": counts,
        "baseline": baseline,
        "ratchet_exceeded": ratchet,
        "fmt_checked": fmt_files is not None,
    }


RATCHET_HINTS = {
    "unwrap": "propagate with `?` or `let ... else` instead of adding `.unwrap()`",
    "expect": "propagate with `?` instead of adding `.expect(..)`",
    "string-error": "return a typed `thiserror` enum from new service methods",
    "pool-branch": "put new persistence behind a repository function instead of branching on the pool",
    "unformatted-file": "run `cargo fmt` on the files you touch (or the formatting-only commit)",
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_BACKEND, help="Backend crate directory (default: backend)")
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE, help="Ratchet baseline JSON")
    parser.add_argument("--json", action="store_true", help="Print a JSON report")
    parser.add_argument("--no-fmt", action="store_true", help="Skip the rustfmt-based rules (no cargo needed)")
    parser.add_argument("--update-baseline", action="store_true",
                        help="Write current ratchet counts to the baseline (only lowers them unless --force)")
    parser.add_argument("--force", action="store_true", help="With --update-baseline, allow raising a count")
    args = parser.parse_args(argv)

    if not (args.root / "src").is_dir():
        print(f"rust-standards-lint: no src/ under {args.root}", file=sys.stderr)
        return 2

    report = lint(args.root, args.baseline, check_fmt=not args.no_fmt)
    if args.update_baseline:
        old = report["baseline"]
        new = dict(old)
        for rule, count in report["counts"].items():
            prev = old.get(rule)
            new[rule] = count if (prev is None or count <= prev or args.force) else prev
        args.baseline.write_text(json.dumps(new, indent=2) + "\n", encoding="utf-8")
        report = lint(args.root, args.baseline, check_fmt=not args.no_fmt)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for f in report["findings"]:
            print(f"{f['file']}:{f['line']}: [{f['rule']}] {f['text']}")
        for r in report["ratchet_exceeded"]:
            print(f"[{r['rule']}] {r['count']} occurrences, baseline allows {r['allowed']}: {RATCHET_HINTS[r['rule']]}")
        counts = ", ".join(f"{k}={v}" for k, v in report["counts"].items())
        print(f"rust-standards-lint: {report['files']} files, {len(report['findings'])} findings, ratchet {counts} "
              f"-> {'PASS' if report['passed'] else 'FAIL'}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
