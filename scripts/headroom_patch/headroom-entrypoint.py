#!/usr/bin/env python3
"""Headroom wrapper entrypoint.

Installs the unified stats patch into site-packages, then launches
the normal headroom proxy CLI as if this script doesn't exist.

Mounted into the headroom container at /opt/headroom-patch/ via compose volumes.
Compose entrypoint: ["python", "/opt/headroom-patch/headroom-entrypoint.py"]
"""
from __future__ import annotations

import contextlib
import os
import pathlib
import sys

PATCH_SRC = pathlib.Path("/opt/headroom-patch/headroom_patch")


def _find_site_packages() -> pathlib.Path | None:
    """Locate the writable site-packages dir that contains headroom."""
    # Derive from headroom's own __file__ — guaranteed to be the right dir.
    try:
        import headroom as _hr  # ty: ignore[unresolved-import]
        return pathlib.Path(_hr.__file__).parent.parent
    except Exception:
        pass
    # Fallback: first writable entry in sys.path that looks like site-packages.
    for p in sys.path:
        path = pathlib.Path(p)
        if "site-packages" in p and path.is_dir() and os.access(p, os.W_OK):
            return path
    return None


site_pkg = _find_site_packages()

if site_pkg and PATCH_SRC.exists():
    target = site_pkg / "headroom_patch"
    if not target.exists():
        with contextlib.suppress(OSError):
            target.symlink_to(PATCH_SRC)

    with contextlib.suppress(OSError):
        (site_pkg / "usercustomize.py").write_text(
            "try:\n"
            "    from headroom_patch import unified_stats_patch\n"
            "    unified_stats_patch.apply_patch()\n"
            "except Exception:\n"
            "    pass\n"
        )

# Re-exec as the real headroom CLI, forwarding all compose command: args.
# os.execv replaces this process so PID 1 stays the actual proxy.
os.execv(
    sys.executable,
    [sys.executable, "-m", "headroom.cli", "proxy"] + sys.argv[1:],
)
