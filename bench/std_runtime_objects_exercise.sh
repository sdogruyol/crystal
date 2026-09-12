#!/usr/bin/env bash
# Runtime objects and error standard library exercise driver.
# Runs the runtime objects exercise in plain and release mode, checks every
# section reported, and proves the checks can fail by patching copies of the
# libraries via IYI_PATH.
#
#     bash bench/std_runtime_objects_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   * Box value and reference round-trip
#   * WeakRef live dereference
#   * ReferenceStorage in-place construction and equality
#   * Errno message lookup and code values
#   * WasiError to_errno mapping and messages
#   * WinError message lookup and error values
#   * SystemError message formatting and error wrapping
#   * Kernel p return value forwarding
#   * Exception hierarchy, callstack, and cause chaining
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_runtime_objects_exercise.iyi" \
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

echo "== the runtime objects exercise, plain build"
run_case "plain" ro-plain
if ! grep -q "all std/runtime_objects checks passed" "$WORK/ro-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every runtime objects section reported"
for phrase in "std/box:" "std/weak_ref:" "std/reference_storage:" "std/errno:" "std/wasi_error:" "std/winerror:" "std/system_error:" "std/gc:" "std/kernel:" "std/exception:" "std/runtime_objects:"; do
  if ! grep -q "$phrase" "$WORK/ro-plain.out" 2>/dev/null; then
    echo "  MISSING: section '$phrase' was not reported"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  All 11 runtime object and error sections reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" ro-release --release
if ! grep -q "all std/runtime_objects checks passed" "$WORK/ro-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when runtime object operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy unmodified siblings so include resolves everything
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/" 2>/dev/null || true
  # Patch the targeted file
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_runtime_objects_exercise.iyi" \
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
    "$(grep -m1 "$phrase" "$WORK/$dir/out" | sed -e 's/^FAIL: //' -e 's/^iyi: panic: //')"
}
# 1. Box value unboxing broken
prove_fails "box value unbox broken" no_box_val "Unboxing null pointer" "box.iyi" \
  's/pointer\.address == 0/true/'

# 2. WeakRef live dereference broken
prove_fails "weak_ref dereference broken" no_weak_deref "weak_ref: unexpectedly nil" "weak_ref.iyi" \
  's/@target\.as(T?)/nil/'

# 3. ReferenceStorage equality broken
prove_fails "reference_storage equality broken" no_rs_eq "ref_storage: equality mismatch" "reference_storage.iyi" \
  's/def ==(other : ReferenceStorage(T)) : Bool/def ==(other : ReferenceStorage(T)) : Bool; return false;/'

# 4. Errno message lookup broken
prove_fails "errno message lookup broken" no_errno_msg "errno: ENOENT message" "errno.iyi" \
  's/"No such file or directory"/"Wrong file msg"/'

# 5. WasiError translation broken
prove_fails "wasi_error translation broken" no_wasi_trans "wasi: to_errno ENOENT" "wasi_error.iyi" \
  's/when ENOENT[ ]*then Errno::ENOENT/when ENOENT then Errno::EPERM/'

# 6. WinError message lookup broken
prove_fails "winerror message lookup broken" no_win_msg "winerror: file not found message" "winerror.iyi" \
  's/"The system cannot find the file specified\."/"Wrong file msg"/'

# 7. SystemError message formatting broken
prove_fails "system_error formatting broken" no_sys_fmt "system_error: message formatting" "system_error.iyi" \
  's/"#{message}: #{desc}"/desc\.to_s/'

# 8. Kernel sleep timing broken
prove_fails "kernel sleep timing broken" no_kern_sleep "kernel: sleep too short" "kernel.iyi" \
  's/target_ns = __iyi_monotonic_ns/target_ns = 0_i64/'

# 9. Exception cause chaining broken
prove_fails "exception cause chaining broken" no_exc_cause "exception: cause message" "exception.iyi" \
  's/def initialize(@message : String? = nil, @cause : ::Exception? = nil)/def initialize(@message : String? = nil, @cause : ::Exception? = nil); @cause = nil/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/runtime_objects checks and failure proofs passed"
else
  echo "std/runtime_objects exercise had failures"
fi

exit "$status"
