#!/usr/bin/env python3
"""Patch upstream headroom source during docker build.

This repo builds the bedrock-native gateway from upstream commits. Until the
upstream fixes are merged, we apply local surgical patches in one place.
"""

from __future__ import annotations

import sys
from pathlib import Path


def replace_once(path: Path, old: str, new: str, desc: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"{desc}: expected snippet not found in {path}")
    path.write_text(text.replace(old, new, 1))


def patch_aws_sso(root: Path) -> None:
    cargo = root / "Cargo.toml"
    replace_once(
        cargo,
        'aws-config = { version = "1", default-features = false, features = ["behavior-version-latest", "rustls", "rt-tokio"] }',
        'aws-config = { version = "1", default-features = false, features = ["behavior-version-latest", "rustls", "rt-tokio", "sso"] }',
        "aws-config sso feature patch",
    )


def patch_eventstream_default(root: Path) -> None:
    target = root / "crates" / "headroom-proxy" / "src" / "bedrock" / "eventstream_to_sse.rs"

    replace_once(
        target,
        "            None => return OutputMode::Sse,",
        "            None => return OutputMode::EventStream,",
        "output mode default patch",
    )

    replace_once(
        target,
        "        OutputMode::Sse\n",
        "        // Bedrock-native clients frequently send */* (or omit Accept).\n"
        "        // Prefer EventStream unless the caller explicitly requests SSE.\n"
        "        if accept_raw.split(',').any(|t| t.split(';').next().unwrap_or(\"\").trim() == \"*/*\") {\n"
        "            return OutputMode::EventStream;\n"
        "        }\n"
        "        OutputMode::Sse\n",
        "output mode wildcard patch",
    )


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_headroom_upstream.py <headroom-root>")

    root = Path(sys.argv[1]).resolve()
    if not root.exists():
        raise SystemExit(f"headroom root does not exist: {root}")

    patch_aws_sso(root)
    patch_eventstream_default(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
