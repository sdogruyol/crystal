#!/usr/bin/env bash
# IO and filesystem standard library exercise driver.
# Runs the io and filesystem exercise (std/path, std/env, std/dir, std/file_utils,
# std/file, std/io) in plain and release mode, checks every section reported,
# and proves the checks can fail by patching copies of the libraries via IYI_PATH.
#
#     bash bench/std_io_filesystem_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   * Path basename computation
#   * ENV key retrieval
#   * Dir children collection
#   * FileUtils comparison
#   * File size reporting
#   * IO::Memory string representation
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
  echo "  building $label..."
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_io_filesystem_exercise.iyi" >"$WORK/$name.build.log" 2>&1; then
    echo "  $label: build failed"
    sed -n '1,12p' "$WORK/$name.build.log"
    status=1
    return
  fi
  if ! "$WORK/$name" >"$WORK/$name.out" 2>&1; then
    echo "  $label: run failed"
    sed -n '1,12p' "$WORK/$name.out"
    status=1
    return
  fi
  echo "  $label: all io and filesystem checks passed"
}

echo "== the io and filesystem exercise, plain build"
run_case "plain" io_fs-plain
if ! grep -q "all std/io and filesystem checks passed" "$WORK/io_fs-plain.out" 2>/dev/null; then
  echo "plain run did not report final success"
  status=1
fi

echo
echo "== every module section reported"
for phrase in "== std/path" "== std/env" "== std/dir" "== std/file_utils" "== std/file" "== std/io"; do
  if ! grep -q "$phrase" "$WORK/io_fs-plain.out" 2>/dev/null; then
    echo "missing section: $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  Path, ENV, Dir, FileUtils, File, and IO sections all reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" io_fs-release --release
if ! grep -q "all std/io and filesystem checks passed" "$WORK/io_fs-release.out" 2>/dev/null; then
  echo "release run did not report final success"
  status=1
fi

echo
echo "== proving the checks can fail when operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy unmodified siblings so include resolves everything
  cp "$REPO/src/std/"*.iyi "$WORK/$dir/std/" 2>/dev/null || true
  # Patch the targeted file
  sed -e "$sed_script" "$REPO/src/std/$file" > "$WORK/$dir/std/$file"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it.
  if cmp -s "$REPO/src/std/$file" "$WORK/$dir/std/$file"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_io_filesystem_exercise.iyi" \
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

# 1. Path basename broken
prove_fails "path basename broken" no_path_base "path basename" "path.iyi" \
  's/base_len = last - first + 1/base_len = 0/'

# 2. ENV retrieval broken
prove_fails "env retrieval broken" no_env_get "Missing ENV key" "env.iyi" \
  's/val = self\[key\]?/val = nil/'

# 3. Dir children collection broken
prove_fails "dir children broken" no_dir_child "dir children size" "dir.iyi" \
  's/res << entry/# res << entry/'

# 4. FileUtils cmp broken
prove_fails "file_utils cmp broken" no_fu_cmp "fu cmp identical" "file_utils.iyi" \
  's/c1 == c2/c1 != c2/'

# 5. File size reporting broken
prove_fails "file size broken" no_file_size "file size" "file.iyi" \
  's/info(path)\.size/0_i64/'
# 6. IO::Memory to_s broken
prove_fails "io memory to_s broken" no_mem_tos "mem to_s" "io.iyi" \
  's/String\.new(@bytesize)/String.new(0)/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/io and filesystem checks and failure proofs passed"
fi

exit "$status"
