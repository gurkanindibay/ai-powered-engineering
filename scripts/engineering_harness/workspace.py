"""Owned candidate snapshots without modifying or trusting the user's checkout."""
from __future__ import annotations

import io
import os
from pathlib import Path
import subprocess
import tarfile

from .contracts import safe_path, under
from .routing import HarnessError


def git(root: Path, *args: str, binary: bool = False):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": "/nonexistent",
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "GIT_AUTHOR_NAME": "Engineering Harness", "GIT_AUTHOR_EMAIL": "harness@localhost",
           "GIT_COMMITTER_NAME": "Engineering Harness", "GIT_COMMITTER_EMAIL": "harness@localhost"}
    try:
        result = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
                                cwd=root, capture_output=True, timeout=120, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise HarnessError("Git operation could not complete") from exc
    if result.returncode:
        raise HarnessError(f"Git {args[0]} failed: {result.stderr.decode(errors='replace')[:500]}")
    return result.stdout if binary else result.stdout.decode().strip()


class Workspace:
    def __init__(self, directory: Path):
        self.path = Path(directory).resolve()

    def create(self, repository: Path, revision: str = "HEAD") -> tuple[str, str]:
        if self.path.exists():
            raise HarnessError("Candidate workspace already exists")
        repository = repository.resolve()
        source = git(repository, "rev-parse", "--verify", f"{revision}^{{commit}}")
        archive = git(repository, "archive", "--format=tar", source, binary=True)
        self.path.mkdir(parents=True, mode=0o700)
        with tarfile.open(fileobj=io.BytesIO(archive)) as data:
            for entry in data.getmembers():
                name = entry.name.rstrip("/")
                safe_path(name)
                if not (entry.isfile() or entry.isdir()):
                    raise HarnessError(f"Unsupported archive link or special file: {name}")
                parts = Path(name).parts
                if any(p.startswith(".env") or p in (".aws", ".codex", ".ssh") or p.endswith((".pem", ".key")) for p in parts):
                    raise HarnessError(f"Tracked credentials must not enter a worker snapshot: {name}")
            data.extractall(self.path, filter="data")
        git(self.path, "init", "--quiet")
        git(self.path, "add", "--all")
        git(self.path, "commit", "--quiet", "--allow-empty", "-m", f"Harness source {source}")
        return source, self.head()

    def export(self, destination: Path):
        """Export exactly committed content; ignored build files cannot influence gates."""
        archive = git(self.path, "archive", "--format=tar", self.head(), binary=True)
        destination.mkdir(parents=True)
        with tarfile.open(fileobj=io.BytesIO(archive)) as data:
            for entry in data.getmembers():
                safe_path(entry.name.rstrip("/"))
                if not (entry.isfile() or entry.isdir()):
                    raise HarnessError("Candidate contains a link or special file")
            data.extractall(destination, filter="data")

    def head(self) -> str:
        return git(self.path, "rev-parse", "HEAD")

    def clean(self) -> bool:
        return not git(self.path, "status", "--porcelain", "--untracked-files=all")

    def writable(self, paths: list[str]) -> list[Path]:
        result = []
        for relative in paths:
            safe_path(relative)
            path = self.path / relative
            if path.is_symlink() or not path.resolve().is_relative_to(self.path):
                raise HarnessError("Writable path escapes the candidate workspace")
            path.mkdir(parents=True, exist_ok=True)
            result.append(path)
        return result

    def changes(self) -> list[str]:
        tracked = git(self.path, "diff", "--name-only", "-z", "HEAD", binary=True).decode().split("\x00")
        extra = git(self.path, "ls-files", "--others", "--exclude-standard", "-z", binary=True).decode().split("\x00")
        return sorted(set(p for p in tracked + extra if p))

    def integrate(self, allowed: list[str], protected: list[str], message: str) -> str:
        for name in self.changes():
            safe_path(name)
            if not any(under(name, prefix) for prefix in allowed):
                raise HarnessError(f"Worker changed a path outside its assignment: {name}")
            if any(under(name, prefix) for prefix in protected):
                raise HarnessError(f"Worker changed protected checker/policy: {name}")
            path = self.path / name
            if path.is_symlink() or not path.resolve().is_relative_to(self.path):
                raise HarnessError(f"Worker introduced an unsafe symlink: {name}")
        if self.changes():
            git(self.path, "add", "--all")
            git(self.path, "commit", "--quiet", "-m", message)
        return self.head()
