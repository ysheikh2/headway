#!/usr/bin/env sh
# Headroom entrypoint wrapper — installs the unified stats patch into
# site-packages and then launches the normal headroom proxy.
#
# This runs inside the ghcr.io/chopratejas/headroom:code container at startup.
# The /opt/headroom-patch directory is bind-mounted from the host repo.
set -e

PATCH_SRC="/opt/headroom-patch/headroom_patch"
SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])")

# Install the patch package into site-packages by symlink so it's importable.
if [ -d "$PATCH_SRC" ]; then
  ln -sfn "$PATCH_SRC" "${SITE_PACKAGES}/headroom_patch"
fi

# Write a usercustomize.py into site-packages (loads after site.py, after packages).
cat >"${SITE_PACKAGES}/usercustomize.py" <<'PYEOF'
try:
    from headroom_patch import bedrock_native_patch, unified_stats_patch
    bedrock_native_patch.apply_patch()
    unified_stats_patch.apply_patch()
except Exception:
    pass
PYEOF

# Run the original headroom proxy entrypoint.
exec python3 -m headroom.cli proxy "$@"
