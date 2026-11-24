#!/usr/bin/env python3
"""Inventory every test in the repo, classify how/if it runs in CI, flag shortcut patterns,
and join the result with the Gherkin scenario catalogue to find mis-coverage.

Usage: python3 -I scan_tests.py <repo-root> <out.json>
"""
import ast
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(sys.argv[1]).resolve()
OUT = Path(sys.argv[2])
SP = REPO / "apps/development-time/SitePulse"
sys.path.insert(0, str(SP / "scripts"))
import feature_traceability as ft  # noqa: E402

# ---- CI facts (from harness/loop/verification_gates.py) -------------------------------------
GATES_SRC = (SP / "harness/loop/verification_gates.py").read_text()
db_block = GATES_SRC.split('"rust-db-test"', 1)[1].split('"flutter-analyze"', 1)[0]
DB_GATE_FILES = set(re.findall(r'"--test", "(\w+)"', db_block.split("--ignored")[0]))
FEATURE_GATED = {(f, t) for f, ts in re.findall(r'"--features", "(\w+)",((?:\s*"--test", "\w+",?)+)', GATES_SRC) for t in re.findall(r'"--test", "(\w+)"', ts)}
WORKFLOWS = "\n".join(p.read_text(errors="replace") for p in (REPO / ".github/workflows").glob("*.yml"))
OPT_IN = set(re.findall(r'"--test", "\w+",\s*"(\w+)", "--", "--exact"', db_block))

tests = []


def rel(p):
    return p.relative_to(REPO).as_posix()


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
        elif c in "\"'" and not (c == "'" and open_c == "{"):  # Rust lifetimes use '
            in_str = c
        elif c == '"' :
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
    text = path.read_text(errors="replace")
    file_cfg = re.search(r'#!\[cfg\(feature\s*=\s*"(\w+)"\)\]', text)
    for m in re.finditer(r"#\[(tokio::test|test|sqlx::test|actix_rt::test)[^\]]*\]", text):
        # attribute block: go back to collect sibling attrs/comments, forward to fn
        head_start = text.rfind("\n\n", 0, m.start())
        fn = re.compile(r"(?:pub\s+)?(?:async\s+)?fn\s+(\w+)").search(text, m.end())
        if not fn:
            continue
        attrs = text[head_start:fn.start()] + text[m.start():fn.start()]
        body_open = text.find("{", fn.end())
        body_close = match_brace(text, body_open)
        body = text[body_open:body_close + 1]
        line = text.count("\n", 0, fn.start()) + 1
        ignore = re.search(r'#\[ignore(?:\s*=\s*"([^"]*)")?\]', attrs)
        should_panic = re.search(r"#\[should_panic(\([^)]*\))?\]", attrs)
        name = fn.group(1)
        stem = path.stem
        in_src = "/src/" in rel(path)
        if file_cfg and (file_cfg.group(1), stem) in FEATURE_GATED:
            run, run_note = "ci", f"rust-test with --features {file_cfg.group(1)}"
        elif file_cfg:
            run = "never-in-ci" ; run_note = f"file compiled only with --features {file_cfg.group(1)}; no CI gate passes it"
        elif ignore:
            if stem in DB_GATE_FILES:
                run, run_note = "ci-db-gate", "#[ignore], run by rust-db-test --ignored"
            else:
                run, run_note = "never-in-ci", f"#[ignore] and {stem}.rs is not in the rust-db-test --test list"
        else:
            run, run_note = "ci", "rust-test"
        env_guard = re.search(r'env::var\("(SITEPULSE_\w+)"\)[^\n]*\n\s*(?:println|eprintln)!\("SKIP', body)
        if env_guard:
            if name in OPT_IN:
                run, run_note = "ci-db-gate", f"env-guarded ({env_guard.group(1)}); opt-in command in rust-db-test; reports PASS without running in rust-test"
            else:
                run, run_note = "silent-pass", f"returns early unless {env_guard.group(1)}=1; never set in CI, so it reports PASS without running"
        asserts = RS_ASSERT.findall(body)
        tests.append(dict(
            lang="rust", file=rel(path), line=line, name=name, in_src=in_src,
            markers=[x for x in [ignore and f"ignore: {ignore.group(1) or ''}".strip(), should_panic and ("should_panic" + (should_panic.group(1) or "")), file_cfg and f"cfg(feature={file_cfg.group(1)})"] if x],
            run=run, run_note=run_note,
            n_assert=len(asserts), n_unwrap=len(re.findall(r"\.(unwrap|expect)\(", body)),
            weak=len(RS_WEAK.findall(body)),
            sleep=bool(SLEEP.search(body)), swallow=len(SWALLOW_RS.findall(body)),
            should_panic_unchecked=bool(should_panic and "expected" not in (should_panic.group(1) or "")),
            loc=body.count("\n") + 1, end=line + body.count("\n"),
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
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) or not node.name.startswith("test"):
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
        weak = sum(py_weak(a) for a in asserts)
        waits = [n for n in ast.walk(node) if isinstance(n, ast.Call) and re.match(r"^(wait|wait_for\w*|run_suite)$", py_call_name(n) or "")]
        swallow = sum(1 for n in ast.walk(node) if isinstance(n, ast.ExceptHandler) and all(isinstance(s, ast.Pass) for s in n.body))
        early_return = any(isinstance(s, ast.If) and any(isinstance(b, ast.Return) for b in s.body) and re.search(r"environ|getenv|which|exists\(", ast.unparse(s.test)) for s in node.body[:4])
        cond_only = bool(asserts) and all(any(a in ast.walk(i) for i in ast.walk(node) if isinstance(i, ast.If)) for a in asserts) and not calls
        src = ast.get_source_segment(text, node) or ""
        run, note = "ci", suite
        if any("xfail" in d or "expectedFailure" in d for d in all_decos):
            run, note = "xfail", suite
        elif any(re.search(r"\bskip\b|skip\(|skipTest", d) for d in all_decos):
            run, note = "skipped", suite
        elif any("skipIf" in d or "skipUnless" in d for d in all_decos):
            run, note = "conditional", suite + " (" + "; ".join(d for d in all_decos if "skip" in d)[:160] + ")"
        env_skip = re.search(r'if not os\.environ\.get\("(\w+)"\):\s*\n\s*pytest\.skip', src)
        if env_skip and env_skip.group(1) not in WORKFLOWS:
            run, note = "silent-skip", suite + f" (pytest.skip unless {env_skip.group(1)} is set; no workflow sets it)"
        if early_return:
            run, note = "silent-pass", suite + " (returns early on missing env/tool: reported PASS)"
        tests.append(dict(
            lang="python", file=rel(path), line=node.lineno, name=node.name, in_src=False,
            markers=marks, run=run, run_note=note,
            n_assert=len(asserts) + len(calls) + len(withs), n_unwrap=0, weak=weak,
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
for p in sorted((REPO / "tests").rglob("test_*.py")):
    py_scan(p, "engineering-harness-ci")

# pytest-bdd scenarios automated by step definitions (test_features.py) are 'gherkin' mode
# Cucumber pilot: not run by CI
pilot = ["SC-10-01-01", "SC-10-04-01", "SC-10-04-02", "SC-07-06-03"]

for t in tests:
    flags = []
    if t["n_assert"] == 0 and t["n_unwrap"] == 0 and t.get("n_wait"):
        flags.append("wait-only (no explicit assertion)" if "linked_backend_suites" not in t["file"] else "suite-wrapper")
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

# ---- scenario join ---------------------------------------------------------------------------
cat = ft.load_catalogue(SP)
index = defaultdict(list)
for t in tests:
    sp_rel = (REPO / t["file"]).relative_to(SP).as_posix() if str(REPO / t["file"]).startswith(str(SP)) else t["file"]
    index[(sp_rel, t["name"])].append(t)
    index[("*", t["name"])].append(t)

by_file = defaultdict(list)
for t in tests:
    by_file[(REPO / t["file"]).relative_to(SP).as_posix() if str(REPO / t["file"]).startswith(str(SP)) else t["file"]].append(t)


def by_line(f, ln):
    ts = by_file.get(f, [])
    inside = [t for t in ts if t.get("deco_line", t["line"]) - 1 <= ln <= t["end"]]
    if inside:
        return [min(inside, key=lambda t: t["end"] - t["line"])]
    after = sorted((t for t in ts if 0 < t.get("deco_line", t["line"]) - ln <= 15), key=lambda t: t["line"])
    return after[:1]


WRAPPER = "e2e/tests/test_linked_backend_suites.py"
scen_rows = []
test_scen_count = Counter()
for s in cat.scenarios:
    refs = cat.links.get(s.id, [])
    resolved = []
    for r in refs:
        cand = (index.get((r["file"], r["test"])) if r["test"] else None) or by_line(r["file"], r["line"])
        if not cand and r["file"].startswith("scripts/"):
            resolved.append(dict(ref=r, kind="script", test=None))
            continue
        if not cand:
            first = min((t["line"] for t in by_file.get(r["file"], [])), default=10**9)
            resolved.append(dict(ref=r, kind="file-level" if r["line"] < first else "unresolved", test=None))
            continue
        t = cand[0]
        test_scen_count[(t["file"], t["name"])] += 1
        resolved.append(dict(ref=r, kind="wrapper" if t["file"].endswith(WRAPPER) else "test", test=t,
                             attached_by="name" if r["test"] else "line"))
    run_ok = [x for x in resolved if x["kind"] in ("script", "file-level") or (x["test"] and x["test"]["run"] in ("ci", "ci-db-gate", "conditional"))]  # silent-skip / never-in-ci do not count
    WEAKF = {"no-assertion", "weak-assertions-only", "only-unwrap (passes if nothing panics)", "wait-only (no explicit assertion)"}
    precise = [x for x in run_ok if x["kind"] == "test"]
    strong = [x for x in precise if not set(x["test"]["flags"]) & WEAKF]
    if s.mode == "pending":
        verdict = "PENDING"
    elif s.mode == "gherkin":
        verdict = "GHERKIN"
    elif not refs:
        verdict = "NO-LINK"
    elif not run_ok:
        verdict = "LINKED-BUT-NEVER-RUN"
    elif not precise:
        kinds = {x["kind"] for x in run_ok}
        verdict = "FILE-LEVEL-ONLY" if kinds == {"file-level"} else "SCRIPT-ONLY" if kinds == {"script"} else "COARSE-ONLY"
    elif not strong:
        verdict = "LINKED-WEAK-ONLY"
    else:
        verdict = "OK"
    layer_mismatch = False
    if s.layer == "gui" and s.mode == "linked":
        layer_mismatch = not any(x["test"] and x["test"]["file"].endswith(".py") and "/e2e/" in x["test"]["file"] for x in resolved) and not any(x["test"] and x["test"]["lang"] == "dart" for x in resolved)
    scen_rows.append(dict(
        id=s.id, name=s.name, mode=s.mode, layer=s.layer, file=s.file, line=s.line,
        priority=next((p for p in ("smoke", "core", "edge") if p in s.all_tags), ""),
        pending_note=s.pending_note, verdict=verdict, layer_mismatch=layer_mismatch,
        unresolved=[x["ref"] for x in resolved if x["kind"] == "unresolved"],
        links=[dict(file=x["ref"]["file"], line=x["ref"]["line"], test=x["ref"]["test"],
                    run=(x["test"] or {}).get("run", x["kind"]), flags=(x["test"] or {}).get("flags", []),
                    kind=x["kind"], resolved_test=(x["test"] or {}).get("name"), attached_by=x.get("attached_by"))
               for x in resolved],
        cucumber_pilot=s.id in pilot,
    ))

for t in tests:
    t["scenarios_claimed"] = test_scen_count.get((t["file"], t["name"]), 0)

OUT.write_text(json.dumps(dict(tests=tests, scenarios=scen_rows, db_gate_files=sorted(DB_GATE_FILES), opt_in=sorted(OPT_IN)), indent=1))
print("tests", len(tests), Counter(t["lang"] for t in tests))
print("run", Counter((t["lang"], t["run"]) for t in tests))
print("flags", Counter(f for t in tests for f in t["flags"]))
print("verdicts", Counter(r["verdict"] for r in scen_rows))
print("layer mismatch", sum(r["layer_mismatch"] for r in scen_rows))
print("link kinds", Counter(l["kind"] for r in scen_rows for l in r["links"]))
print("attached_by line", sum(1 for r in scen_rows for l in r["links"] if l.get("attached_by")=="line"))
print("unresolved links", sum(len(r["unresolved"]) for r in scen_rows))
