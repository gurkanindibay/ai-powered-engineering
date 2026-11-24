#!/usr/bin/env python3
"""Test-strategy scanner: how every SitePulse test runs in CI, which shortcuts it takes, and
which Gherkin scenarios are covered only on paper.

It parses Rust test attributes and bodies, Dart test()/testWidgets() calls and Python test
functions (AST), reads the gate commands in harness/loop/verification_gates.py, and joins the
result with the scenario catalogue through feature_traceability.py. See
docs/testing/TEST_STRATEGY.md ("Method and reproduction").

Usage:
  python3 -I scripts/test_strategy_scan.py                 # totals by suite, run status, flag, verdict
  python3 -I scripts/test_strategy_scan.py --json          # the same totals as JSON
  python3 -I scripts/test_strategy_scan.py --output out.json   # every test and scenario row
"""
import argparse
import ast
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

DEFAULT_REPO = Path(__file__).resolve().parents[4]
WRAPPER = "e2e/tests/test_linked_backend_suites.py"
API_CHECK = "scripts/api_system_check.py"
WEAK_FLAGS = {
    "no-assertion", "weak-assertions-only", "only-unwrap (passes if nothing panics)",
    "wait-only (no explicit assertion)",
}
RUNS_IN_CI = {"ci", "ci-db-gate", "conditional"}



def inventory(repo: Path, sitepulse: Path | None = None) -> dict:
    """Discover named tests, their source ranges and their CI selections."""
    REPO = repo.resolve()
    SP = sitepulse or REPO / "apps/development-time/SitePulse"
    tests = []

    def rel(p):
        return p.relative_to(REPO).as_posix()

    # ---- CI facts (from harness/loop/verification_gates.py) -------------------------------------
    gates = SP / "harness/loop/verification_gates.py"
    GATES_SRC = gates.read_text() if gates.exists() else ""
    db_block = GATES_SRC.partition('"rust-db-test"')[2].partition('"flutter-analyze"')[0]
    DB_GATE_FILES = set(re.findall(r'"--test", "(\w+)"', db_block.split("--ignored")[0]))
    FEATURE_GATED = {
        (feature, target)
        for feature, commands in re.findall(
            r'"--features", "([\w-]+)",((?:\s*"--test", "\w+",?)+)', GATES_SRC
        )
        for target in re.findall(r'"--test", "(\w+)"', commands)
    }
    workflows = REPO / ".github/workflows"
    WORKFLOWS = "\n".join(p.read_text(errors="replace") for p in workflows.glob("*.yml"))
    nightly_workflow = workflows / "sitepulse-nightly.yml"
    nightly = nightly_workflow.read_text() if nightly_workflow.exists() else ""
    OPT_IN = set(re.findall(r'"--test", "\w+",\s*"(\w+)", "--", "--exact"', db_block))



    def match_brace(text, start, open_c="{", close_c="}"):
        depth, i, n = 0, start, len(text)
        in_str = None
        while i < n:
            c = text[i]
            if in_str:
                if c == "\\":
                    i += 2
                    continue
                if c == in_str:
                    in_str = None
            elif c == '"' or (c == "'" and open_c != "{"):
                in_str = c
            elif c == open_c:
                depth += 1
            elif c == close_c:
                depth -= 1
                if depth == 0:
                    return i
            i += 1
        return n - 1


    # ---- assertion / shortcut heuristics ---------------------------------------------------------
    RS_ASSERT = re.compile(r"\b(assert(?:_eq|_ne|_matches)?!|prop_assert\w*!|panic!|assert_\w+\(|expect_\w+\(|check_\w+\(|verify_\w+\()")
    RS_WEAK = re.compile(r"assert!\(\s*[\w.:()&]*\.(is_ok|is_some|is_err|is_none)\(\)\s*\)|assert!\(\s*!\s*[\w.]+\.is_empty\(\)\s*\)|assert!\(\s*true\s*\)")
    DART_ASSERT = re.compile(r"\b(expect|expectLater|verify|verifyNever|expectAsync\d?|fail)\s*\(|\b(assert|expect|check|verify)\w*\(")
    DART_WEAK = re.compile(r"expect\([^;]*,\s*(isNotNull|findsWidgets|isNotEmpty|isTrue|findsAtLeastNWidgets\(1\))\s*\)")
    SLEEP = re.compile(r"thread::sleep|tokio::time::sleep|time\.sleep\(|wait_for_timeout\(|Future\.delayed\(")
    SWALLOW_RS = re.compile(r"let _ = [^;]*\.await\s*;|\.ok\(\);|unwrap_or_default\(\)")
    SWALLOW_DART = re.compile(r"catch\s*\([^)]*\)\s*\{\s*\}")


    def rust_scan(path):
        trivia = re.compile(r"\s+|//[^\n]*|#\[[^\]]*\]")
        function = re.compile(r"(?:pub\s+)?(?:async\s+)?fn\s+(\w+)")
        text = path.read_text(errors="replace")
        lines = text.splitlines(keepends=True)
        file_cfg = re.search(r'#!\[cfg\(feature\s*=\s*"([\w-]+)"\)\]', text)
        for m in re.finditer(r"#\[(tokio::test|test|sqlx::test|actix_rt::test)[^\]]*\]", text):
            # Sibling attributes can precede or follow the test attribute.
            start_line = text.count("\n", 0, m.start()) + 1
            for previous in reversed(lines[:start_line - 1]):
                if not re.match(r"^\s*(?:#\[|//)", previous):
                    break
                start_line -= 1
            head_start = sum(map(len, lines[:start_line - 1]))
            cursor = m.end()
            while token := trivia.match(text, cursor):
                cursor = token.end()
            fn = function.match(text, cursor)
            if not fn:
                continue
            name_start = fn.start(1)
            attrs = text[head_start:name_start]
            cfg = file_cfg or re.search(r'#\[cfg\(feature\s*=\s*"([\w-]+)"\)\]', attrs)
            body_open = text.find("{", fn.end())
            body_close = match_brace(text, body_open)
            body = text[body_open:body_close + 1]
            line = text.count("\n", 0, name_start) + 1
            ignore = re.search(r'#\[ignore(?:\s*=\s*"([^"]*)")?\]', attrs)
            should_panic = re.search(r"#\[should_panic(\([^)]*\))?\]", attrs)
            name = fn.group(1)
            stem = path.stem
            in_src = "/src/" in rel(path)
            if cfg and (cfg.group(1), stem) in FEATURE_GATED and not ignore:
                run, run_note = "ci", f"rust-test with --features {cfg.group(1)}"
            elif cfg and (cfg.group(1), stem) not in FEATURE_GATED:
                run, run_note = "never-in-ci", f"requires --features {cfg.group(1)}; no CI gate passes it"
            elif cfg:
                run, run_note = "never-in-ci", f"#[ignore]; no CI gate runs the ignored {cfg.group(1)} cases"
            elif ignore:
                if stem in DB_GATE_FILES:
                    run, run_note = "ci-db-gate", "#[ignore], run by rust-db-test --ignored"
                else:
                    run, run_note = "never-in-ci", f"#[ignore] and {stem}.rs is not in the rust-db-test --test list"
            else:
                run, run_note = "ci", "rust-test"
            env_guard = re.search(
                r'env::var(?:_os)?\(\s*"([A-Z][A-Z0-9_]*)"\s*\)'
                r'[^;{}]*(?:\{[^{};]*(?:println!\("SKIP|eprintln!\("SKIP|return\s*;))',
                body,
            )
            if env_guard:
                if name in OPT_IN:
                    run, run_note = "ci-db-gate", f"env-guarded ({env_guard.group(1)}); opt-in command in rust-db-test; reports PASS without running in rust-test"
                else:
                    run, run_note = "silent-pass", f"returns early unless {env_guard.group(1)}=1; never set in CI, so it reports PASS without running"
            asserts = RS_ASSERT.findall(body)
            tests.append(dict(
                lang="rust", file=rel(path), line=line, name=name, in_src=in_src,
                markers=[x for x in [ignore and f"ignore: {ignore.group(1) or ''}".strip(), should_panic and ("should_panic" + (should_panic.group(1) or "")), cfg and f"cfg(feature={cfg.group(1)})"] if x],
                run=run, run_note=run_note,
                n_assert=len(asserts), n_unwrap=len(re.findall(r"\.(unwrap|expect)\(", body)),
                weak=len(RS_WEAK.findall(body)),
                sleep=bool(SLEEP.search(body)), swallow=len(SWALLOW_RS.findall(body)),
                should_panic_unchecked=bool(should_panic and "expected" not in (should_panic.group(1) or "")),
                loc=body.count("\n") + 1, end=text.count("\n", 0, body_close) + 1, deco_line=start_line,
            ))


    def dart_scan(path):
        text = path.read_text(errors="replace")
        file_skip = re.search(r"@Skip\(", text)
        tags = re.search(r"@Tags\(\[([^\]]*)\]\)", text)
        for m in re.finditer(r"(?<![\w.])(testWidgets|test)\(\s*(['\"])(.+?)\2", text):
            open_p = text.find("(", m.start())
            close_p = match_brace(text, open_p, "(", ")")
            body = text[open_p:close_p + 1]
            tail = body[-200:]
            skip = re.search(r"skip:\s*([^,)]+)", tail)
            line = text.count("\n", 0, m.start()) + 1
            asserts = DART_ASSERT.findall(body)
            run = "skipped" if (file_skip or (skip and skip.group(1).strip() not in ("false", "null"))) else "ci"
            tests.append(dict(
                lang="dart", file=rel(path), line=line, name=m.group(3), in_src=False,
                markers=([f"skip: {skip.group(1).strip()}"] if skip else []) + ([f"tags: {tags.group(1)}"] if tags else ["untagged"]),
                run=run, run_note="flutter-test" if run == "ci" else "skipped",
                n_assert=len(asserts), n_unwrap=0, weak=len(DART_WEAK.findall(body)),
                sleep=bool(SLEEP.search(body)), swallow=len(SWALLOW_DART.findall(body)),
                should_panic_unchecked=False, loc=body.count("\n") + 1, untagged=not tags,
                end=line + body.count("\n"),
            ))


    PY_ASSERT_CALL = re.compile(r"^(assert\w*|expect\w*|check\w*|verify\w*|require\w*|fail|raises|to_\w+|_assert\w*|_expect\w*|_check\w*)$")


    def py_call_name(node):
        f = node.func
        return f.attr if isinstance(f, ast.Attribute) else f.id if isinstance(f, ast.Name) else ""


    def py_weak(a: ast.Assert):
        t = a.test
        if isinstance(t, (ast.Name, ast.Attribute, ast.Call)) and not (isinstance(t, ast.Call) and py_call_name(t) in ("isinstance",)):
            return isinstance(t, (ast.Name, ast.Attribute))
        if isinstance(t, ast.Compare) and len(t.ops) == 1:
            op, right = t.ops[0], t.comparators[0]
            if isinstance(op, ast.IsNot) and isinstance(right, ast.Constant) and right.value is None:
                return True
            if isinstance(right, ast.Constant) and right.value in (0, 1) and isinstance(op, (ast.Gt, ast.GtE)) and isinstance(t.left, ast.Call) and py_call_name(t.left) == "len":
                return True
        if isinstance(t, ast.Constant) and t.value:
            return True
        return False


    def py_scan(path, suite):
        text = path.read_text(errors="replace")
        try:
            tree = ast.parse(text)
        except SyntaxError:
            return
        lines = text.splitlines()
        registered_checks = {}
        if suite == "api-system":
            for statement in tree.body:
                if (isinstance(statement, ast.AnnAssign) and isinstance(statement.target, ast.Name)
                        and statement.target.id == "CHECK_FUNCS" and isinstance(statement.value, ast.Dict)):
                    registered_checks = {
                        value.id: key.value for key, value in zip(statement.value.keys, statement.value.values)
                        if isinstance(key, ast.Constant) and isinstance(key.value, str) and isinstance(value, ast.Name)
                    }
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if not node.name.startswith("test") and not (suite == "api-system" and node.name in registered_checks):
                continue
            decos = [ast.unparse(d) for d in node.decorator_list]
            parent_decos = []
            for cls in ast.walk(tree):
                if isinstance(cls, ast.ClassDef) and node in cls.body:
                    parent_decos = [ast.unparse(d) for d in cls.decorator_list]
            all_decos = decos + parent_decos
            marks = [d for d in all_decos if re.search(r"skip|xfail|expectedFailure|allow_|covers|pending", d)]
            asserts = [n for n in ast.walk(node) if isinstance(n, ast.Assert)]
            calls = [n for n in ast.walk(node) if isinstance(n, ast.Call) and PY_ASSERT_CALL.match(py_call_name(n) or "")]
            withs = [n for n in ast.walk(node) if isinstance(n, ast.With) and "raises" in ast.unparse(n.items[0].context_expr)]
            compares = [n for n in ast.walk(node) if isinstance(n, ast.Compare)] if suite == "api-system" else []
            weak = sum(py_weak(a) for a in asserts)
            waits = [n for n in ast.walk(node) if isinstance(n, ast.Call) and re.match(r"^(wait|wait_for\w*|run_suite)$", py_call_name(n) or "")]
            swallow = sum(1 for n in ast.walk(node) if isinstance(n, ast.ExceptHandler) and all(isinstance(s, ast.Pass) for s in n.body))
            env_guards = [(statement, ast.unparse(statement.test)) for statement in node.body
                          if isinstance(statement, ast.If)
                          and re.search(r"\b(?:environ|getenv|which|exists)\b", ast.unparse(statement.test))]
            early_return = any(any(isinstance(branch, ast.Return) for branch in guard.body)
                               for guard, _ in env_guards)
            cond_only = bool(asserts) and all(any(a in ast.walk(i) for i in ast.walk(node) if isinstance(i, ast.If)) for a in asserts) and not calls
            src = "\n".join(lines[node.lineno - 1:node.end_lineno])
            run, note = "ci", suite
            if suite == "nightly-e2e" and path.relative_to(SP / "e2e").as_posix() not in nightly:
                run, note = "never-in-ci", "file is not selected in sitepulse-nightly.yml"
            if any("xfail" in d or "expectedFailure" in d for d in all_decos):
                run, note = "xfail", suite
            elif any(re.search(r"\bskip\b|skip\(|skipTest", d) for d in all_decos):
                run, note = "skipped", suite
            elif any("skipIf" in d or "skipUnless" in d or "skipif" in d for d in all_decos):
                run, note = "conditional", suite + " (" + "; ".join(d for d in all_decos if "skip" in d)[:160] + ")"
            for guard, condition in env_guards:
                if not any(isinstance(node, ast.Call) and py_call_name(node) in {"skip", "skipTest"}
                           for branch in guard.body for node in ast.walk(branch)):
                    continue
                variables = set(re.findall(r"""['"]([A-Z][A-Z0-9_]*)['"]""", condition))
                missing = sorted(name for name in variables if not re.search(
                    rf"(?m)^\s*(?:{re.escape(name)}:|(?:export\s+)?{re.escape(name)}=)", WORKFLOWS))
                if missing:
                    run, note = "silent-skip", f"{suite} skips on missing environment: {', '.join(missing)}"
            if early_return:
                run, note = "silent-pass", suite + " (returns early on missing env/tool: reported PASS)"
            tests.append(dict(
                lang="python", file=rel(path), line=node.lineno, name=node.name, in_src=False,
                markers=marks, run=run, run_note=note,
                n_assert=len(asserts) + len(calls) + len(withs) + len(compares), n_unwrap=0, weak=weak,
                sleep=bool(SLEEP.search(src)), swallow=swallow, should_panic_unchecked=False,
                loc=src.count("\n") + 1, cond_only=cond_only, end=getattr(node, "end_lineno", node.lineno),
                deco_line=min([d.lineno for d in node.decorator_list] or [node.lineno]),
                allow_server_errors="allow_server_errors" in " ".join(all_decos), n_wait=len(waits),
                covers=[m for d in all_decos for m in re.findall(r"SC-\d\d-\d\d-\d\d", d)],
            ))


    # ---- collect -------------------------------------------------------------------------------
    for p in sorted((SP / "backend/tests").rglob("*.rs")):
        rust_scan(p)
    for p in sorted((SP / "backend/src").rglob("*.rs")):
        rust_scan(p)
    for p in sorted((SP / "flutter/test").rglob("*_test.dart")):
        dart_scan(p)
    for p in sorted((SP / "harness/tests").glob("test_*.py")):
        py_scan(p, "harness-selftest")
    for p in sorted((SP / "e2e/tests").rglob("test_*.py")):
        py_scan(p, "gui-e2e")
    for p in sorted((SP / "e2e/nightly").rglob("test_*.py")):
        py_scan(p, "nightly-e2e")
    for p in sorted((REPO / "tests").rglob("test_*.py")):
        py_scan(p, "engineering-harness-ci")
    api_check = SP / "scripts/api_system_check.py"
    if api_check.exists():
        py_scan(api_check, "api-system")

    # pytest-bdd scenarios automated by step definitions (test_features.py) are 'gherkin' mode

    for t in tests:
        flags = []
        if t["n_assert"] == 0 and t["n_unwrap"] == 0 and t.get("n_wait"):
            flags.append("wait-only (no explicit assertion)" if not t["file"].endswith(WRAPPER) else "suite-wrapper")
        elif t["n_assert"] == 0 and t["n_unwrap"] == 0:
            flags.append("no-assertion")
        elif t["n_assert"] == 0:
            flags.append("only-unwrap (passes if nothing panics)")
        elif t["weak"] and t["weak"] >= t["n_assert"]:
            flags.append("weak-assertions-only")
        if t["sleep"]:
            flags.append("fixed-sleep")
        if t["swallow"]:
            flags.append("swallowed-errors")
        if t.get("should_panic_unchecked"):
            flags.append("should_panic without expected=")
        if t.get("cond_only"):
            flags.append("assertions only inside if")
        if t.get("allow_server_errors"):
            flags.append("allow_server_errors")
        t["flags"] = flags

    return dict(tests=tests, db_gate_files=sorted(DB_GATE_FILES), opt_in=sorted(OPT_IN))


def resolve_links(sitepulse: Path, repo: Path, links: dict, tests: list[dict]) -> dict:
    """Resolve declarations using lexical test ranges and immediately attached comments."""
    by_file = defaultdict(list)
    for test in tests:
        path = repo / test["file"]
        if path.is_relative_to(sitepulse):
            by_file[path.relative_to(sitepulse).as_posix()].append(test)
    source_lines = {}
    resolved = {}
    for sid, refs in links.items():
        resolved[sid] = []
        for ref in refs:
            file, line = ref["file"], ref["line"]
            if file not in source_lines:
                source_lines[file] = (sitepulse / file).read_text(errors="replace").splitlines()
            lines = source_lines[file]
            candidates = by_file[file]
            inside = [test for test in candidates if test.get("deco_line", test["line"]) <= line <= test["end"]]
            target = min(inside, key=lambda test: test["end"] - test["line"], default=None)
            attachment = "enclosing"
            if target is None:
                attachment = "next"
                # The comment must be next to the declaration in the same scope.
                indent = len(lines[line - 1]) - len(lines[line - 1].lstrip())
                for test in candidates:
                    begin = test.get("deco_line", test["line"])
                    if begin <= line:
                        continue
                    head = lines[begin - 1]
                    if indent != len(head) - len(head.lstrip()):
                        continue
                    if all(re.match(r"^\s*(?://|#(?!\[))", part) for part in lines[line:begin - 1]):
                        target = test
                        break
            if file == WRAPPER:
                kind, problem = "wrapper", "whole-suite wrapper is not a named scenario test"
            elif file.startswith("scripts/") and (file != API_CHECK or target is None):
                kind, problem = "script", "script declaration is not a registered CI test case"
            elif target is None:
                first = min((test["line"] for test in candidates), default=float("inf"))
                kind = "file-level" if line < first else "unresolved"
                problem = "unattached declaration; place it inside or immediately above its named test"
            elif target["run"] not in RUNS_IN_CI:
                kind, problem = "test", f'{target["name"]} does not execute in CI: {target["run_note"]}'
            else:
                kind, problem = "test", ""
            resolved[sid].append(dict(ref=ref, kind=kind, test=target, problem=problem,
                                      attached_by=attachment if target else None))
    return resolved


def scenario_verdict(scenario, links: list[dict]) -> str:
    """Return the shared static verification classification for one scenario."""
    if scenario.mode == "pending":
        return "PENDING"
    if scenario.mode == "gherkin":
        return "GHERKIN"
    if not links:
        return "NO-LINK"
    valid = [link for link in links if not link["problem"]]
    if any(not set(link["test"]["flags"]) & WEAK_FLAGS for link in valid):
        return "OK"
    if valid:
        return "LINKED-WEAK-ONLY"
    kinds = {link["kind"] for link in links}
    if len(kinds) != 1:
        return "NO-VALID-LINK"
    return {"file-level": "FILE-LEVEL-ONLY", "wrapper": "COARSE-ONLY", "script": "SCRIPT-ONLY",
            "test": "LINKED-BUT-NEVER-RUN"}.get(kinds.pop(), "NO-VALID-LINK")


def verified_count(verdicts) -> int:
    return sum(verdict in ("OK", "GHERKIN") for verdict in verdicts)


def scan(repo: Path) -> dict:
    """Return the test inventory and its links to the scenario catalogue."""
    repo = repo.resolve()
    sitepulse = repo / "apps/development-time/SitePulse"
    scripts = str(Path(__file__).resolve().parent)
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    import feature_traceability as ft

    result = inventory(repo, sitepulse)
    tests = result["tests"]
    catalogue = ft.load_catalogue(sitepulse)
    resolved = resolve_links(sitepulse, repo, catalogue.links, tests)
    scen_rows = []
    test_scen_count = Counter()
    for s in catalogue.scenarios:
        links = resolved.get(s.id, [])
        linked_tests = [link["test"] for link in links if link["test"]]
        for test in linked_tests:
            test_scen_count[(test["file"], test["name"])] += 1
        layer_mismatch = s.layer == "gui" and s.mode == "linked" and not any(
            test["lang"] == "dart" or (test["lang"] == "python" and "/e2e/" in test["file"])
            for test in linked_tests
        )
        scen_rows.append(dict(
            id=s.id, name=s.name, mode=s.mode, layer=s.layer, file=s.file, line=s.line,
            priority=next((p for p in ("smoke", "core", "edge") if p in s.all_tags), ""),
            pending_note=s.pending_note, verdict=scenario_verdict(s, links), layer_mismatch=layer_mismatch,
            unresolved=[link["ref"] for link in links if link["kind"] == "unresolved"],
            links=[dict(file=link["ref"]["file"], line=link["ref"]["line"], test=link["ref"]["test"],
                        run=(link["test"] or {}).get("run", link["kind"]),
                        flags=(link["test"] or {}).get("flags", []), kind=link["kind"],
                        resolved_test=(link["test"] or {}).get("name"), attached_by=link["attached_by"],
                        problem=link["problem"]) for link in links],
        ))
    for test in tests:
        test["scenarios_claimed"] = test_scen_count[(test["file"], test["name"])]
    return dict(result, scenarios=scen_rows)


def summarize(result: dict) -> dict:
    tests, scenarios = result["tests"], result["scenarios"]
    count = lambda items: dict(sorted(Counter(items).items()))
    return {
        "tests": len(tests),
        "by_language": count(t["lang"] for t in tests),
        "by_run_status": count(f"{t['lang']}:{t['run']}" for t in tests),
        "flags": count(f for t in tests for f in t["flags"]),
        "scenarios": len(scenarios),
        "verified_scenarios": verified_count(r["verdict"] for r in scenarios),
        "verdicts": count(r["verdict"] for r in scenarios),
        "link_kinds": count(l["kind"] for r in scenarios for l in r["links"]),
        "never_run_tests": [f"{t['file']}:{t['line']} {t['name']}" for t in tests if t["run"] in ("never-in-ci", "silent-skip")],
        "mis_covered": [f"{r['id']} {r['verdict']}" for r in scenarios if r["verdict"] not in ("OK", "PENDING", "GHERKIN")],
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=DEFAULT_REPO, help="repository root (default: this checkout)")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    parser.add_argument("--output", type=Path, help="write every test and scenario row to this JSON file")
    args = parser.parse_args(argv)
    result = scan(args.repo)
    if args.output:
        args.output.write_text(json.dumps(result, indent=1))
    summary = summarize(result)
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        for key in ("tests", "by_language", "by_run_status", "flags", "scenarios", "verified_scenarios", "verdicts", "link_kinds"):
            print(f"{key}: {summary[key]}")
        print("never-run tests:", *summary["never_run_tests"] or ["none"], sep="\n  ")
        print("mis-covered scenarios:", *summary["mis_covered"] or ["none"], sep="\n  ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
