#!/usr/bin/env bash
# Advanced Network Parity standard library exercise driver.
# Runs the network advanced parity exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std modules.
#
#     bash bench/std_network_advanced_parity_exercise.sh
#
# Proves RFC parity, bounded state, and security failure proofs across:
#   1. HPACK (RFC 7541)
#   2. QPACK (RFC 9204)
#   3. HTTP/2 (RFC 9113)
#   4. HTTP/3 (RFC 9114)
#   5. QUIC (RFC 9000, 9001, 9002)
#   6. WebSocket (RFC 6455, full public surface)
#   7. WebTransport (draft-ietf-webtrans-http3)
#   8. Capsule & HTTP Datagrams (RFC 9297)
#   9. Real TCP Loopback: WebSocket Handshake & Echo
#  10. Real TCP Loopback: HTTP/2 & HPACK Request & Response
#  11. Real UDP Loopback: QUIC Handshake, 1-RTT & Stream Transfer
#  12. Real UDP Loopback: HTTP/3, QPACK, WebTransport & Capsules
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
  if ! IYI_PATH="$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_network_advanced_parity_exercise.iyi" \
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

echo "== the network advanced parity exercise, plain build"
run_case "plain" net-adv-plain
if ! grep -q "all std/network_advanced_parity checks passed" "$WORK/net-adv-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every network advanced parity section reported"
for phrase in \
  "== Section 1: HPACK (RFC 7541)" \
  "== Section 2: QPACK (RFC 9204)" \
  "== Section 3: HTTP/2 (RFC 9113)" \
  "== Section 4: HTTP/3 (RFC 9114)" \
  "== Section 5: QUIC (RFC 9000, 9001, 9002)" \
  "== Section 6: WebSocket (RFC 6455, full public surface)" \
  "== Section 7: WebTransport (draft-ietf-webtrans-http3)" \
  "== Section 8: Capsule & HTTP Datagrams (RFC 9297)" \
  "== Section 9: Real TCP Loopback: WebSocket Handshake & Echo" \
  "== Section 10: Real TCP Loopback: HTTP/2 & HPACK Request & Response" \
  "== Section 11: Real UDP Loopback: QUIC Handshake, 1-RTT & Stream Transfer" \
  "== Section 12: Real UDP Loopback: HTTP/3, QPACK, WebTransport & Capsules"; do
  grep -F -q "$phrase" "$WORK/net-adv-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  all 12 network advanced parity sections successfully reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" net-adv-release --release
if ! grep -q "all std/network_advanced_parity checks passed" "$WORK/net-adv-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when network protocol mechanisms are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/"
  sed -e "$sed_script" "$REPO/src/std/$target_file" > "$WORK/$dir/std/$target_file"
  if cmp -s "$REPO/src/std/$target_file" "$WORK/$dir/std/$target_file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_network_advanced_parity_exercise.iyi" \
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

# 1. HPACK: integer encoding broken
prove_fails "hpack integer encoding broken" hpack_int \
  "c.1.2 encode 1337 with 5-bit prefix" "hpack.iyi" \
  's/prefix_byte | prefix_max\.to_u8/prefix_byte/'

# 2. HPACK: huffman decoding broken
prove_fails "hpack huffman decoding broken" hpack_huff \
  "c.4.1 huffman decode www.example.com" "hpack.iyi" \
  's/out_chars << sym\.to_u8/out_chars << (sym ^ 1)\.to_u8/'
# 3. QPACK: static table entry broken
prove_fails "qpack static table entry broken" qpack_static \
  "qpack static index 1 is :path /" "qpack.iyi" \
  's/TableEntry\.new(":path", "\/")/TableEntry.new(":path", "\/corrupted")/'

# 4. QPACK: dynamic table insertion broken
prove_fails "qpack dynamic table insertion broken" qpack_dynamic \
  "qpack dynamic table insert count" "qpack.iyi" \
  's/@insert_count = @insert_count + 1_i64/@insert_count = 0_i64/'

# 5. HTTP/2: preface verification broken
prove_fails "http2 preface verification broken" h2_preface \
  "client preface bytes size 24" "http2.iyi" \
  's/CLIENT_PREFACE_BYTES = Bytes\.new(24)/CLIENT_PREFACE_BYTES = Bytes.new(20)/'

# 6. HTTP/2: frame header serialization broken
prove_fails "http2 frame header serialization broken" h2_fh \
  "frame header length 9 bytes" "http2.iyi" \
  's/buf = \[\] of UInt8/buf = [0_u8]/'

# 7. HTTP/3: frame data type corrupted
prove_fails "http3 frame data type corrupted" h3_frame \
  "H3 DATA frame type 0x00" "http3.iyi" \
  's/DATA         = 0x00_u64/DATA         = 0x99_u64/'

# 8. HTTP/3: control stream type corrupted
prove_fails "http3 control stream type corrupted" h3_ctrl \
  "H3 control stream type 0x00" "http3.iyi" \
  's/CONTROL           = 0x00_u64/CONTROL           = 0x99_u64/'

# 9. QUIC: loopback UDP send_to dropped
prove_fails "quic loopback UDP send_to dropped" quic_drop \
  "handshake keys missing" "quic.iyi" \
  's/@socket\.send_to(data, host, port)/0 # drop/'
# 10. QUIC: CertificateVerify downgraded
prove_fails "quic CertificateVerify downgraded" cv_downgrade \
  "TLS 1.3 requires rsa_pss_rsae_sha256 CertificateVerify" "quic.iyi" \
  's/cv_msg\[4\] = 0x08_u8; cv_msg\[5\] = 0x04_u8/cv_msg[4] = 0x04_u8; cv_msg[5] = 0x01_u8/'

# 11. WebSocket: handshake accept calculation corrupted
prove_fails "websocket accept vector corrupted" ws_accept \
  "RFC 6455 1.3 Sec-WebSocket-Accept" "websocket.iyi" \
  's/258EAFA5-E914-47DA-95CA-C5AB0DC85B11/00000000-0000-0000-0000-000000000000/'

# 12. WebSocket: unmasked client frame accepted
prove_fails "websocket unmasked client frame accepted" ws_unmasked \
  "unmasked client frame was not rejected" "websocket.iyi" \
  's/unless masked$/if false/g'

# 13. WebTransport: bidi stream type broken
prove_fails "webtransport bidi stream type broken" wt_bidi \
  "stream type bidi 0x41" "webtransport.iyi" \
  's/STREAM_TYPE_BIDI = 0x41_u64/STREAM_TYPE_BIDI = 0x99_u64/'

# 14. Capsule: varint boundary check broken
prove_fails "capsule varint boundary check broken" cap_bound \
  "boundary 64 size" "capsule.iyi" \
  's/MAX_1BYTE *= *63_u64/MAX_1BYTE = 64_u64/'

# 15. Capsule: datagram quarter stream id broken
prove_fails "capsule datagram quarter stream id broken" cap_dgram \
  "dgram stream_id 8" "capsule.iyi" \
  's/@quarter_stream_id \* 4_u64/@quarter_stream_id * 2_u64/'

echo
if [ "$status" -eq 0 ]; then
  echo "Advanced Network Parity: HPACK, QPACK, HTTP/2, HTTP/3, QUIC, WebSocket,"
  echo "WebTransport, and Capsule public APIs and loopback socket proofs all pass plain"
  echo "and release, and each check is proven to fail when its mechanism is broken."
else
  echo "Advanced Network Parity: something above failed."
fi
exit "$status"
