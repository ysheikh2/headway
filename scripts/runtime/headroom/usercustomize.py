"""Loaded by Python after site-packages are ready (usercustomize hook).

Applies the unified Bedrock+Copilot stats patch to the headroom proxy
before the app starts serving requests.
"""

try:
    from headroom_patch import bedrock_native_patch, unified_stats_patch

    bedrock_native_patch.apply_patch()

    unified_stats_patch.apply_patch()
except Exception:
    pass
