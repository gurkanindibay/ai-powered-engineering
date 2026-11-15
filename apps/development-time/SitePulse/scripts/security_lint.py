#!/usr/bin/env python3
"""Static security guardrails for the repository (gate `security-lint`).

Each rule encodes a weakness class from docs/quality/SECURITY_ASSESSMENT.md so
it cannot return unnoticed:

  tracked-secret-file     A file that normally holds credentials is tracked by
                          git: `.env` and `.env.*` (except `.env.example`),
                          private keys and key stores (`*.pem`, `*.key`,
                          `*.asc`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`,
                          `id_rsa*`), `key.properties`.
                          (Found: backend/.env.bak-* with a bank API secret.)
  hardcoded-secret        A tracked text file contains a private key block, a
                          provider-format token (AWS, GitHub, Google, Slack,
                          Stripe live), or a `*_SECRET=` / `*_PASSWORD=` /
                          `*_TOKEN=` / `*_KEY=` assignment in a config file
                          whose value is a long high-entropy literal.
  workflow-permissions    A GitHub workflow has no top-level `permissions:`
                          block, so its token keeps the repository default
                          (possibly write) scope.
  workflow-untrusted      A workflow uses `pull_request_target`, or expands
                          attacker-controlled context (`github.head_ref`, PR or
                          issue title/body, comment body, commit message) into
                          a script instead of passing it through `env:`.
  unpinned-image          A Dockerfile `FROM` or compose `image:` uses `latest`
                          or no tag.
  public-route            A route with the `Public` policy in backend/src/app.rs
                          is not on the reviewed list (`public_routes` in the
                          baseline). A new unauthenticated endpoint must be
                          reviewed and added there deliberately.
  dev-route-guard         `dev_routes_enabled()` no longer refuses production,
                          or a `/api/v1/system/` route is not `Development`.
  permissive-cors         The backend allows any CORS origin.
  weak-crypto             Disabled certificate or signature validation, or a
                          broken hash (MD5, SHA-1), in backend or Flutter code.
  insecure-token-storage  Flutter persists a token, password or secret in
                          browser storage or shared preferences.
  unsafe-python           `shell=True`, `verify=False`, `yaml.load(` without a
                          safe loader, `pickle.load`, `eval(`/`exec(` in the
                          Python tooling.
  internal-error-leak     (ratchet) A handler returns the text of an internal
                          error (`{}", e` / `e.to_string()`) with a 5xx status.
                          Counted per file against the baseline: the count may
                          only go down.

Accepted existing findings live in `scripts/security_lint_baseline.json`
(`accepted`: list of "rule|path|detail" keys, `internal_error_leaks`: per-file
counts, `public_routes`: reviewed public routes). A baseline entry that no
longer matches anything is reported so the baseline shrinks with the fixes.

Only the working tree is scanned. Secrets that were committed earlier stay in
git history: rotate them, and use GitHub secret scanning for the history.

Usage:
    python3 scripts/security_lint.py                   # human-readable
    python3 scripts/security_lint.py --json            # gate `security-lint`
    python3 scripts/security_lint.py --write-baseline  # accept the current state

Exit code 0 when there are no unaccepted findings, 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Dict, List, Optional

PROJECT = Path(__file__).resolve().parent.parent
DEFAULT_REPO = PROJECT.parents[2]
DEFAULT_BASELINE = PROJECT / "scripts" / "security_lint_baseline.json"
PROJECT_REL = "apps/development-time/SitePulse"

SECRET_FILE_RE = re.compile(
    r"(^|/)(\.env(\..+)?|id_rsa[^/]*|id_ed25519[^/]*|key\.properties|[^/]+\.(pem|key|asc|p12|pfx|jks|keystore))$"
)
SECRET_FILE_ALLOWED_RE = re.compile(r"(^|/)\.env\.(example|sample|template)$")

TOKEN_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY(?: BLOCK)?-----")),
    ("AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("Slack token", re.compile(r"\bxox[abprs]-[0-9A-Za-z\-]{10,}\b")),
    ("Stripe live key", re.compile(r"\b[sr]k_live_[0-9A-Za-z]{16,}\b")),
]
CONFIG_SUFFIXES = (".env", ".yml", ".yaml", ".sh", ".properties", ".toml", ".ini", ".cfg", ".conf")
ASSIGNMENT_RE = re.compile(
    r"""^\s*(?:export\s+)?([A-Za-z0-9_]*(?:SECRET|PASSWORD|PASSWD|TOKEN|API_?KEY|PRIVATE_?KEY)[A-Za-z0-9_]*)"""
    r"""\s*[=:]\s*["']?([^"'\s#]+)""",
    re.I,
)
TEXT_SUFFIXES = (
    ".rs", ".dart", ".py", ".sh", ".yml", ".yaml", ".json", ".toml", ".md", ".html", ".js", ".ts", ".sql",
    ".properties", ".xml", ".gradle", ".kts", ".plist", ".txt", ".ini", ".cfg", ".conf", ".env", ".feature",
)
SKIP_DIR_PARTS = ("graphify-out/", "/.specify/executions/", "/node_modules/", "/target/", "/build/")

UNTRUSTED_CONTEXT_RE = re.compile(
    r"\$\{\{[^}]*(?:github\.head_ref|github\.event\.(?:pull_request|issue|discussion)\.(?:title|body)"
    r"|github\.event\.pull_request\.head\.(?:ref|label)|github\.event\.(?:comment|review)\.body"
    r"|github\.event\.head_commit\.message|github\.event\.pages\.[^}]*page_name)[^}]*\}\}"
)
ENV_ASSIGNMENT_RE = re.compile(r"^\s*(?!run\b)[A-Za-z_][A-Za-z0-9_\-]*:\s*\$\{\{[^}]*\}\}\s*$")

ROUTE_RE = re.compile(r'^\s*(get|post|put|patch|delete)\s+"([^"]+)"\s*=>\s*[\w:]+\s*,\s*(.+?);\s*$')
LEAK_STATUS_RE = re.compile(r"INTERNAL_SERVER_ERROR|SERVICE_UNAVAILABLE|BAD_GATEWAY")
LEAK_TEXT_RE = re.compile(r'\{[^}]*\}[^"]*",\s*(?:e|err|error)\s*\)|\b(?:e|err|error)\.to_string\(\)|,\s*(?:e|err|error)\)\)')

WEAK_CRYPTO_RS = re.compile(
    r"danger_accept_invalid_(?:certs|hostnames)|insecure_disable_signature_validation|validate_exp\s*=\s*false"
    r"|Algorithm::None|\b(?:md5|Md5|sha1|Sha1)::"
)
WEAK_CRYPTO_DART = re.compile(r"badCertificateCallback|\bmd5\b|\bsha1\b")
CORS_RE = re.compile(r"CorsLayer::(?:very_)?permissive\(\)|AllowOrigin::any\(\)|allow_origin\(\s*(?:tower_http::cors::)?Any\s*\)")
STORAGE_RE = re.compile(r"localStorage|sessionStorage|SharedPreferences|\.setString\(|document\.cookie")
SENSITIVE_WORD_RE = re.compile(r"token|password|secret|credential", re.I)
UNSAFE_PY = [
    ("shell=True", re.compile(r"\bshell\s*=\s*True\b")),
    ("verify=False", re.compile(r"\bverify\s*=\s*False\b")),
    ("yaml.load without a safe loader", re.compile(r"\byaml\.load\((?![^)]*Loader\s*=\s*(?:yaml\.)?(?:Safe|CSafe)Loader)")),
    ("pickle.load", re.compile(r"\bpickle\.loads?\(")),
    ("eval/exec", re.compile(r"(?<![\w.])(?:eval|exec)\(")),
]


@dataclass(frozen=True)
class Finding:
    rule: str
    path: str
    line: int
    detail: str

    @property
    def key(self) -> str:
        return f"{self.rule}|{self.path}|{self.detail}"


def tracked_files(repo: Path) -> List[str]:
    """Paths tracked by git; falls back to walking the tree outside a git checkout (tests)."""
    try:
        out = subprocess.run(
            ["git", "-C", str(repo), "ls-files", "-z"], capture_output=True, check=True, timeout=60
        ).stdout.decode()
        files = [f for f in out.split("\0") if f]
        if files:
            return [f for f in files if (repo / f).is_file()]
    except (subprocess.SubprocessError, OSError):
        pass
    return sorted(str(p.relative_to(repo)) for p in repo.rglob("*") if p.is_file() and ".git/" not in str(p))


def _read(path: Path) -> Optional[str]:
    try:
        if path.stat().st_size > 2_000_000:
            return None
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def entropy(value: str) -> float:
    counts = Counter(value)
    return -sum(n / len(value) * math.log2(n / len(value)) for n in counts.values())


def _looks_like_secret(value: str) -> bool:
    if len(value) < 20 or any(c in value for c in "${}<>()/\\ "):
        return False
    if re.fullmatch(r"[a-z]+(?:[-_][a-z0-9]+)+", value):  # descriptive placeholder such as ci-only-password
        return False
    return entropy(value) >= 3.5


def check_secrets(repo: Path, files: List[str]) -> List[Finding]:
    findings = []
    for rel in files:
        if any(part in f"/{rel}" for part in SKIP_DIR_PARTS):
            continue
        name = rel.rsplit("/", 1)[-1]
        secret_file = bool(SECRET_FILE_RE.search(rel)) and not SECRET_FILE_ALLOWED_RE.search(rel)
        if secret_file:
            findings.append(Finding("tracked-secret-file", rel, 0, "credential file tracked by git"))
        is_config = secret_file or name.startswith(".env") or rel.endswith(CONFIG_SUFFIXES)
        if not (is_config or rel.endswith(TEXT_SUFFIXES)):
            continue
        text = _read(repo / rel)
        if text is None:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for label, pattern in TOKEN_PATTERNS:
                if pattern.search(line) and "security-lint: example" not in line:
                    findings.append(Finding("hardcoded-secret", rel, number, label))
            if is_config:
                match = ASSIGNMENT_RE.match(line)
                if match and _looks_like_secret(match.group(2)):
                    # The value itself is never printed.
                    findings.append(Finding("hardcoded-secret", rel, number, f"literal value for {match.group(1)}"))
    return findings


def check_workflows(repo: Path, files: List[str]) -> List[Finding]:
    findings = []
    for rel in files:
        if not re.match(r"\.github/workflows/[^/]+\.ya?ml$", rel):
            continue
        text = _read(repo / rel) or ""
        if not re.search(r"^permissions:", text, re.M):
            findings.append(Finding("workflow-permissions", rel, 0, "no top-level permissions block"))
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if re.search(r"\bpull_request_target\b", line):
                findings.append(Finding("workflow-untrusted", rel, number, "pull_request_target trigger"))
            if UNTRUSTED_CONTEXT_RE.search(line) and not ENV_ASSIGNMENT_RE.match(line):
                findings.append(Finding("workflow-untrusted", rel, number, "untrusted context expanded in a script"))
    return findings


def check_images(repo: Path, files: List[str]) -> List[Finding]:
    findings = []
    for rel in files:
        name = rel.rsplit("/", 1)[-1]
        is_dockerfile = name == "Dockerfile" or name.startswith("Dockerfile.")
        is_compose = re.match(r"(docker-)?compose[^/]*\.ya?ml$", name) is not None
        if not (is_dockerfile or is_compose):
            continue
        stages = set()
        for number, line in enumerate((_read(repo / rel) or "").splitlines(), 1):
            match = (
                re.match(r"\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?", line, re.I)
                if is_dockerfile
                else re.match(r"\s*image:\s*[\"']?([^\"'\s]+)", line)
            )
            if not match:
                continue
            image = match.group(1)
            if is_dockerfile and match.group(2):
                stages.add(match.group(2).lower())
            if image.lower() in stages or image == "scratch" or "$" in image or "@sha256:" in image:
                continue
            tag = image.rsplit("/", 1)[-1].partition(":")[2]
            if tag in ("", "latest"):
                findings.append(Finding("unpinned-image", rel, number, f"{image} has no fixed version tag"))
    return findings


def _strip_tests(text: str) -> str:
    """Drops `#[cfg(test)]` modules (always at the end of a file in this codebase)."""
    index = text.find("#[cfg(test)]")
    return text if index < 0 else text[:index]


def check_backend(repo: Path, backend: Path, public_routes: List[str]) -> List[Finding]:
    findings = []
    src = backend / "src"
    if not src.is_dir():
        return findings
    rel = lambda p: str(p.relative_to(repo))  # noqa: E731

    app = src / "app.rs"
    app_text = _read(app) or ""
    reviewed = set(public_routes)
    for number, line in enumerate(app_text.splitlines(), 1):
        match = ROUTE_RE.match(line)
        if not match:
            continue
        method, path, policy = match.group(1).upper(), match.group(2), match.group(3).strip()
        if policy == "Public" and f"{method} {path}" not in reviewed:
            findings.append(Finding("public-route", rel(app), number, f"{method} {path} is unauthenticated and not reviewed"))
        if path.startswith("/api/v1/system/") and policy != "Development":
            findings.append(Finding("dev-route-guard", rel(app), number, f"{method} {path} must use the Development policy"))
    if app_text:
        guard = re.search(r"fn dev_routes_enabled\(\)[^{]*\{(.*?)\n\}", app_text, re.S)
        if not guard or "!state::AppStateInner::is_production()" not in guard.group(1):
            findings.append(Finding("dev-route-guard", rel(app), 0, "dev_routes_enabled() does not refuse production"))

    for path in sorted(src.rglob("*.rs")):
        text = _strip_tests(_read(path) or "")
        for number, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if CORS_RE.search(line):
                findings.append(Finding("permissive-cors", rel(path), number, "any CORS origin is allowed"))
            weak = WEAK_CRYPTO_RS.search(line)
            if weak:
                findings.append(Finding("weak-crypto", rel(path), number, weak.group(0)))
    return findings


def internal_error_leaks(repo: Path, backend: Path) -> Dict[str, int]:
    """Per handler file: statements that return internal error text with a 5xx status."""
    counts: Dict[str, int] = {}
    handlers = backend / "src" / "handlers"
    if not handlers.is_dir():
        return counts
    for path in sorted(handlers.rglob("*.rs")):
        lines = _strip_tests(_read(path) or "").splitlines()
        count = 0
        for index, line in enumerate(lines):
            if LEAK_STATUS_RE.search(line) and LEAK_TEXT_RE.search(" ".join(lines[index:index + 4])):
                count += 1
        if count:
            counts[str(path.relative_to(repo))] = count
    return counts


def check_flutter(repo: Path, flutter: Path) -> List[Finding]:
    findings = []
    lib = flutter / "lib"
    if not lib.is_dir():
        return findings
    for path in sorted(lib.rglob("*.dart")):
        rel = str(path.relative_to(repo))
        for number, line in enumerate((_read(path) or "").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if STORAGE_RE.search(line) and SENSITIVE_WORD_RE.search(line):
                findings.append(Finding("insecure-token-storage", rel, number, "credential written to client storage"))
            weak = WEAK_CRYPTO_DART.search(line)
            if weak:
                findings.append(Finding("weak-crypto", rel, number, weak.group(0)))
    return findings


def check_python(repo: Path, files: List[str]) -> List[Finding]:
    findings = []
    for rel in files:
        if not rel.endswith(".py") or "/tests/" in f"/{rel}" or rel.endswith("security_lint.py"):
            continue
        for number, line in enumerate((_read(repo / rel) or "").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for label, pattern in UNSAFE_PY:
                if pattern.search(line):
                    findings.append(Finding("unsafe-python", rel, number, label))
    return findings


def load_baseline(path: Path) -> dict:
    data = json.loads(path.read_text()) if path.exists() else {}
    return {
        "accepted": list(data.get("accepted", [])),
        "internal_error_leaks": dict(data.get("internal_error_leaks", {})),
        "public_routes": list(data.get("public_routes", [])),
    }


def lint(repo: Path, backend: Path, flutter: Path, baseline: dict) -> dict:
    files = tracked_files(repo)
    findings = (
        check_secrets(repo, files)
        + check_workflows(repo, files)
        + check_images(repo, files)
        + check_backend(repo, backend, baseline["public_routes"])
        + check_flutter(repo, flutter)
        + check_python(repo, files)
    )
    accepted = set(baseline["accepted"])
    seen = {f.key for f in findings}
    open_findings = [f for f in findings if f.key not in accepted]

    leaks = internal_error_leaks(repo, backend)
    allowed = baseline["internal_error_leaks"]
    for path, count in sorted(leaks.items()):
        if count > allowed.get(path, 0):
            open_findings.append(Finding(
                "internal-error-leak", path, 0,
                f"{count} handler error(s) expose internal error text; baseline allows {allowed.get(path, 0)}",
            ))
    stale = sorted(accepted - seen)
    stale += [f"internal_error_leaks|{p} (now {leaks.get(p, 0)}, baseline {n})"
              for p, n in sorted(allowed.items()) if leaks.get(p, 0) < n]
    return {
        "status": "FAIL" if open_findings else "PASS",
        "findings": [asdict(f) for f in open_findings],
        "accepted": len(findings) - len([f for f in findings if f.key not in accepted]),
        "stale_baseline": stale,
        "all_keys": sorted(seen),
        "internal_error_leaks": leaks,
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO, help="repository root")
    parser.add_argument("--backend", type=Path, help="backend directory (default: <repo>/%s/backend)" % PROJECT_REL)
    parser.add_argument("--flutter", type=Path, help="Flutter directory (default: <repo>/%s/flutter)" % PROJECT_REL)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--write-baseline", action="store_true",
                        help="accept every current finding (review the diff before committing)")
    args = parser.parse_args(argv)

    repo = args.repo.resolve()
    backend = (args.backend or repo / PROJECT_REL / "backend").resolve()
    flutter = (args.flutter or repo / PROJECT_REL / "flutter").resolve()
    baseline = load_baseline(args.baseline)
    report = lint(repo, backend, flutter, baseline)

    if args.write_baseline:
        # Public routes are never accepted in bulk: review each and list it by hand.
        keys = [k for k in report["all_keys"] if not k.startswith("public-route|")]
        args.baseline.write_text(json.dumps({
            "accepted": keys,
            "internal_error_leaks": report["internal_error_leaks"],
            "public_routes": baseline["public_routes"],
        }, indent=2) + "\n")
        print(f"Baseline written to {args.baseline}: {len(keys)} accepted finding(s)")
        return 0

    if args.json:
        print(json.dumps({k: report[k] for k in ("status", "findings", "accepted", "stale_baseline")}, indent=2))
    else:
        for finding in report["findings"]:
            location = f"{finding['path']}:{finding['line']}" if finding["line"] else finding["path"]
            print(f"  [{finding['rule']}] {location}: {finding['detail']}")
        for entry in report["stale_baseline"]:
            print(f"  note: baseline entry no longer needed: {entry}")
        print(f"security-lint: {len(report['findings'])} finding(s), {report['accepted']} accepted by baseline")
        print(report["status"])
    return 1 if report["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
