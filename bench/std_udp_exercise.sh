#!/usr/bin/env bash
# Datagram sockets: UDP standard library exercise driver.
# Runs the UDP exercise in plain and release mode, checks every section
# reported, verifies timeout/would_block diagnostics, and proves the checks
# can fail by patching copies of std/udp.iyi.
#
#     bash bench/std_udp_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# payload transmission, local port retrieval, IPv6 addressing, datagram
# truncation, receive timeout, and poller readiness.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_udp_exercise.iyi" \
       >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    tail -n 15 "$WORK/$name.build.log"
    status=1
    return 1
  fi
  if ! "$WORK/$name" >"$WORK/$name.out" 2>&1; then
    echo "  $label: run failed"
    cat "$WORK/$name.out"
    status=1
    return 1
  fi
  return 0
}

echo "== the UDP exercise, plain build"
run_case "plain" udp-plain
if ! grep -q "std_udp_exercise: all checks passed" "$WORK/udp-plain.out" 2>/dev/null; then
  echo "  plain build did not report completion"
  status=1
else
  echo "  plain build: completed successfully"
fi

echo
echo "== every UDP section reported"
for phrase in round_trip datagram_struct buffer_sizes non_blocking timeout_mode poll_read truncation closed_port_send connected_mode ipv6_round_trip; do
  if ! grep -q "$phrase: ok" "$WORK/udp-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  round_trip, datagram_struct, buffer_sizes, non_blocking, timeout_mode, poll_read, truncation, closed_port_send, connected_mode, and ipv6_round_trip all reported ok"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" udp-release --release
if ! grep -q "std_udp_exercise: all checks passed" "$WORK/udp-release.out" 2>/dev/null; then
  echo "  release build did not report completion"
  status=1
else
  echo "  release build: completed successfully"
fi

echo
echo "== timeout and non-blocking subcommands exit non-zero with diagnostic"
"$WORK/udp-plain" timeout >"$WORK/timeout.out" 2>&1
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
  echo "  timeout subcommand exited zero; expected non-zero"
  status=1
elif ! grep -q "receive timed out" "$WORK/timeout.out"; then
  echo "  timeout subcommand did not report 'receive timed out'"
  cat "$WORK/timeout.out"
  status=1
else
  printf '  timeout diagnostic: exits %s at "%s"\n' "$exit_code" \
    "$(grep -m1 "receive timed out" "$WORK/timeout.out" | sed 's/^iyi: panic: //')"
fi

"$WORK/udp-plain" would_block >"$WORK/would_block.out" 2>&1
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
  echo "  would_block subcommand exited zero; expected non-zero"
  status=1
elif ! grep -q "receive would block" "$WORK/would_block.out"; then
  echo "  would_block subcommand did not report 'receive would block'"
  cat "$WORK/would_block.out"
  status=1
else
  printf '  would_block diagnostic: exits %s at "%s"\n' "$exit_code" \
    "$(grep -m1 "receive would block" "$WORK/would_block.out" | sed 's/^iyi: panic: //')"
fi

echo
echo "== proving the checks can fail when UDP operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/udp.iyi" > "$WORK/$dir/std/udp.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/udp.iyi" "$WORK/$dir/std/udp.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_udp_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched UDP library did not build"
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
  if ! grep -a -q "$phrase" "$WORK/$dir/out"; then
    echo "  $label: failed, but not at expected check (expected '$phrase')"
    sed -n '$p' "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -a -m1 "$phrase" "$WORK/$dir/out" | tr -d '\0' | sed 's/^iyi: panic: //')"
}

# 1. Broken payload reception
prove_fails "payload reception broken" bad_payload "round_trip: payload mismatch" \
  's/bytes\.to_unsafe\.copy_from(buffer, count\.to_i32)/bytes.to_unsafe[0] = 63_u8/'

# 2. Broken local port (answers 0 instead of assigned ephemeral port)
prove_fails "local port returns 0" bad_port "round_trip: server port must be positive" \
  's/(addr\[2\]\.to_i32 << 8) | addr\[3\]\.to_i32/0/'

# 3. Broken IPv6 address formatting
prove_fails "ipv6 address formatting broken" bad_v6 "ipv6_round_trip:" \
  's/"::1"/"::99"/'

# 4. Broken datagram truncation (altering received slice size)
prove_fails "datagram truncation broken" bad_trunc "truncation: size mismatch" \
  's/count = UdpSocket\.__sys_recvfrom(@fd, buffer, max_bytes\.to_u64/if max_bytes == 10; max_bytes = 1; end; count = UdpSocket.__sys_recvfrom(@fd, buffer, max_bytes.to_u64/'
# 5. Broken non-blocking receive (fails to recognize EAGAIN and raises)
prove_fails "non-blocking receive broken" bad_nonblock "cannot receive from UDP socket" \
  's/if UdpSocket\.__is_eagain(count)/if false/'
# 6. Broken receive timeout configuration (timeout syscall rejected)
prove_fails "receive timeout broken" bad_timeout "cannot set read timeout" \
  's/res = UdpSocket\.__sys_set_timeout(@fd, SO_RCVTIMEO, ms)/res = -1/'

# 7. Broken poll_read (returns false when packet is waiting)
prove_fails "poll_read broken" bad_poll "poll_read: expected true with packet waiting" \
  's/UdpSocket\.__sys_poll_read(@fd, timeout_ms)/false/'

echo
if [ "$status" -eq 0 ]; then
  echo "Datagram sockets standard library: IPv4 loopback round-trip, Datagram struct,"
  echo "buffer sizing, non-blocking receive, receive timeouts, poller readiness,"
  echo "datagram truncation, closed port sends, connected mode, and IPv6 loopback"
  echo "all pass plain and optimised, and each check is proven to fail when broken."
else
  echo "Datagram sockets standard library: something above failed."
fi
exit "$status"
