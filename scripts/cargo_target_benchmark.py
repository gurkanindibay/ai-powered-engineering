#!/usr/bin/env python3
"""Measure SitePulse Cargo profiles and target pool reuse on a fixed source revision."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tarfile
import tempfile
import time
from contextlib import ExitStack
from pathlib import Path

from cargo_target_pool import dir_size, measure

ROOT = Path(__file__).resolve().parents[1]
BACKEND = Path("apps/development-time/SitePulse/backend")
POOL_SCRIPT = ROOT / "scripts/cargo_target_pool.py"
PROBE = "cargo_target_benchmark_line_table_probe"
PROFILE_SETTINGS = {
    '[profile.dev]': 'debug = "line-tables-only"',
    '[profile.dev.package."*"]': 'debug = false',
}


def source_archive(revision: str, archive: Path) -> None:
    with archive.open("wb") as destination:
        subprocess.run(
            ["git", "archive", revision, "--", str(BACKEND)],
            cwd=ROOT, stdout=destination, check=True,
        )


def unpack(archive: Path, path: Path, *, baseline: bool = False) -> Path:
    with tarfile.open(archive) as source:
        source.extractall(path, filter="data")
    backend = path / BACKEND
    if baseline:
        manifest = backend / "Cargo.toml"
        contents = manifest.read_text()
        for profile, setting in PROFILE_SETTINGS.items():
            block = f"{profile}\n{setting}\n\n"
            if contents.count(block) != 1:
                raise ValueError(f"expected a single {profile} block with {setting}")
            contents = contents.replace(block, "", 1)
        manifest.write_text(contents)
    with (backend / "src/lib.rs").open("a") as library:
        library.write(f'\n#[test]\nfn {PROBE}() {{ panic!("benchmark line table probe"); }}\n')
    return backend


def artifact_counts(path: Path, backend: Path) -> dict[str, int]:
    rebuilt: dict[str, set[str]] = {"workspace": set(), "dependencies": set()}
    with path.open() as stream:
        for line in stream:
            artifact = json.loads(line)
            if artifact.get("reason") != "compiler-artifact" or artifact["fresh"]:
                continue
            group = "workspace" if Path(artifact["manifest_path"]).is_relative_to(backend) else "dependencies"
            rebuilt[group].add(artifact["package_id"])
    return {group: len(packages) for group, packages in rebuilt.items()}


def cargo_env() -> dict[str, str]:
    overrides = ("CARGO_PROFILE_", "CARGO_INCREMENTAL", "CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR")
    return {key: value for key, value in os.environ.items() if not key.startswith(overrides)}


def stop(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        process.wait()


def builds(
    commands: list[tuple[Path, list[str], dict[str, str]]], logs: Path,
    target_root: Path, sample_seconds: float,
) -> tuple[list[dict], int]:
    logs.mkdir()
    results = []
    peak = dir_size(target_root)
    with ExitStack() as stack:
        running = []
        for index, (backend, argv, env) in enumerate(commands):
            stdout_path = logs / f"{index}.jsonl"
            stderr_path = logs / f"{index}.log"
            stdout = stack.enter_context(stdout_path.open("w"))
            stderr = stack.enter_context(stderr_path.open("w"))
            started = time.monotonic()
            process = subprocess.Popen(argv, cwd=backend, env=env, stdout=stdout, stderr=stderr)
            stack.callback(stop, process)
            running.append((index, backend, stdout_path, stderr_path, started, process))
        while running:
            peak = max(peak, dir_size(target_root))
            for entry in running[:]:
                index, backend, stdout_path, stderr_path, started, process = entry
                code = process.poll()
                if code is None:
                    continue
                running.remove(entry)
                if code:
                    tail = stderr_path.read_text(errors="replace").splitlines()[-25:]
                    raise RuntimeError(f"Cargo build exited with {code}\n" + "\n".join(tail))
                results.append({
                    "index": index,
                    "seconds": round(time.monotonic() - started, 2),
                    "rebuilt_packages": artifact_counts(stdout_path, backend),
                })
            if running:
                time.sleep(sample_seconds)
    return sorted(results, key=lambda result: result["index"]), peak


def run_benchmark(args: argparse.Namespace, scratch: Path) -> dict:
    archive = scratch / "source.tar"
    source_archive(args.revision, archive)
    baseline = unpack(archive, scratch / "baseline", baseline=True)
    slim = unpack(archive, scratch / "slim")
    newcomers = [unpack(archive, scratch / f"agent-{i}") for i in range(args.agents - 1)]
    baseline_target = baseline / "target"
    pool = scratch / "pool"
    env = cargo_env()
    test = ["cargo", "test", "--locked", "--offline", "--no-run", "-j", str(args.jobs),
            "--message-format=json"]
    baseline_command = (baseline, test, dict(env, CARGO_INCREMENTAL="1"))
    lease = [sys.executable, str(POOL_SCRIPT), "--pool-dir", str(pool), "--slots", str(args.slots),
             "run", "--wait", "3600", "--"]
    slim_command = (slim, [*lease, *test], env)

    phases = {}
    for label, command, target_root in (
        ("baseline", baseline_command, baseline_target),
        ("slim", slim_command, pool),
    ):
        print(f"{label}: cold build and rebuild", file=sys.stderr, flush=True)
        cold, cold_peak = builds([command], scratch / f"{label}-cold", target_root, args.sample_seconds)
        (command[0] / "src/lib.rs").touch()
        rebuild, rebuild_peak = builds(
            [command], scratch / f"{label}-rebuild", target_root, args.sample_seconds,
        )
        target = baseline_target if label == "baseline" else pool / "slot-0"
        phases[label] = {
            "cold": cold[0], "rebuild": rebuild[0], "cold_peak_bytes": cold_peak,
            "rebuild_peak_bytes": rebuild_peak, "size": measure(target),
        }

    probe = subprocess.run(
        [*lease, "cargo", "test", "--locked", "--offline", "-j", str(args.jobs),
         "--lib", PROBE, "--", "--exact"],
        cwd=slim, env=dict(env, RUST_BACKTRACE="1"), capture_output=True, text=True,
    )
    source_line = re.search(rf"\b{PROBE}\b[^\n]*\n\s+at (.+src/lib\.rs:\d+:\d+)", probe.stdout)
    if probe.returncode != 101 or source_line is None:
        raise RuntimeError(f"could not verify the test backtrace source line\n{probe.stdout}\n{probe.stderr}")

    print("pool: building from independent source trees", file=sys.stderr, flush=True)
    active, active_peak = builds(
        [slim_command, *((path, [*lease, *test], env) for path in newcomers)],
        scratch / "pool-concurrent", pool, args.sample_seconds,
    )
    # Run after concurrent load to demonstrate that a new tree reuses a warm slot.
    late = unpack(archive, scratch / "late-agent")
    warm, warm_peak = builds(
        [(late, [*lease, *test], env)], scratch / "pool-handoff", pool, args.sample_seconds,
    )
    orphaned = [str(path / "target") for path in [slim, *newcomers, late] if (path / "target").exists()]
    if orphaned or warm[0]["rebuilt_packages"]["dependencies"]:
        raise RuntimeError(f"pooled builds left targets or rebuilt dependencies on handoff: {orphaned}, {warm}")
    phases["pool"] = {
        "agents": args.agents,
        "slots": args.slots,
        "concurrent": active,
        "handoff": warm[0],
        "concurrent_peak_bytes": active_peak,
        "handoff_peak_bytes": warm_peak,
        "slot_sizes": [measure(path) for path in sorted(pool.glob("slot-*")) if path.is_dir()],
        "orphaned_targets": orphaned,
        "backtrace_source": source_line[1],
    }
    return phases


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", default="HEAD", help="Git revision to export for both profiles")
    parser.add_argument("--scratch-dir", type=Path, default=ROOT, help="existing directory on a volume with ample space")
    parser.add_argument("--jobs", type=int, default=2, help="Cargo jobs per build")
    parser.add_argument("--agents", type=int, default=3, help="number of concurrent source trees")
    parser.add_argument("--slots", type=int, default=2, help="target directories available to concurrent agents")
    parser.add_argument("--sample-seconds", type=float, default=2, help="interval between disk measurements")
    parser.add_argument("--json", action="store_true", help="print the benchmark report as JSON")
    args = parser.parse_args()
    if args.jobs < 1 or args.slots < 1 or args.agents <= args.slots or args.sample_seconds <= 0:
        parser.error("jobs, slots and sample-seconds must be positive, and agents must exceed slots")
    try:
        args.revision = subprocess.check_output(
            ["git", "rev-parse", "--verify", f"{args.revision}^{{commit}}"], cwd=ROOT, text=True,
        ).strip()
        report = {
            "revision": args.revision,
            "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
            "machine": platform.machine(),
            "jobs_per_build": args.jobs,
            "sample_seconds": args.sample_seconds,
        }
        with tempfile.TemporaryDirectory(prefix="cargo-target-benchmark-", dir=args.scratch_dir) as directory:
            report.update(run_benchmark(args, Path(directory)))
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"cargo target benchmark: {error}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for profile in ("baseline", "slim"):
            result = report[profile]
            print(f"{profile}: cold {result['cold']['seconds']} s, rebuild {result['rebuild']['seconds']} s, "
                  f"{result['size']['total_bytes'] / 1024**3:.2f} GiB")
        pool = report["pool"]
        print(f"pool: {pool['agents']} agents with {pool['slots']} slots, "
              f"{pool['concurrent_peak_bytes'] / 1024**3:.2f} GiB sampled peak, "
              f"{pool['handoff']['rebuilt_packages']['dependencies']} dependencies rebuilt at handoff")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
