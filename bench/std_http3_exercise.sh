#!/usr/bin/env bash
# HTTP/3 standard library exercise driver.
# Runs the HTTP/3 exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/http3.iyi.
#
#     bash bench/std_http3_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. Settings dictionary serialization (corrupted settings encoding detected)
#   2. HTTP/3 frame type tagging (corrupted frame type detected)
#   3. Unidirectional control stream type identification (corrupted control stream type detected)
#   4. QPACK field decoding integration (corrupted header field decoding detected)
#   5. Quarter Stream ID mapping for datagrams (corrupted division detected)
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
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_http3_exercise.iyi" \
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

echo "== the http3 exercise, plain build"
run_case "plain" http3-plain
if ! grep -q "all std/http3 checks passed" "$WORK/http3-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every http3 section reported"
for phrase in "constants:" "settings:" "frames:" "control-stream:" "request-response:" "extended-connect:" "datagrams:" "control-stream-audit:" "forbidden-frames:" "settings-audit:"; do
  grep -q "$phrase" "$WORK/http3-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  constants, settings, frames, control-stream, request-response, extended-connect, datagrams, control-stream-audit, forbidden-frames, and settings-audit all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" http3-release --release
if ! grep -q "all std/http3 checks passed" "$WORK/http3-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when http3 mechanisms are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy sibling files so all imports are reachable
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/"
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
       -o "$WORK/$dir/program" "$REPO/bench/std_http3_exercise.iyi" \
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
  if [ "$exit_code" -ne 1 ]; then
    echo "  $label: expected exit 1, got $exit_code"
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

# 1. Settings dictionary serialization corrupted
prove_fails "settings table capacity corrupted" settings_corrupt \
  "settings table cap" "http3.iyi" \
  's/val_b = VarInt.encode(entry.value)/val_b = VarInt.encode(0_u64)/'

# 2. DATA frame type corrupted
prove_fails "data frame type corrupted" data_corrupt \
  "frame data type" "http3.iyi" \
  's/pub DATA *= *0x00_u64/pub DATA = 0x99_u64/'

# 3. Control stream type corrupted
prove_fails "control stream type corrupted" ctrl_corrupt \
  "control stream type" "http3.iyi" \
  's/pub CONTROL *= *0x00_u64/pub CONTROL = 0x09_u64/'

# 4. QPACK field section decoding corrupted
prove_fails "qpack decoding corrupted" qpack_corrupt \
  "method decoded" "http3.iyi" \
  's/res.as(Array(FieldLine))/[] of FieldLine/'

# 5. Quarter Stream ID mapping corrupted
prove_fails "quarter stream id mapping corrupted" dgram_corrupt \
  "stream id mapping" "http3.iyi" \
  's/quarter_stream_id \* 4_u64/quarter_stream_id \* 2_u64/'

# 6. Duplicate SETTINGS rejection on control stream
prove_fails "duplicate SETTINGS accepted" dup_settings_fail \
  "duplicate SETTINGS not rejected" "http3.iyi" \
  's/return H3Error::FRAME_UNEXPECTED/return H3Error::NO_ERROR/'

# 7. Forbidden frame rejection on request stream
prove_fails "forbidden frame accepted" forbid_frame_fail \
  "forbidden frame not rejected" "http3.iyi" \
  's/return {fields, Bytes.empty, H3Error::FRAME_UNEXPECTED}/return {fields, Bytes.empty, H3Error::NO_ERROR}/'

# 8. Reserved HTTP/2 setting accepted
prove_fails "reserved H2 setting accepted" reserved_setting_fail \
  "reserved H2 setting not rejected" "http3.iyi" \
  's/id == 0x02_u64/false/'
echo
if [ "$status" -eq 0 ]; then
  echo "HTTP/3 standard library: stream types, frame codecs, settings dictionary,"
  echo "unidirectional control streams, QPACK integration, request-response framing,"
  echo "Extended CONNECT, and datagrams all pass plain and release, and each check is"
  echo "proven to fail when its mechanism is broken."
else
  echo "HTTP/3 standard library: something above failed."
fi
exit "$status"
