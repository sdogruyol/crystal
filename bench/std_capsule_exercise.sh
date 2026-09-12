#!/usr/bin/env bash
# HTTP Datagrams, Capsule Protocol, and WebTransport session exercise driver.
# Runs the capsule exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/capsule.iyi
# and std/webtransport.iyi.
#
#     bash bench/std_capsule_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# QUIC varint encoding, boundary values, HTTP datagram quarter stream IDs,
# capsule length overrun detection, extensibility skipping of unknown capsule types,
# WebTransport bidi stream framing, and session close code integrity.
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
  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_capsule_exercise.iyi" \
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

echo "== the capsule and webtransport exercise, plain build"
run_case "plain" capsule-plain
if ! grep -q "all std/capsule checks passed" "$WORK/capsule-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every capsule and webtransport section reported"
for phrase in \
  "rfc 9000 appendix a:" \
  "boundary values:" \
  "varint errors:" \
  "http datagrams:" \
  "capsule framing:" \
  "capsule extensibility:" \
  "extended connect:" \
  "webtransport stream framing:" \
  "webtransport datagrams:" \
  "session state machine:" \
  "wave two transport interface:"; do
  if ! grep -q "$phrase" "$WORK/capsule-plain.out" 2>/dev/null; then
    echo "  MISSING: $phrase was not reported"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  varint test vectors, boundary values, datagrams, capsules, extensibility, extended connect, stream framing, and session state machine all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" capsule-release --release
if ! grep -q "all std/capsule checks passed" "$WORK/capsule-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when capsule and webtransport operations are broken"

prove_fails_capsule() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/capsule.iyi" > "$WORK/$dir/std/capsule.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/capsule.iyi" "$WORK/$dir/std/capsule.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  cp "$REPO/src/std/webtransport.iyi" "$WORK/$dir/std/webtransport.iyi"
  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_capsule_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched capsule library did not build"
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

prove_fails_wt() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  cp "$REPO/src/std/capsule.iyi" "$WORK/$dir/std/capsule.iyi"
  sed -e "$sed_script" "$REPO/src/std/webtransport.iyi" > "$WORK/$dir/std/webtransport.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/webtransport.iyi" "$WORK/$dir/std/webtransport.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_capsule_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched webtransport library did not build"
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

# 1. QUIC VarInt 1-byte encoding broken (adds 1 to value)
prove_fails_capsule "varint 1-byte encoding broken" no_v1 "rfc9000 app a: 37 in 1 byte hex" \
  's/buf\[0\] = value\.to_u8/buf[0] = (value + 1_u64).to_u8/'

# 2. QUIC VarInt 2-byte prefix broken (clears prefix bit)
prove_fails_capsule "varint 2-byte prefix broken" no_v2 "rfc9000 app a: 37 in 2 byte hex" \
  's/0x40_u8/0x00_u8/'

# 3. QUIC VarInt boundary size broken (encodes 64 in 1 byte instead of 2)
prove_fails_capsule "varint boundary check broken" no_bound "boundary 64 size" \
  's/MAX_1BYTE *= *63_u64/MAX_1BYTE = 64_u64/'
# 4. HTTP Datagram quarter stream id calculation broken
prove_fails_capsule "datagram quarter stream id broken" no_qid "dgram stream 4 stream_id" \
  's/@quarter_stream_id \* 4_u64/@quarter_stream_id * 2_u64/'

# 5. Capsule length overrun check disabled
prove_fails_capsule "capsule overrun check broken" no_overrun "capsule: truncated payload not refused" \
  's/return nil if capsule_len_u64 > remaining\.to_u64/return {new(capsule_type, Bytes.new(0)), hdr_len}/'

# 6. Capsule extensibility broken (skipping unknown capsule types disabled)
prove_fails_capsule "capsule extensibility broken" no_ext "extensibility: expected 2 known capsules" \
  's/unless capsule\.unknown[?]/if true/'

# 7. WebTransport bidi stream type header broken
prove_fails_wt "webtransport bidi stream type broken" no_bidi "bidi wire prefix 0x4041" \
  's/STREAM_TYPE_BIDI = 0x41_u64/STREAM_TYPE_BIDI = 0x42_u64/'

# 8. WebTransport close capsule error code broken
prove_fails_wt "close session capsule error code broken" no_close "peer session code" \
  's/new(code, reason_str)/new(code + 1_u64, reason_str)/'
echo
if [ "$status" -eq 0 ]; then
  echo "all capsule and webtransport tests and failure proofs passed"
else
  echo "capsule and webtransport tests failed"
fi
exit "$status"
