#!/usr/bin/env bash
# HTTP/2 (RFC 9113) standard library exercise driver.
# Runs the HTTP/2 exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/http2.iyi.
#
#     bash bench/std_http2_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. Client connection preface verification bypassed
#   2. DATA on stream 0 check disabled (h2spec 6.1)
#   3. Stream ID monotonicity check disabled (h2spec 5.1.1)
#   4. Frame on closed stream check disabled (h2spec 5.1)
#   5. SETTINGS bad length check disabled (h2spec 6.5)
#   6. SETTINGS ACK non-zero length check disabled (h2spec 6.5)
#   7. WINDOW_UPDATE 0 increment check disabled (h2spec 6.9)
#   8. WINDOW_UPDATE overflow check disabled (h2spec 6.9.1)
#   9. CONTINUATION atomicity check disabled (h2spec 6.2/6.10)
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local label="$1" name="$2"; shift 2
  mkdir -p "$WORK/$name"
  # IYI_PATH is named here rather than inherited. Without it this build only
  # resolves the module for someone whose shell already exports the path, so
  # the gate passed for its author and was red for CI and for everyone else.
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" \
       -o "$WORK/$name/program" "$REPO/bench/std_http2_exercise.iyi" \
       >"$WORK/$name/build.log" 2>&1; then
    echo "  $label build: failed"
    sed -n '1,12p' "$WORK/$name/build.log"
    status=1
    return 1
  fi
  if ! "$WORK/$name/program" >"$WORK/$name/out" 2>&1; then
    echo "  $label run: failed"
    sed -n '1,15p' "$WORK/$name/out"
    status=1
    return 1
  fi
  cp "$WORK/$name/out" "$WORK/$name.out"
  echo "  $label: pass"
}

echo "== the http2 exercise, plain build"
run_case "plain" http2-plain
if ! grep -q "all std/http2 checks passed" "$WORK/http2-plain.out" 2>/dev/null; then
  echo "  plain exercise did not report all checks passed"
  status=1
fi

echo
echo "== every http2 section reported"
for phrase in \
  "section 1: connection preface & settings handshake" \
  "section 2: every frame type encoding and decoding" \
  "section 3: stream state machine transitions" \
  "section 4: multiplexing concurrent streams" \
  "section 5: continuation frames and atomic non-interleaved assembly" \
  "section 6: flow control with transfer larger than initial window" \
  "section 7: protocol error suite" \
  "section 8: remediation of 18 adversarial review findings"; do
  if ! grep -Fqi "$phrase" "$WORK/http2-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all 8 sections successfully reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" http2-release --release
if ! grep -q "all std/http2 checks passed" "$WORK/http2-release.out" 2>/dev/null; then
  echo "  release exercise did not report all checks passed"
  status=1
fi

echo
echo "== proving the checks can fail when http2 operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir"
  # Copy all standard library modules so imports are satisfied
  cp -r "$REPO/src/std" "$WORK/$dir/"
  sed -e "$sed_script" "$REPO/src/std/$target_file" > "$WORK/$dir/std/$target_file"

  # A patch that matches nothing leaves the library intact, and an intact
  # library passes. That reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift; this
  # catches it at the patch rather than at the conclusion.
  if cmp -s "$REPO/src/std/$target_file" "$WORK/$dir/std/$target_file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_http2_exercise.iyi" \
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

# 1. Connection preface verification bypassed
prove_fails "preface verification bypassed" no_preface \
  "assertion failed: h2spec 3.5: invalid client preface rejected" "http2.iyi" \
  's/if !preface_ok/if false/'

# 2. DATA on stream 0 check disabled
prove_fails "data on stream 0 check disabled" no_stream0_data \
  "assertion failed: h2spec 6.1 code is PROTOCOL_ERROR" "http2.iyi" \
  '/RFC 9113 6.1: DATA frames MUST be associated with a stream/,/return Http2Error/s/if header.stream_id == 0/if false/'

# 3. Stream ID monotonicity check disabled in process_headers
prove_fails "stream monotonicity check disabled" no_monotonicity \
  "assertion failed: h2spec 5.1.1: decreasing stream ID rejected" "http2.iyi" \
  '/RFC 9113 5.1.1: stream identifier must be strictly greater than previous/,/return Http2Error/s/if header.stream_id <= @last_peer_stream_id/if false/'

# 4. Frame on closed stream check disabled
prove_fails "frame on closed stream check disabled" no_closed_check \
  "assertion failed: h2spec 5.1 message is closed stream" "http2.iyi" \
  '/process_data/,/Flow control accounting/s/if stream.state == StreamState::Closed || stream.state == StreamState::HalfClosedRemote/if false/'
# 5. SETTINGS bad length check disabled
prove_fails "settings bad length check disabled" no_settings_len \
  "assertion failed: h2spec 6.5: SETTINGS length not multiple of 6 rejected" "http2.iyi" \
  's/if header.length % 6 != 0/if false/'

# 6. SETTINGS ACK non-zero length check disabled
prove_fails "settings ack non-zero length check disabled" no_settings_ack_len \
  "assertion failed: h2spec 6.5: SETTINGS ACK with non-zero length rejected" "http2.iyi" \
  '/if header\.ack[?]/,/end/s/if header.length != 0/if false/'

# 7. WINDOW_UPDATE 0 increment check disabled
prove_fails "window update 0 increment check disabled" no_zero_inc \
  "assertion failed: h2spec 6.9: WINDOW_UPDATE increment 0 rejected" "http2.iyi" \
  's/if inc == 0_i64/if false/'

# 8. WINDOW_UPDATE overflow check disabled
prove_fails "window update overflow check disabled" no_overflow_check \
  "assertion failed: h2spec 6.9.1: WINDOW_UPDATE window overflow rejected" "http2.iyi" \
  's/if @connection_send_window + inc > MAX_WINDOW_SIZE/if false/'

# 9. CONTINUATION atomicity check disabled
prove_fails "continuation atomicity check disabled" no_continuation_check \
  "assertion failed: h2spec 6.2\/6.10 code is PROTOCOL_ERROR" "http2.iyi" \
  's/if header.type != FrameType::CONTINUATION/if false/'

# 10. Max concurrent streams enforcement disabled
prove_fails "max concurrent streams disabled" no_max_streams \
  "assertion failed: finding 7: max concurrent streams limit enforced" "http2.iyi" \
  's/if active_stream_count >= @local_settings.max_concurrent_streams/if false/'

# 11. Client SETTINGS_ENABLE_PUSH rejection disabled
prove_fails "client push rejection disabled" no_push_rej \
  "assertion failed: finding 11: client rejects server SETTINGS_ENABLE_PUSH" "http2.iyi" \
  '/Finding 11: Client must reject SETTINGS_ENABLE_PUSH from server/,/return Http2Error/s/if @role == Role::Client/if false/'

# 12. PUSH_PROMISE on idle stream check disabled
prove_fails "push promise idle stream check disabled" no_pp_idle \
  "assertion failed: finding 15: PUSH_PROMISE on idle stream rejected" "http2.iyi" \
  '/Finding 15: Associated stream must be Open or HalfClosedLocal/,/return Http2Error/s/if assoc_stream\.nil[?] || (assoc_stream.state != StreamState::Open && assoc_stream.state != StreamState::HalfClosedLocal)/if false/'
# 13. PUSH_PROMISE promised stream ID monotonicity check disabled
prove_fails "push promise monotonicity check disabled" no_pp_mono \
  "assertion failed: finding 16: decreasing promised stream ID rejected" "http2.iyi" \
  's/if promised_id <= @last_peer_stream_id/if false/'

# 14. GOAWAY received last_stream_id assignment removed
prove_fails "goaway received last_stream_id assignment removed" no_gw_last_id \
  "assertion failed: finding 18: newly initiated stream 3 > received GOAWAY last_stream_id rejected" "http2.iyi" \
  's/@goaway_received_last_stream_id = last_id//'
echo
if [ "$status" -eq 0 ]; then
  echo "all std/http2 failure proofs passed"
else
  echo "std/http2 exercise driver encountered failures"
fi
exit "$status"
