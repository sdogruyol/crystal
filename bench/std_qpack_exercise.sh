#!/usr/bin/env bash
# QPACK standard library exercise driver (RFC 9204).
# Runs the QPACK exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/qpack.iyi.
#
#     bash bench/std_qpack_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
# 1. Static table lookup correctness
# 2. Dynamic table size-based FIFO eviction
# 3. Blocked stream limit enforcement (SETTINGS_QPACK_BLOCKED_STREAMS)
# 4. Out-of-order stream unblocking and resolution
# 5. Decompression bomb protection (max header list size bound)
#
# Exits non-zero if any check fails.

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

SETUP_INCLUDE() {
  local target_dir="$1"
  mkdir -p "$target_dir/std"
  ln -sf "$REPO/src/std/slice.iyi" "$target_dir/std/slice.iyi"
  ln -sf "$REPO/src/std/text.iyi" "$target_dir/std/text.iyi"
  ln -sf "$REPO/src/std/traits.iyi" "$target_dir/std/traits.iyi"
  ln -sf "$REPO/src/std/enumerable.iyi" "$target_dir/std/enumerable.iyi"

  # Link or fetch hpack.iyi from sibling worktree or origin ref
  if [ -f "$REPO/../iyi-hpack/src/std/hpack.iyi" ]; then
    ln -sf "$REPO/../iyi-hpack/src/std/hpack.iyi" "$target_dir/std/hpack.iyi"
  elif git -C "$REPO" rev-parse --verify origin/std/hpack >/dev/null 2>&1; then
    git -C "$REPO" show origin/std/hpack:src/std/hpack.iyi > "$target_dir/std/hpack.iyi"
  elif [ -f "$REPO/src/std/hpack.iyi" ]; then
    ln -sf "$REPO/src/std/hpack.iyi" "$target_dir/std/hpack.iyi"
  else
    echo "ERROR: std/hpack.iyi not found in sibling worktree, origin ref, or repo" >&2
    exit 1
  fi
}

DEFAULT_INCLUDE="$WORK/default_include"
SETUP_INCLUDE "$DEFAULT_INCLUDE"
ln -sf "$REPO/src/std/qpack.iyi" "$DEFAULT_INCLUDE/std/qpack.iyi"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! IYI_PATH="$DEFAULT_INCLUDE:$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_qpack_exercise.iyi" \
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

echo "== the qpack exercise, plain build"
run_case "plain" qpack-plain
if ! grep -q "all std/qpack checks passed" "$WORK/qpack-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every qpack section reported"
for phrase in "static table:" "dynamic table:" "appendix b:" "out-of-order delivery:" "blocked stream limit:" "security and liveness:"; do
  grep -q "$phrase" "$WORK/qpack-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  static table, dynamic table, appendix b, out-of-order delivery, blocked stream limit, and security/liveness all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" qpack-release --release
if ! grep -q "all std/qpack checks passed" "$WORK/qpack-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when qpack operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  local inc_dir="$WORK/$dir/include"
  SETUP_INCLUDE "$inc_dir"
  sed -e "$sed_script" "$REPO/src/std/qpack.iyi" > "$inc_dir/std/qpack.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/qpack.iyi" "$inc_dir/std/qpack.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$inc_dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_qpack_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched qpack library did not build"
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

# 1. Static table entry broken
prove_fails "static table entry broken" no_static "static: index 1 value" \
  's/TableEntry.new(":path", "\/")/TableEntry.new(":path", "\/broken")/'

# 2. Dynamic table eviction broken
prove_fails "dynamic table eviction broken" no_evict "dynamic: eviction size" \
  's/while (@size + entry_sz) > @capacity/while false/'

# 3. Out-of-order unblocking broken
prove_fails "out-of-order unblocking broken" no_unblock "ooo: unblocked count" \
  's/if @dynamic_table.insert_count >= st.req_insert_count/if false/'

# 4. Blocked stream limit enforcement broken
prove_fails "blocked stream limit broken" no_limit "limit: stream 12 should be rejected" \
  's/if @blocked_streams.size + 1 > @max_blocked_streams/if false/'

# 5. Decompression bomb defense broken
prove_fails "decompression bomb defense broken" no_bomb "sec: decompression bomb must be rejected" \
  's/if total_size > @max_header_list_size/if false/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/qpack exercise driver checks and failure proofs passed"
fi
exit "$status"
