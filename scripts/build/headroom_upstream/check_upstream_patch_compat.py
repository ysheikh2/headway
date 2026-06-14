#!/usr/bin/env python3
"""Verify local upstream patch script against latest Headroom source.

This script is intended for CI/scheduled automation:
- Clone upstream Headroom at a target ref.
- Apply scripts/build/headroom_upstream/patch_headroom_upstream.py.
- Optionally run cargo check smoke validation.
- Optionally update a tracked compatibility record JSON in this repo.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PATCH_SCRIPT = REPO_ROOT / "scripts" / "build" / "headroom_upstream" / "patch_headroom_upstream.py"
DEFAULT_RECORD = (
    REPO_ROOT / "scripts" / "build" / "headroom_upstream" / "upstream_patch_compat.json"
)


@dataclass
class CompatResult:
    upstream_repo: str
    requested_ref: str
    resolved_sha: str
    patch_script: str
    patch_apply_ok: bool
    cargo_check_ok: bool

    def as_record(self) -> dict[str, object]:
        return {
            "upstream_repo": self.upstream_repo,
            "requested_ref": self.requested_ref,
            "resolved_sha": self.resolved_sha,
            "patch_script": self.patch_script,
            "patch_apply_ok": self.patch_apply_ok,
            "cargo_check_ok": self.cargo_check_ok,
            "checked_at_utc": datetime.now(UTC).isoformat(),
        }


def run(cmd: list[str], *, cwd: Path | None = None) -> str:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=False,
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        out = proc.stdout.strip()
        err = proc.stderr.strip()
        raise RuntimeError(
            f"Command failed ({proc.returncode}): {' '.join(cmd)}\nstdout:\n{out}\nstderr:\n{err}"
        )
    return proc.stdout.strip()


def clone_upstream(repo: str, ref: str, dest: Path) -> str:
    remote = f"https://github.com/{repo}.git"
    run(["git", "clone", "--depth", "1", "--branch", ref, remote, str(dest)])
    return run(["git", "rev-parse", "HEAD"], cwd=dest)


def apply_patch(headroom_root: Path) -> None:
    run([sys.executable, str(PATCH_SCRIPT), str(headroom_root)])


def run_cargo_check(headroom_root: Path) -> None:
    run(
        [
            "cargo",
            "check",
            "-p",
            "headroom-proxy",
            "--manifest-path",
            str(headroom_root / "Cargo.toml"),
        ]
    )


def maybe_update_record(record_path: Path, record: dict[str, object]) -> bool:
    existing: dict[str, object] = {}
    if record_path.exists():
        try:
            existing = json.loads(record_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Invalid JSON in {record_path}: {exc}") from exc

    stable_keys = [
        "upstream_repo",
        "requested_ref",
        "resolved_sha",
        "patch_script",
        "patch_apply_ok",
        "cargo_check_ok",
    ]
    if all(existing.get(k) == record.get(k) for k in stable_keys):
        return False

    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return True


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo", default="chopratejas/headroom", help="Upstream GitHub repo owner/name"
    )
    parser.add_argument("--ref", default="main", help="Git ref to validate")
    parser.add_argument(
        "--cargo-check",
        action="store_true",
        help="Run cargo check -p headroom-proxy after patch application",
    )
    parser.add_argument(
        "--record-path",
        default="",
        help="If set, update compatibility JSON only when upstream SHA/result changed",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if not PATCH_SCRIPT.exists():
        raise SystemExit(f"Patch script not found: {PATCH_SCRIPT}")

    with tempfile.TemporaryDirectory(prefix="headroom-upstream-") as tmp:
        checkout = Path(tmp) / "headroom"
        resolved_sha = clone_upstream(args.repo, args.ref, checkout)
        apply_patch(checkout)
        cargo_ok = False
        if args.cargo_check:
            run_cargo_check(checkout)
            cargo_ok = True

    result = CompatResult(
        upstream_repo=args.repo,
        requested_ref=args.ref,
        resolved_sha=resolved_sha,
        patch_script=str(PATCH_SCRIPT.relative_to(REPO_ROOT)),
        patch_apply_ok=True,
        cargo_check_ok=cargo_ok,
    )
    record = result.as_record()

    print(json.dumps(record, indent=2, sort_keys=True))

    if args.record_path:
        record_path = Path(args.record_path)
        if not record_path.is_absolute():
            record_path = REPO_ROOT / record_path
        updated = maybe_update_record(record_path, record)
        print(
            f"record {'updated' if updated else 'unchanged'}: {record_path.relative_to(REPO_ROOT)}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
