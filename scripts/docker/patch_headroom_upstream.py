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


def patch_bedrock_anthropic_vendor_match(root: Path) -> None:
    invoke = root / "crates" / "headroom-proxy" / "src" / "bedrock" / "invoke.rs"
    invoke_streaming = (
        root / "crates" / "headroom-proxy" / "src" / "bedrock" / "invoke_streaming.rs"
    )

    for target in (invoke, invoke_streaming):
        replace_once(
            target,
            'const ANTHROPIC_VENDOR_PREFIX: &str = "anthropic.";\n',
            'const ANTHROPIC_VENDOR_PREFIX: &str = "anthropic.";\n'
            'const ANTHROPIC_VENDOR_SEGMENT: &str = ".anthropic.";\n\n'
            'fn is_anthropic_model_id(model_id: &str) -> bool {\n'
            '    model_id.starts_with(ANTHROPIC_VENDOR_PREFIX)\n'
            '        || model_id.contains(ANTHROPIC_VENDOR_SEGMENT)\n'
            '}\n',
            f"anthropic vendor matcher patch ({target.name})",
        )

        replace_once(
            target,
            "let is_anthropic = model_id.starts_with(ANTHROPIC_VENDOR_PREFIX);",
            "let is_anthropic = is_anthropic_model_id(&model_id);",
            f"anthropic model detection usage patch ({target.name})",
        )


def patch_bedrock_converse_body_support(root: Path) -> None:
    invoke = root / "crates" / "headroom-proxy" / "src" / "bedrock" / "invoke.rs"
    invoke_streaming = (
        root / "crates" / "headroom-proxy" / "src" / "bedrock" / "invoke_streaming.rs"
    )

    replace_once(
        invoke,
        """    if let Err(e) = BedrockEnvelope::parse(body) {
        tracing::warn!(
            event = \"bedrock_envelope_parse_error\",
            request_id = %request_id,
            error = %e,
            \"bedrock invoke: envelope parse failed; passing body through unchanged\"
        );
        return body.clone();
    }
    tracing::info!(
        event = \"bedrock_envelope_parsed\",
        request_id = %request_id,
        body_bytes = body.len(),
        \"bedrock invoke: envelope validated; dispatching to live-zone compressor\"
    );
""",
        """    let parsed_envelope = BedrockEnvelope::parse(body).is_ok();
    if parsed_envelope {
        tracing::info!(
            event = \"bedrock_envelope_parsed\",
            request_id = %request_id,
            body_bytes = body.len(),
            \"bedrock invoke: envelope validated; dispatching to live-zone compressor\"
        );
    } else {
        tracing::info!(
            event = \"bedrock_envelope_parse_skipped\",
            request_id = %request_id,
            \"bedrock invoke: envelope parse skipped; attempting generic anthropic compression\"
        );
    }
""",
        "invoke converse payload support parse gate",
    )

    replace_once(
        invoke,
        """        AnthropicOutcome::Compressed { body: new_body, .. } => {
            // Defence-in-depth: re-emit so anthropic_version is the
            // first key. With preserve_order this is a no-op on the
            // happy path.
            match BedrockEnvelope::ensure_anthropic_version_first(&new_body) {
                Ok(b) => b,
                Err(e) => {
                    tracing::error!(
                        event = \"bedrock_envelope_reemit_failed\",
                        request_id = %request_id,
                        error = %e,
                        \"bedrock invoke: failed to re-emit envelope; falling back to original body\"
                    );
                    body.clone()
                }
            }
        }
""",
        """        AnthropicOutcome::Compressed { body: new_body, .. } => {
            if parsed_envelope {
                // Defence-in-depth: re-emit so anthropic_version is the
                // first key. With preserve_order this is a no-op on the
                // happy path.
                match BedrockEnvelope::ensure_anthropic_version_first(&new_body) {
                    Ok(b) => b,
                    Err(e) => {
                        tracing::error!(
                            event = \"bedrock_envelope_reemit_failed\",
                            request_id = %request_id,
                            error = %e,
                            \"bedrock invoke: failed to re-emit envelope; falling back to original body\"
                        );
                        body.clone()
                    }
                }
            } else {
                new_body
            }
        }
""",
        "invoke converse payload support compressed branch",
    )

    replace_once(
        invoke_streaming,
        """    if let Err(e) = BedrockEnvelope::parse(body) {
        tracing::warn!(
            event = \"bedrock_envelope_parse_error\",
            request_id = %request_id,
            error = %e,
            \"bedrock invoke-streaming: envelope parse failed; passing body through unchanged\"
        );
        return body.clone();
    }
""",
        """    let parsed_envelope = BedrockEnvelope::parse(body).is_ok();
    if !parsed_envelope {
        tracing::info!(
            event = \"bedrock_envelope_parse_skipped\",
            request_id = %request_id,
            \"bedrock invoke-streaming: envelope parse skipped; attempting generic anthropic compression\"
        );
    }
""",
        "invoke_streaming converse payload support parse gate",
    )

    replace_once(
        invoke_streaming,
        """        AnthropicOutcome::Compressed { body: new_body, .. } => {
            match BedrockEnvelope::ensure_anthropic_version_first(&new_body) {
                Ok(b) => b,
                Err(e) => {
                    tracing::error!(
                        event = \"bedrock_envelope_reemit_failed\",
                        request_id = %request_id,
                        error = %e,
                        \"bedrock invoke-streaming: failed to re-emit envelope\"
                    );
                    body.clone()
                }
            }
        }
""",
        """        AnthropicOutcome::Compressed { body: new_body, .. } => {
            if parsed_envelope {
                match BedrockEnvelope::ensure_anthropic_version_first(&new_body) {
                    Ok(b) => b,
                    Err(e) => {
                        tracing::error!(
                            event = \"bedrock_envelope_reemit_failed\",
                            request_id = %request_id,
                            error = %e,
                            \"bedrock invoke-streaming: failed to re-emit envelope\"
                        );
                        body.clone()
                    }
                }
            } else {
                new_body
            }
        }
""",
        "invoke_streaming converse payload support compressed branch",
    )


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_headroom_upstream.py <headroom-root>")

    root = Path(sys.argv[1]).resolve()
    if not root.exists():
        raise SystemExit(f"headroom root does not exist: {root}")

    patch_aws_sso(root)
    patch_eventstream_default(root)
    patch_bedrock_anthropic_vendor_match(root)
    patch_bedrock_converse_body_support(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
