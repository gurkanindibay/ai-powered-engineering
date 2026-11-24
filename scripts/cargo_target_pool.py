#!/usr/bin/env python3
"""Bound the disk used by Cargo build output when many agents work in separate worktrees.

Cargo writes a full `target/` inside every worktree, so disk use grows with each agent and
nothing removes it afterwards. This tool keeps build output in a fixed pool of slots on a
cache volume instead. An agent leases one slot for the lifetime of a command, so disk is capped
at N slots no matter how many worktrees exist, and a new worktree starts warm because the slot
still holds the compiled dependencies.

Usage:
    python3 scripts/cargo_target_pool.py run -- cargo test --locked
    python3 scripts/cargo_target_pool.py measure [--target-dir DIR] [--json]
    python3 scripts/cargo_target_pool.py status [--json]
    python3 scripts/cargo_target_pool.py sweep --max-age-days 7 [--json]
    python3 scripts/cargo_target_pool.py watchdog --min-free-gb 20 [--json]
    python3 scripts/cargo_target_pool.py clean-worktree <path> [--dry-run] [--json]

Pool layout (`--pool-dir`, default `$CARGO_TARGET_POOL_DIR` or `~/.cache/agent-cargo-pool`):
    slot-0/            the Cargo target directory
    slot-0.lock        flock file: held while a command uses the slot
    slot-0.json        {"fingerprint": ..., "last_used": <epoch seconds>}

`run` leases one free slot, exports CARGO_TARGET_DIR (and CARGO_INCREMENTAL=0 unless it is
already set), runs the command and releases the slot. The lock file descriptor is passed on to
the command, so the slot stays leased while any process still uses it, even if this tool is
killed; the operating system releases it when the last holder exits. A slot is wiped before use
when the build fingerprint (RUSTFLAGS, wrapper, toolchain) differs from the one it was built
with, because Cargo would otherwise keep both sets of artifacts and the slot would only grow.

Exit codes: 0 ok (for `run`, the command's own exit code), 2 usage error, 3 disk still below the
free-space threshold, 75 no free slot (retry later). POSIX only (uses flock).
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Sequence

DEFAULT_SLOTS = 4
EXIT_LOW_DISK = 3
EXIT_BUSY = 75
CACHEDIR_TAG = "CACHEDIR.TAG"
CARGO_TAG_SIGNATURE = "Signature: 8a477f597d28d172789f06886806bc55"
FINGERPRINT_ENV = ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER")
SKIPPED_DIRS = {".git", "node_modules"}
GIB = 1024**3


class PoolError(Exception):
    """Usage error (exit 2)."""


def default_pool_dir(env: dict[str, str]) -> Path:
    configured = env.get("CARGO_TARGET_POOL_DIR")
    return Path(configured).expanduser() if configured else Path.home() / ".cache" / "agent-cargo-pool"


def default_slots(env: dict[str, str]) -> int:
    raw = env.get("CARGO_TARGET_POOL_SLOTS")
    if not raw:
        return DEFAULT_SLOTS
    try:
        value = int(raw)
    except ValueError as error:
        raise PoolError(f"CARGO_TARGET_POOL_SLOTS must be an integer, got {raw!r}") from error
    return value


def dir_size(path: Path) -> int:
    """Disk usage in bytes (allocated blocks), counting each hard-linked file once."""
    seen: set[tuple[int, int]] = set()
    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            try:
                info = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if entry.is_dir(follow_symlinks=False):
                stack.append(Path(entry.path))
                continue
            key = (info.st_dev, info.st_ino)
            if key in seen:
                continue
            seen.add(key)
            total += info.st_blocks * 512
    return total


def free_bytes(path: Path) -> int:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    return shutil.disk_usage(probe).free


def build_fingerprint(env: dict[str, str], toolchain: str) -> str:
    parts = [f"{name}={env.get(name, '')}" for name in FINGERPRINT_ENV]
    parts.append(f"toolchain={toolchain}")
    return "\n".join(parts)


def detect_toolchain() -> str:
    """`rustc -vV` of the toolchain the command will use; empty when rustc is not installed."""
    try:
        done = subprocess.run(["rustc", "-vV"], capture_output=True, text=True, check=False, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout.strip() if done.returncode == 0 else ""


@dataclass
class Slot:
    index: int
    path: Path
    lock_path: Path
    meta_path: Path

    @property
    def name(self) -> str:
        return f"slot-{self.index}"

    def read_meta(self) -> dict:
        try:
            return json.loads(self.meta_path.read_text())
        except (OSError, ValueError):
            return {}

    def write_meta(self, fingerprint: str, now: float) -> None:
        self.meta_path.write_text(json.dumps({"fingerprint": fingerprint, "last_used": now}))

    def last_used(self) -> float:
        value = self.read_meta().get("last_used", 0)
        return float(value) if isinstance(value, (int, float)) else 0.0

    def wipe(self) -> None:
        shutil.rmtree(self.path, ignore_errors=True)


class Lease:
    """An exclusive flock on one slot, held until `release`."""

    def __init__(self, slot: Slot, fd: int, fingerprint: str, clock: Callable[[], float]) -> None:
        self.slot = slot
        self.fd = fd
        self.fingerprint = fingerprint
        self._clock = clock
        self.released = False

    def release(self) -> None:
        if self.released:
            return
        self.released = True
        self.slot.write_meta(self.fingerprint, self._clock())
        os.close(self.fd)  # closing the descriptor releases the flock

    def __enter__(self) -> "Lease":
        return self

    def __exit__(self, *exc: object) -> None:
        self.release()


def _try_lock(lock_path: Path) -> int | None:
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


class Pool:
    def __init__(self, root: Path, slots: int, clock: Callable[[], float] = time.time) -> None:
        if slots < 1:
            raise PoolError("--slots must be at least 1")
        self.root = root
        self.slots = slots
        self.clock = clock

    def slot(self, index: int) -> Slot:
        return Slot(index, self.root / f"slot-{index}", self.root / f"slot-{index}.lock",
                    self.root / f"slot-{index}.json")

    def all_slots(self) -> list[Slot]:
        return [self.slot(i) for i in range(self.slots)]

    def try_lease(self, fingerprint: str) -> Lease | None:
        """Lease a free slot, preferring the most recently used one built with this fingerprint."""
        self.root.mkdir(parents=True, exist_ok=True)

        def preference(slot: Slot) -> tuple[int, float]:
            warm = slot.read_meta().get("fingerprint") == fingerprint
            return (0 if warm else 1, -slot.last_used())

        for slot in sorted(self.all_slots(), key=preference):
            fd = _try_lock(slot.lock_path)
            if fd is None:
                continue
            if slot.read_meta().get("fingerprint") != fingerprint:
                slot.wipe()
            slot.path.mkdir(parents=True, exist_ok=True)
            slot.write_meta(fingerprint, self.clock())
            return Lease(slot, fd, fingerprint, self.clock)
        return None

    def lease(self, fingerprint: str, wait: float, sleep: Callable[[float], None] = time.sleep) -> Lease | None:
        deadline = self.clock() + wait
        while True:
            lease = self.try_lease(fingerprint)
            if lease is not None or self.clock() >= deadline:
                return lease
            sleep(1.0)

    def is_leased(self, slot: Slot) -> bool:
        fd = _try_lock(slot.lock_path)
        if fd is None:
            return True
        os.close(fd)
        return False

    def status(self) -> list[dict]:
        report = []
        for slot in self.all_slots():
            report.append({
                "slot": slot.name,
                "path": str(slot.path),
                "leased": self.is_leased(slot),
                "bytes": dir_size(slot.path) if slot.path.exists() else 0,
                "last_used": slot.last_used() or None,
            })
        return report

    def _wipe_if_idle(self, slot: Slot) -> int:
        """Wipe an unleased slot while holding its lock; returns the bytes freed."""
        fd = _try_lock(slot.lock_path)
        if fd is None:
            return 0
        try:
            freed = dir_size(slot.path) if slot.path.exists() else 0
            slot.wipe()
            slot.meta_path.unlink(missing_ok=True)
            return freed
        finally:
            os.close(fd)

    def sweep(self, max_age_days: float) -> dict:
        """Wipe idle slots, and orphaned temp dirs, unused for longer than `max_age_days`."""
        cutoff = self.clock() - max_age_days * 86400
        swept, freed = [], 0
        for slot in self.all_slots():
            if slot.path.exists() and slot.last_used() < cutoff:
                bytes_freed = self._wipe_if_idle(slot)
                if not self.is_leased(slot) and not slot.path.exists():
                    swept.append(slot.name)
                    freed += bytes_freed
        for orphan in sorted(self.root.glob("tmp-*")) if self.root.exists() else []:
            try:
                if orphan.stat().st_mtime < cutoff:
                    freed += dir_size(orphan)
                    shutil.rmtree(orphan, ignore_errors=True)
                    swept.append(orphan.name)
            except OSError:
                continue
        return {"swept": swept, "freed_bytes": freed}

    def watchdog(self, min_free_bytes: int, free: Callable[[Path], int] = free_bytes) -> dict:
        """Wipe least recently used idle slots until free space is back above the threshold."""
        swept, freed = [], 0
        candidates = sorted((s for s in self.all_slots() if s.path.exists()), key=Slot.last_used)
        for slot in candidates:
            if free(self.root) >= min_free_bytes:
                break
            bytes_freed = self._wipe_if_idle(slot)
            if not slot.path.exists():
                swept.append(slot.name)
                freed += bytes_freed
        free_now = free(self.root)
        return {"ok": free_now >= min_free_bytes, "free_bytes": free_now,
                "min_free_bytes": min_free_bytes, "swept": swept, "freed_bytes": freed}


def measure(target: Path) -> dict:
    """Where the bytes of one Cargo target directory go."""
    report: dict = {"target_dir": str(target), "exists": target.is_dir(), "total_bytes": 0, "profiles": {}}
    if not target.is_dir():
        return report
    report["total_bytes"] = dir_size(target)
    for profile in sorted(p for p in target.iterdir() if p.is_dir() and not p.name.startswith(".")):
        sizes = {name: dir_size(profile / name) for name in ("deps", "incremental", "build")
                 if (profile / name).is_dir()}
        if not sizes:
            continue
        sizes["total"] = dir_size(profile)
        sizes["binaries_in_deps"] = count_binaries(profile / "deps")
        report["profiles"][profile.name] = sizes
    return report


def count_binaries(deps: Path) -> int:
    """Linked executables in deps/: files without an extension that are executable."""
    try:
        entries = list(os.scandir(deps))
    except OSError:
        return 0
    return sum(1 for e in entries
               if e.is_file(follow_symlinks=False) and "." not in e.name and os.access(e.path, os.X_OK))


def find_cargo_targets(worktree: Path) -> Iterator[Path]:
    """Directories named `target` that carry Cargo's CACHEDIR.TAG, so nothing else is touched."""
    stack = [worktree]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False) or entry.name in SKIPPED_DIRS:
                continue
            path = Path(entry.path)
            if entry.name == "target" and is_cargo_target(path):
                yield path
            else:
                stack.append(path)


def is_cargo_target(path: Path) -> bool:
    tag = path / CACHEDIR_TAG
    try:
        return CARGO_TAG_SIGNATURE in tag.read_text(errors="ignore")
    except OSError:
        return False


def clean_worktree(worktree: Path, dry_run: bool) -> dict:
    if not (worktree / ".git").exists():
        raise PoolError(f"{worktree} is not a git worktree or checkout (no .git entry)")
    removed, freed = [], 0
    for target in sorted(find_cargo_targets(worktree)):
        freed += dir_size(target)
        removed.append(str(target.relative_to(worktree)))
        if not dry_run:
            shutil.rmtree(target, ignore_errors=True)
    return {"worktree": str(worktree), "dry_run": dry_run, "removed": removed, "freed_bytes": freed}


def run_command(command: Sequence[str], env: dict[str, str], cwd: Path | None, pass_fds: tuple[int, ...]) -> int:
    proc = subprocess.Popen(list(command), env=env, cwd=cwd, pass_fds=pass_fds)

    def forward(signum: int, _frame: object) -> None:
        proc.send_signal(signum)

    previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        code = proc.wait()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return 128 - code if code < 0 else code


def cmd_run(args: argparse.Namespace, pool: Pool, env: dict[str, str]) -> int:
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        raise PoolError("run needs a command after --")
    if args.min_free_gb > 0:
        verdict = pool.watchdog(int(args.min_free_gb * GIB))
        if not verdict["ok"]:
            emit(args, verdict, f"refusing to start: {verdict['free_bytes'] / GIB:.1f} GiB free, "
                                f"need {args.min_free_gb:g} GiB")
            return EXIT_LOW_DISK
    fingerprint = build_fingerprint(env, detect_toolchain())
    lease, temp_dir = None, None
    if args.on_busy == "wait":
        lease = pool.lease(fingerprint, args.wait)
    else:
        lease = pool.try_lease(fingerprint)
    if lease is None:
        if args.on_busy != "temp":
            emit(args, {"error": "no free slot"}, f"no free slot in {pool.root} ({pool.slots} slots)")
            return EXIT_BUSY
        temp_dir = Path(tempfile.mkdtemp(prefix="tmp-", dir=pool.root))
    target = temp_dir if temp_dir is not None else lease.slot.path
    child_env = dict(env, CARGO_TARGET_DIR=str(target))
    child_env.setdefault("CARGO_INCREMENTAL", "0")
    child_env["CARGO_TARGET_POOL_SLOT"] = target.name
    pass_fds: tuple[int, ...] = ()
    if lease is not None:
        os.set_inheritable(lease.fd, True)
        pass_fds = (lease.fd,)
    try:
        return run_command(command, child_env, None, pass_fds)
    finally:
        if lease is not None:
            lease.release()
        if temp_dir is not None:
            shutil.rmtree(temp_dir, ignore_errors=True)


def emit(args: argparse.Namespace, payload: dict | list, text: str) -> None:
    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(text, file=sys.stderr if args.command_name == "run" else sys.stdout)


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} GiB"


def cmd_measure(args: argparse.Namespace, _pool: Pool, env: dict[str, str]) -> int:
    configured = args.target_dir or env.get("CARGO_TARGET_DIR")
    report = measure(Path(configured) if configured else Path.cwd() / "target")
    lines = [f"{report['target_dir']}: {human(report['total_bytes'])}"]
    for profile, sizes in report["profiles"].items():
        parts = ", ".join(f"{k} {human(v)}" for k, v in sizes.items() if k != "binaries_in_deps")
        lines.append(f"  {profile}: {parts}; {sizes['binaries_in_deps']} linked binaries in deps")
    emit(args, report, "\n".join(lines))
    return 0


def cmd_status(args: argparse.Namespace, pool: Pool, _env: dict[str, str]) -> int:
    report = pool.status()
    lines = [f"{r['slot']}: {'LEASED' if r['leased'] else 'idle'}, {human(r['bytes'])}" for r in report]
    emit(args, report, "\n".join(lines))
    return 0


def cmd_sweep(args: argparse.Namespace, pool: Pool, _env: dict[str, str]) -> int:
    report = pool.sweep(args.max_age_days)
    emit(args, report, f"swept {len(report['swept'])} entries, freed {human(report['freed_bytes'])}")
    return 0


def cmd_watchdog(args: argparse.Namespace, pool: Pool, _env: dict[str, str]) -> int:
    report = pool.watchdog(int(args.min_free_gb * GIB))
    state = "ok" if report["ok"] else "STILL BELOW THRESHOLD"
    emit(args, report, f"{state}: {human(report['free_bytes'])} free, swept {report['swept'] or 'nothing'}")
    return 0 if report["ok"] else EXIT_LOW_DISK


def cmd_clean_worktree(args: argparse.Namespace, _pool: Pool, _env: dict[str, str]) -> int:
    report = clean_worktree(Path(args.path).resolve(), args.dry_run)
    verb = "would remove" if args.dry_run else "removed"
    emit(args, report, f"{verb} {len(report['removed'])} target dirs, {human(report['freed_bytes'])}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Pool Cargo target directories across agent worktrees.")
    parser.add_argument("--pool-dir", type=Path, help="pool directory (default $CARGO_TARGET_POOL_DIR)")
    parser.add_argument("--slots", type=int, help=f"number of slots (default $CARGO_TARGET_POOL_SLOTS or {DEFAULT_SLOTS})")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    # `--json` is accepted before or after the subcommand; SUPPRESS keeps the top-level value.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS, help="machine-readable output")
    sub = parser.add_subparsers(dest="command_name", required=True)

    run = sub.add_parser("run", parents=[common], help="lease a slot and run a command with CARGO_TARGET_DIR set")
    run.add_argument("--on-busy", choices=("wait", "temp", "fail"), default="wait",
                     help="no free slot: wait (default), use a temp dir deleted afterwards, or fail with 75")
    run.add_argument("--wait", type=float, default=600.0, help="seconds to wait for a slot (default 600)")
    run.add_argument("--min-free-gb", type=float, default=0.0,
                     help="sweep idle slots and refuse to start below this free space (default off)")
    run.add_argument("command", nargs=argparse.REMAINDER, help="-- <command> [args...]")
    run.set_defaults(handler=cmd_run)

    meas = sub.add_parser("measure", parents=[common], help="show where the bytes of a target directory go")
    meas.add_argument("--target-dir", help="default $CARGO_TARGET_DIR or ./target")
    meas.set_defaults(handler=cmd_measure)

    sub.add_parser("status", parents=[common], help="show slots, leases and sizes").set_defaults(handler=cmd_status)

    sweep = sub.add_parser("sweep", parents=[common], help="wipe idle slots unused for longer than a number of days")
    sweep.add_argument("--max-age-days", type=float, default=7.0)
    sweep.set_defaults(handler=cmd_sweep)

    dog = sub.add_parser("watchdog", parents=[common], help="wipe least recently used idle slots until enough disk is free")
    dog.add_argument("--min-free-gb", type=float, required=True)
    dog.set_defaults(handler=cmd_watchdog)

    clean = sub.add_parser("clean-worktree", parents=[common], help="delete Cargo target dirs inside a worktree")
    clean.add_argument("path", help="worktree root")
    clean.add_argument("--dry-run", action="store_true")
    clean.set_defaults(handler=cmd_clean_worktree)
    return parser


def main(argv: Sequence[str] | None = None, env: dict[str, str] | None = None) -> int:
    env = dict(os.environ if env is None else env)
    args = build_parser().parse_args(argv)
    try:
        pool = Pool(args.pool_dir or default_pool_dir(env), args.slots or default_slots(env))
        return args.handler(args, pool, env)
    except PoolError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
