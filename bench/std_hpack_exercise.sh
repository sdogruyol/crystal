#!/usr/bin/env bash
# HPACK (RFC 7541) HTTP/2 header compression standard library exercise driver.
# Runs the HPACK exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/hpack.iyi.
#
#     bash bench/std_hpack_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across
# integer encoding, Huffman decoding, dynamic table eviction, decompression bomb
# defense, invalid index rejection, Huffman padding validation, and never-indexed
# representation preservation.
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_hpack_exercise.iyi" \
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

echo "== the hpack exercise, plain build"
run_case "plain" hpack-plain
if ! grep -q "all std/hpack checks passed" "$WORK/hpack-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every hpack section reported"
for phrase in \
  "integer representation (rfc 7541 c.1)" \
  "huffman coding (rfc 7541 appendix b)" \
  "header field representations (rfc 7541 c.2)" \
  "request sequence without huffman (rfc 7541 c.3)" \
  "request sequence with huffman (rfc 7541 c.4)" \
  "response sequence without huffman and eviction (rfc 7541 c.5)" \
  "response sequence with huffman and eviction (rfc 7541 c.6)" \
  "security: dynamic table size updates and settings" \
  "security: decompression bomb defenses" \
  "security: invalid index and never-indexed persistence"; do
  if ! grep -q "== $phrase" "$WORK/hpack-plain.out" 2>/dev/null; then
    echo "  MISSING: $phrase was not reported"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all 10 sections successfully reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" hpack-release --release
if ! grep -q "all std/hpack checks passed" "$WORK/hpack-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when hpack operations are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" sed_script="$4"
  mkdir -p "$WORK/$dir/std"
  sed -e "$sed_script" "$REPO/src/std/hpack.iyi" > "$WORK/$dir/std/hpack.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/hpack.iyi" "$WORK/$dir/std/hpack.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi
  if ! IYI_PATH="$WORK/$dir:$REPO/src" "$IYI" build \
       -o "$WORK/$dir/program" "$REPO/bench/std_hpack_exercise.iyi" \
       >"$WORK/$dir/build.log" 2>&1; then
    echo "  $label: the patched hpack library did not build"
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

# 1. Integer encoding broken (prefix_max zeroed)
prove_fails "integer encoding broken" no_int "assertion failed: c.1.1 encode 10 with 5-bit prefix" \
  's/prefix_max = (1_u64.unsafe_shl(prefix_bits)) - 1_u64/prefix_max = 0_u64/'

# 2. Huffman decoding broken (emits corrupted symbol byte)
prove_fails "huffman decoding broken" no_huff "assertion failed: c.4.1 huffman decode www.example.com" \
  's/out_chars << sym.to_u8/out_chars << (sym ^ 1).to_u8/'

# 3. Dynamic table eviction broken
prove_fails "dynamic table eviction broken" no_evict "assertion failed: c.5.2 dynamic table size 222 (after eviction)" \
  's/@size + entry_size > @max_size/false/'

# 4. Decompression bomb size limit defense disabled
prove_fails "decompression bomb list size defense disabled" no_bomb_size "assertion failed: decompression bomb: list size limit enforced" \
  's/if total_uncompressed_size > @max_header_list_size/if false/'

# 5. Decompression bomb count limit defense disabled
prove_fails "decompression bomb header count defense disabled" no_bomb_count "assertion failed: decompression bomb: header count limit enforced" \
  's/if header_count > @max_header_count/if false/'

# 6. Invalid index 0 check disabled
prove_fails "invalid index 0 check disabled" no_zero_check "assertion failed: index 0 in indexed field is rejected with invalid index message" \
  's/if idx == 0/if false/'

# 7. Huffman padding validation disabled
prove_fails "huffman padding check disabled" no_pad_check "assertion failed: huffman rejects padding > 7 bits" \
  's/if bits_since_sym > 7 || state > 7/if false/'

# 8. Never-indexed representation disabled
prove_fails "never-indexed representation disabled" no_never_indexed "assertion failed: c.2.3 encode back matches hex" \
  's/if field.indexing == IndexingMode::NeverIndexed/if false/'

echo
if [ "$status" -eq 0 ]; then
  echo "all std/hpack exercise runs and failure proofs passed"
else
  echo "std/hpack exercise failed"
fi
exit "$status"
