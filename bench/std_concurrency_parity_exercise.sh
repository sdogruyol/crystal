#!/usr/bin/env bash
# Concurrency Parity standard library exercise driver.
# Runs the concurrency parity exercise in plain and release mode, checks every section
# reported, proves the checks can fail by patching copies of std modules,
# and executes dedicated boundary failure probes against invalid concurrency operations.
#
#     bash bench/std_concurrency_parity_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# atomic bitwise operations, compare-and-set, atomic flags, fiber lifecycles,
# spawn execution, mutex try-locks, condition variable signalling, wait group barriers,
# channel capacity tracking, and channel empty state detection.
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

run_case() {
  local name="$1" out_prefix="$2"
  shift 2
  local build_flags=("$@")

  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       "$IYI" build "${build_flags[@]}" \
       -o "$WORK/$out_prefix" "$REPO/bench/std_concurrency_parity_exercise.iyi" \
       >"$WORK/$out_prefix.build.log" 2>&1; then
    echo "  $name: build failed"
    cat "$WORK/$out_prefix.build.log"
    status=1
    return
  fi

  if ! "$WORK/$out_prefix" >"$WORK/$out_prefix.out" 2>&1; then
    echo "  $name: runtime failure"
    cat "$WORK/$out_prefix.out"
    status=1
    return
  fi
}

echo "== the concurrency parity exercise, plain build"
run_case "plain" conc-plain
if ! grep -q "all std/concurrency_parity checks passed" "$WORK/conc-plain.out" 2>/dev/null; then
  echo "  exercise did not report final pass marker"
  status=1
fi

echo
echo "== every concurrency parity section reported"
for phrase in \
  "atomic primitives:" \
  "atomic flag & orderings:" \
  "fiber operations:" \
  "concurrent spawn & sleep:" \
  "sync mutex & condition variable:" \
  "sync rwlock, exclusive & shared:" \
  "wait group barrier:" \
  "channel rendezvous & buffered:" \
  "channel iteration & select actions:" \
  "concurrency errors & boundaries:" \
  "platform gates & memory consistency:"; do
  if ! grep -qi "$phrase" "$WORK/conc-plain.out" 2>/dev/null; then
    echo "  missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  atomic, fiber, concurrent, sync, mutex, wait group, channel, and platform gates all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" conc-release --release
if ! grep -q "all std/concurrency_parity checks passed" "$WORK/conc-release.out" 2>/dev/null; then
  echo "  release build did not report final pass marker"
  status=1
fi

echo
echo "== proving the checks can fail when concurrency operations are broken"

prove_fails_module() {
  local mod="$1" label="$2" dir="$3" phrase="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/$mod.iyi" > "$WORK/$dir/std/$mod.iyi"
  if cmp -s "$REPO/src/std/$mod.iyi" "$WORK/$dir/std/$mod.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  # Copy sibling modules
  for sibling in atomic fiber concurrent sync mutex wait_group channel; do
    if [ "$sibling" != "$mod" ]; then
      cp "$REPO/src/std/$sibling.iyi" "$WORK/$dir/std/$sibling.iyi"
    fi
  done

  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_concurrency_parity_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched module did not build"
    cat "$WORK/$dir/build.log"
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
    cat "$WORK/$dir/out"
    status=1
    return
  fi
  printf '  %s: exits %s at "%s"\n' "$label" "$exit_code" \
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed 's/^iyi: panic: //')"
}

# 1. std/atomic: bitwise OR broken (dispatches :and instead of :or)
prove_fails_module "atomic" "atomic bitwise_or broken" no_or "atomic i32 bitwise_or" \
  's/IyiAtomic\.rmw(:or/IyiAtomic.rmw(:and/'

# 2. std/atomic: compare_and_set broken (inverts boolean result)
prove_fails_module "atomic" "atomic compare_and_set broken" no_cas "atomic cas success ok" \
  's/{cast_out(res\[0\]), res\[1\]}/{cast_out(res[0]), !res[1]}/'

# 3. std/atomic: Atomic::Flag test_and_set broken
prove_fails_module "atomic" "atomic flag test_and_set broken" no_flag "flag initial test_and_set" \
  's/@value\.swap(true) == false/@value.swap(true) == true/'

# 4. std/fiber: dead? query broken (checks wrong state)
prove_fails_module "fiber" "fiber dead? query broken" no_dead "worker dead after execution" \
  's/@state == 6/@state == 0/'

# 5. std/concurrent: spawn execution broken (does not enqueue fiber)
prove_fails_module "concurrent" "concurrent spawn broken" no_spawn "spawn block executed" \
  's/f\.enqueue/nil/'

# 6. std/sync: Mutex try_lock broken (always fails when available)
prove_fails_module "sync" "mutex try_lock broken" no_trylock "checked_m try_lock" \
  's/@owner\.nil?/false/'

# 7. std/sync: ConditionVariable signal broken (does not wake waiter)
prove_fails_module "sync" "condition variable signal broken" no_signal "condition variable signal woke waiter" \
  's/waiter = @waiters\.shift?/waiter = nil/'

# 8. std/wait_group: WaitGroup done? broken
prove_fails_module "wait_group" "wait group done? broken" no_wg "wg not done initially" \
  's/@counter\.get == 0/@counter.get != 0/'

# 9. std/channel: capacity tracking broken
prove_fails_module "channel" "channel capacity tracking broken" no_cap "channel capacity 2" \
  's/def capacity : Int32/def capacity : Int32; return @capacity + 1;/'

# 10. std/channel: empty? query broken
prove_fails_module "channel" "channel empty? query broken" no_empty "channel initially empty" \
  's/def empty? : Bool/def empty? : Bool; return false;/'

echo
echo "== dedicated boundary failure probes (invalid concurrency shapes)"

prove_panic() {
  local label="$1" code="$2" expected_phrase="$3"
  local probe_src="$WORK/probe_${label}.iyi"
  local probe_bin="$WORK/probe_${label}"
  local probe_log="$WORK/probe_${label}.log"

  cat <<EOF > "$probe_src"
$code
EOF

  if ! PATH=/opt/homebrew/bin:/usr/bin:/bin LIBRARY_PATH=/opt/homebrew/opt/bdw-gc/lib \
       "$IYI" build -o "$probe_bin" "$probe_src" >"$probe_log" 2>&1; then
    echo "  $label: probe build failed"
    cat "$probe_log"
    status=1
    return
  fi

  "$probe_bin" >"$probe_log" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: probe unexpectedly passed (expected exit non-zero)"
    status=1
    return
  fi

  if ! grep -qi "$expected_phrase" "$probe_log"; then
    echo "  $label: panic message missing '$expected_phrase'"
    cat "$probe_log"
    status=1
    return
  fi

  printf '  %s: rejects with "%s"\n' "$label" \
    "$(grep -i -m1 "$expected_phrase" "$probe_log" | sed 's/^iyi: panic: //')"
}

prove_panic "sleep_negative" \
  'import std/concurrent
using std/concurrent::{sleep}
sleep(-1.0)' \
  "Sleep seconds must be non-negative"

prove_panic "waitgroup_negative" \
  'import std/wait_group
using std/wait_group::{WaitGroup}
wg = WaitGroup.new(0)
wg.add(-1)' \
  "Negative WaitGroup counter"

prove_panic "channel_negative_capacity" \
  'import std/channel
using std/channel::{Channel}
ch = Channel(Int32).new(-1)' \
  "a channel's capacity is not negative"

echo
if [ "$status" -eq 0 ]; then
  echo "concurrency parity exercise: ALL CHECKS PASSED (plain, release, 10 mutations, 3 boundary panics)"
else
  echo "concurrency parity exercise: FAILED"
fi
exit "$status"
