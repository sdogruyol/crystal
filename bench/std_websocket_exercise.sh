#!/usr/bin/env bash
# RFC 6455 WebSocket standard library exercise driver.
# Runs the websocket exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/websocket.iyi.
#
#     bash bench/std_websocket_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. Handshake accept computation integrity (RFC 6455 1.3 vector mismatch detected)
#   2. Unmasked client frame rejection (server protocol error refusal)
#   3. Oversized control frame rejection (control payload > 125 bytes refusal)
#   4. Fragmented control frame rejection (control frame with FIN=0 refusal)
#   5. Bad RSV bits rejection (RSV1/2/3 set without extension refusal)
#   6. Incremental UTF-8 validation (invalid UTF-8 in split text frame refusal)
#   7. Invalid close code rejection (forbidden wire close codes refusal)
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"
  shift 2
  # IYI_PATH is named here rather than inherited. Without it this build only
  # resolves the module for someone whose shell already exports the path, so
  # the gate passed for its author and was red for CI and for everyone else.
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_websocket_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "$label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return 1
  fi
  "$WORK/$name" >"$WORK/$name.out" 2>&1
  local exit_code=$?
  sed 's/^/  /' "$WORK/$name.out"
  if [ "$exit_code" -ne 0 ]; then
    echo "$label: exited $exit_code"
    status=1
    return 1
  fi
  return 0
}

echo "== the websocket exercise, plain build"
run_case "plain" websocket-plain
if ! grep -q "all std/websocket checks passed" "$WORK/websocket-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every websocket section reported"
for phrase in "base64:" "handshake:" "utf8_validator:" "client_server:" "interleaved_control:" "permessage_deflate:" "rejection_suite:" "live_socket:"; do
  grep -q "$phrase" "$WORK/websocket-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  base64, handshake, utf8_validator, client_server, interleaved_control, permessage_deflate, rejection_suite, and live_socket all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" websocket-release --release
if ! grep -q "all std/websocket checks passed" "$WORK/websocket-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when protocol protections are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy sibling files so all standard modules are reachable
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$target_file" > "$WORK/$dir/std/$target_file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes. That reads as 'this check cannot fail' when the truth is
  # that nothing was broken to test it. Line-anchored patches drift; this
  # catches it at the patch rather than at the conclusion.
  if cmp -s "$REPO/src/std/$target_file" "$WORK/$dir/std/$target_file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_websocket_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched library did not build"
    sed -n '1,12p' "$WORK/$dir/build.log"
    status=1
    return
  fi
  "$WORK/$dir/program" >"$WORK/$dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi
  if ! grep -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. Handshake accept calculation corrupted
prove_fails "handshake accept vector mismatch" handshake_corrupt \
  "assertion failed: RFC 6455 Section 1.3 accept vector" "websocket.iyi" \
  's/258EAFA5-E914-47DA-95CA-C5AB0DC85B11/00000000-0000-0000-0000-000000000000/'

# 2. Unmasked client frame accepted (must fail: unmasked client frame rejected with 1002)
prove_fails "unmasked client frame accepted" unmasked_bypass \
  "assertion failed: unmasked client frame was not rejected" "websocket.iyi" \
  's/unless masked$/if false/g'

# 3. Oversized control frame accepted (must fail: payload > 125 rejected with 1002)
prove_fails "oversized control frame accepted" oversized_bypass \
  "assertion failed: oversized control frame was not rejected" "websocket.iyi" \
  's/if len7 > 125_u8$/if false/g'

# 4. Fragmented control frame accepted (must fail: control frame with FIN=0 rejected with 1002)
prove_fails "fragmented control frame accepted" frag_ctrl_bypass \
  "assertion failed: fragmented control frame was not rejected" "websocket.iyi" \
  's/unless fin$/if false/g'

# 5. Bad RSV bits accepted (must fail: RSV set without extension rejected with 1002)
prove_fails "bad RSV bits accepted" bad_rsv_bypass \
  "assertion failed: bad RSV frame was not rejected" "websocket.iyi" \
  's/return WebSocketError.new(CLOSE_PROTOCOL_ERROR, "RSV bits set without negotiated extension")/# bypass RSV/g'

# 6. Incremental UTF-8 validation bypassed (must fail: invalid UTF-8 in split frame rejected with 1007)
prove_fails "invalid UTF-8 in split text frame accepted" utf8_bypass \
  "assertion failed: invalid UTF-8 in split text frame was not rejected" "websocket.iyi" \
  's/unless @utf8_validator.update(frame.payload)$/if false/g'

# 7. Invalid close code accepted (must fail: code 1005 rejected with 1002)
prove_fails "forbidden close code 1005 accepted" close_code_bypass \
  "assertion failed: forbidden code 1005 is invalid" "websocket.iyi" \
  's/code == 1005 || //g'

# 8. Control frame with RSV1 accepted when deflate enabled (Finding 1)
prove_fails "control frame with RSV1 accepted" ctrl_rsv1_bypass \
  "assertion failed: control frame with RSV1 was not rejected" "websocket.iyi" \
  's/opcode >= 0x8_u8 && rsv1/false/g'

# 9. Continuation frame with RSV1 accepted when deflate enabled (Finding 2)
prove_fails "continuation frame with RSV1 accepted" cont_rsv1_bypass \
  "assertion failed: continuation frame with RSV1 was not rejected" "websocket.iyi" \
  's/if frame.rsv1$/if false/g'

# 10. Decompression bomb accepted without size check (Finding 4)
prove_fails "decompression bomb accepted without size check" decomp_bomb_bypass \
  "assertion failed: decompression bomb was not rejected" "websocket.iyi" \
  's/Inflate.decompress(decomp_input, @max_message_size)/Inflate.decompress(decomp_input, -1_i64)/'
# 11. Missing Host header accepted during handshake (Finding 7)
prove_fails "missing Host header accepted" host_header_bypass \
  "assertion failed: missing Host header was not rejected" "websocket.iyi" \
  's/if host\.nil[?] || host\.empty[?]$/if false/g'

# 12. Data frame permitted after close sent (Finding 12)
prove_fails "data frame permitted after close sent" post_close_bypass \
  "assertion failed: data frame rejected after close initiated" "websocket.iyi" \
  's/@close_sent && frame.opcode != OP_CLOSE && frame.opcode != OP_PONG/false/g'

# 13. Removal of negotiated client_no_context_takeover parameter fails public connect/upgrade path
prove_fails "server omitted client_no_context_takeover parameter rejected" no_ctx_takeover_bypass \
  "client failed to verify server deflate response: Server omitted client_no_context_takeover parameter" "websocket.iyi" \
  's/client_no_context_takeover; //'
if [ "$status" -eq 0 ]; then
  echo "WebSocket standard library: RFC 6455 handshake, base64, framing, client/server,"
  echo "incremental UTF-8 validation, control frame interleaving, permessage-deflate,"
  echo "and live socket all pass plain and optimised, and each check is proven to fail"
  echo "when its mechanism is broken."
else
  echo "WebSocket standard library: something above failed."
fi
exit "$status"
