#!/usr/bin/env bash
# DEFLATE (RFC 1951), Zlib (RFC 1950), and Gzip (RFC 1952) exercise driver.
# Runs the compress exercise in plain and release mode, checks every section
# reported, verifies cross-implementation compatibility against system gzip
# and python zlib in both directions, reports compression ratios against gzip -9,
# executes dedicated boundary-failure panic probes, and proves the checks can fail
# by patching copies of std/compress.iyi via IYI_PATH.
#
#     bash bench/std_compress_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   - Checksum algorithms (Adler-32 and CRC-32)
#   - DEFLATE stored block encoding and length validation
#   - Fixed Huffman block encoding and decoding
#   - Dynamic Huffman block encoding and decoding
#   - Zlib header check and Adler-32 verification
#   - Gzip magic byte check and CRC-32/ISIZE verification
#   - Truncated streams, invalid block types, and out-of-bounds backward distances
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
  ln -sf "$REPO/src/std/enumerable.iyi" "$target_dir/std/enumerable.iyi"
  ln -sf "$REPO/src/std/traits.iyi" "$target_dir/std/traits.iyi"
}

DEFAULT_INCLUDE="$WORK/default_include"
SETUP_INCLUDE "$DEFAULT_INCLUDE"
ln -sf "$REPO/src/std/compress.iyi" "$DEFAULT_INCLUDE/std/compress.iyi"

run_case() {
  local label="$1" name="$2"
  shift 2
  if ! IYI_PATH="$DEFAULT_INCLUDE:$REPO/src" "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_compress_exercise.iyi" \
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

echo "== the compress exercise, plain build"
run_case "plain" compress-plain
if ! grep -q "all std/compress checks passed" "$WORK/compress-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every compress section reported"
for phrase in "checksums:" "deflate stored:" "deflate fixed:" "deflate dynamic:" "zlib wrapper:" "gzip wrapper:" "cross-implementation:" "bounded decompress:"; do
  if ! grep -qi "$phrase" "$WORK/compress-plain.out" 2>/dev/null; then
    echo "  MISSING: nothing reported for $phrase"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "  all expected sections reported cleanly"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" compress-release --release
if ! grep -q "all std/compress checks passed" "$WORK/compress-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

# -----------------------------------------------------------------------------
# Cross-implementation validation: system gzip / python zlib vs iyi
# -----------------------------------------------------------------------------
echo
echo "== cross-implementation verification with system gzip and python zlib"

VEC_DIR="$WORK/vectors"
mkdir -p "$VEC_DIR"

python3 -c "
import zlib, gzip, random

tests = {
    'empty': b'',
    'rep': b'ABCDEFGHIJ' * 1000, # 10,000 bytes
    'text': b'The quick brown fox jumps over the lazy dog.\n' * 100, # 4,500 bytes
    'rand': bytes([((i * 1103515245 + 12345) >> 16) & 0xFF for i in range(2048)])
}

for name, data in tests.items():
    with open(f'$VEC_DIR/{name}.raw', 'wb') as f:
        f.write(data)
    with open(f'$VEC_DIR/{name}_def0.bin', 'wb') as f:
        f.write(zlib.compress(data, 0)[2:-4])
    with open(f'$VEC_DIR/{name}_def1.bin', 'wb') as f:
        f.write(zlib.compress(data, 1)[2:-4])
    with open(f'$VEC_DIR/{name}_def6.bin', 'wb') as f:
        f.write(zlib.compress(data, 6)[2:-4])
    with open(f'$VEC_DIR/{name}_def9.bin', 'wb') as f:
        f.write(zlib.compress(data, 9)[2:-4])
    with open(f'$VEC_DIR/{name}.zlib', 'wb') as f:
        f.write(zlib.compress(data, 6))
    with open(f'$VEC_DIR/{name}.gz', 'wb') as f:
        f.write(gzip.compress(data, 9))
"

# Build dedicated cross-runner in iyi that decompress external vectors and compresses test files
cat << 'EOF' > "$WORK/cross_runner.iyi"
module bench/cross_runner

import std/slice
using std/slice::{Slice}
import std/compress
using std/compress::{Deflate, Inflate, Zlib, Gzip}

def read_bytes(path : String) : Std::Slice::Bytes
  str = File.read(path)
  b = Slice(UInt8).new(str.bytesize, 0_u8)
  b.copy_from(str.to_unsafe, str.bytesize) if str.bytesize > 0
  b
end

def write_bytes(path : String, bytes : Std::Slice::Bytes) : Nil
  File.open(path, "w") do |io|
    io.write(bytes.to_unsafe, bytes.size)
    io.flush
  end
end

def test_file(vec_dir : String, name : String) : Nil
  raw = read_bytes(vec_dir + "/" + name + ".raw")

  # Decode external vectors
  def0 = read_bytes(vec_dir + "/" + name + "_def0.bin")
  raise "def0 mismatch #{name}" unless Inflate.decompress(def0) == raw

  def1 = read_bytes(vec_dir + "/" + name + "_def1.bin")
  raise "def1 mismatch #{name}" unless Inflate.decompress(def1) == raw

  def6 = read_bytes(vec_dir + "/" + name + "_def6.bin")
  raise "def6 mismatch #{name}" unless Inflate.decompress(def6) == raw

  def9 = read_bytes(vec_dir + "/" + name + "_def9.bin")
  raise "def9 mismatch #{name}" unless Inflate.decompress(def9) == raw

  z_in = read_bytes(vec_dir + "/" + name + ".zlib")
  raise "zlib mismatch #{name}" unless Zlib.decompress(z_in) == raw

  gz_in = read_bytes(vec_dir + "/" + name + ".gz")
  raise "gzip mismatch #{name}" unless Gzip.decompress(gz_in) == raw

  # Compress with iyi and write out for external validation
  c_def = Deflate.compress(raw, 6)
  write_bytes(vec_dir + "/" + name + "_iyi_def.bin", c_def)

  c_z = Zlib.compress(raw, 6)
  write_bytes(vec_dir + "/" + name + "_iyi.zlib", c_z)

  c_gz = Gzip.compress(raw, 6)
  write_bytes(vec_dir + "/" + name + "_iyi.gz", c_gz)
end

def main : Nil
  v = "/tmp/compress_cross_vectors"
  test_file(v, "empty")
  test_file(v, "rep")
  test_file(v, "text")
  test_file(v, "rand")
  puts "  iyi decoded external stored, fixed, dynamic, zlib, and gzip vectors cleanly"
  puts "  iyi compressed streams written for external verification"
end

main
EOF

# Ensure /tmp/compress_cross_vectors exists and symlinks to VEC_DIR
rm -rf /tmp/compress_cross_vectors
ln -s "$VEC_DIR" /tmp/compress_cross_vectors

if ! IYI_PATH="$DEFAULT_INCLUDE:$REPO/src" "$IYI" build -o "$WORK/cross_runner" "$WORK/cross_runner.iyi" \
     >"$WORK/cross_runner.build.log" 2>&1; then
  echo "  cross runner: build failed"
  sed -n '1,12p' "$WORK/cross_runner.build.log"
  status=1
else
  "$WORK/cross_runner" >"$WORK/cross_runner.out" 2>&1
  if [ $? -ne 0 ]; then
    echo "  cross runner: failed to decompress external vectors"
    cat "$WORK/cross_runner.out"
    status=1
  else
    sed 's/^/  /' "$WORK/cross_runner.out"
  fi
fi

# Reverse validation: verify that python zlib and system gunzip decompress iyi's output
python3 -c "
import zlib, gzip, subprocess, os

vec_dir = '$VEC_DIR'
names = ['empty', 'rep', 'text', 'rand']

for name in names:
    with open(f'{vec_dir}/{name}.raw', 'rb') as f:
        orig = f.read()

    # Python zlib decompresses iyi DEFLATE
    with open(f'{vec_dir}/{name}_iyi_def.bin', 'rb') as f:
        iyi_def = f.read()
    dec_def = zlib.decompress(iyi_def, -15)
    assert dec_def == orig, f'python zlib failed on iyi deflate {name}'

    # Python zlib decompresses iyi Zlib
    with open(f'{vec_dir}/{name}_iyi.zlib', 'rb') as f:
        iyi_zlib = f.read()
    dec_zlib = zlib.decompress(iyi_zlib)
    assert dec_zlib == orig, f'python zlib failed on iyi zlib {name}'

    # Python gzip decompresses iyi Gzip
    with open(f'{vec_dir}/{name}_iyi.gz', 'rb') as f:
        iyi_gz = f.read()
    dec_gz = gzip.decompress(iyi_gz)
    assert dec_gz == orig, f'python gzip failed on iyi gzip {name}'

    # System gunzip -d -c decompresses iyi Gzip
    res = subprocess.run(['gzip', '-d', '-c', f'{vec_dir}/{name}_iyi.gz'], capture_output=True, check=True)
    assert res.stdout == orig, f'system gunzip failed on iyi gzip {name}'

print('  system gunzip and python zlib verified all iyi compressed outputs byte for byte')
"
if [ $? -ne 0 ]; then
  echo "  reverse cross-implementation verification failed"
  status=1
fi

# -----------------------------------------------------------------------------
# Compression ratio reporting: honest comparison against zlib / gzip -9
# -----------------------------------------------------------------------------
echo
echo "== compression ratio comparison: iyi Deflate/Gzip vs zlib / system gzip -9"
python3 -c "
import os, subprocess, zlib, gzip

vec_dir = '$VEC_DIR'
names = [
    ('empty', 'Empty input (0 bytes)'),
    ('rep', 'Repetitive run (10,000 bytes)'),
    ('text', 'Repeated text (4,500 bytes)'),
    ('rand', 'Random bytes (2,048 bytes)'),
]

print('  -- Pure DEFLATE Payload Comparison (excluding container framing) --')
h1 = f'  {\"Test Input\":<32} | {\"Original\":<10} | {\"iyi DEFLATE\":<12} | {\"zlib -9\":<10} | {\"Payload Delta\":<14}'
sep1 = '  ' + '-' * (len(h1) - 2)
print(sep1)
print(h1)
print(sep1)

for name, desc in names:
    raw_path = f'{vec_dir}/{name}.raw'
    orig_sz = os.path.getsize(raw_path)
    with open(raw_path, 'rb') as f:
        raw_data = f.read()
    
    iyi_def_sz = os.path.getsize(f'{vec_dir}/{name}_iyi_def.bin')
    zlib_def_sz = len(zlib.compress(raw_data, 9)[2:-4])
    delta = iyi_def_sz - zlib_def_sz
    delta_str = f'{delta:+d} B' if delta != 0 else 'identical'

    print(f'  {desc:<32} | {orig_sz:>8} B | {iyi_def_sz:>10} B | {zlib_def_sz:>8} B | {delta_str:>14}')

print(sep1)
print()
print('  -- Gzip Container Comparison (framing + metadata breakdown) --')
h2 = f'  {\"Test Input\":<32} | {\"iyi Gzip\":<10} | {\"py Gzip\":<10} | {\"CLI gzip -9\":<12} | {\"CLI Note\":<25}'
sep2 = '  ' + '-' * (len(h2) - 2)
print(sep2)
print(h2)
print(sep2)

for name, desc in names:
    raw_path = f'{vec_dir}/{name}.raw'
    with open(raw_path, 'rb') as f:
        raw_data = f.read()
    
    iyi_sz = os.path.getsize(f'{vec_dir}/{name}_iyi.gz')
    py_sz = len(gzip.compress(raw_data, 9))

    copy_path = f'{vec_dir}/{name}_sys.raw'
    with open(raw_path, 'wb') as src, open(copy_path, 'wb') as dst:
        dst.write(raw_data)
    subprocess.run(['gzip', '-9', '-f', copy_path], check=True)
    cli_sz = os.path.getsize(f'{copy_path}.gz')
    
    fname_overhead = cli_sz - py_sz
    note = f'+{fname_overhead} B FNAME header' if fname_overhead > 0 else 'no extra metadata'
    print(f'  {desc:<32} | {iyi_sz:>8} B | {py_sz:>8} B | {cli_sz:>10} B | {note:<25}')

print(sep2)
print('  Note: CLI gzip -9 includes original filename (FNAME) in the header.')
print('  iyi Gzip omits FNAME and sets MTIME=0 for deterministic, reproducible output.')
"

# -----------------------------------------------------------------------------
# Dedicated corrupt-stream panic probes (panics on invalid inputs)
# -----------------------------------------------------------------------------
echo
echo "== dedicated corrupt-stream panic probes (refuses invalid inputs)"

prove_panic() {
  local label="$1" code="$2" expected_phrase="$3"
  local probe_file="$WORK/probe_${label}.iyi"
  local bin_file="$WORK/probe_${label}"

  cat <<EOF > "$probe_file"
module bench/probe_${label}

import std/slice
using std/slice::{Slice}
import std/compress
using std/compress::{Deflate, Inflate, Zlib, Gzip}

def make_bytes(size : Int32, &block : Int32 -> UInt8) : Std::Slice::Bytes
  b = Slice(UInt8).new(size, 0_u8)
  i = 0
  while i < size
    b[i] = yield i
    i = i + 1
  end
  b
end

def main : Nil
  $code
end

main
EOF

  if ! IYI_PATH="$DEFAULT_INCLUDE:$REPO/src" "$IYI" build -o "$bin_file" "$probe_file" > "$WORK/${label}.build.log" 2>&1; then
    echo "  probe $label: build failed unexpectedly"
    sed -n '1,12p' "$WORK/${label}.build.log"
    status=1
    return
  fi

  "$bin_file" > "$WORK/${label}.out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  probe $label: succeeded unexpectedly (should have panicked)"
    status=1
    return
  fi

  if ! grep -q "$expected_phrase" "$WORK/${label}.out"; then
    echo "  probe $label: failed but with wrong message:"
    sed -n '1,5p' "$WORK/${label}.out"
    status=1
    return
  fi
  echo "  probe $label: panicked as expected ($expected_phrase)"
}

# 1. Truncated DEFLATE stream
prove_panic "truncated_deflate" \
  'good = Deflate.compress(make_bytes(50) { 65_u8 }, 6); bad = good[0, good.size // 2]; Inflate.decompress(bad)' \
  "unexpected end of compressed data"

# 2. Invalid DEFLATE block type (BTYPE 3 is reserved)
prove_panic "invalid_btype3" \
  'bad = make_bytes(2) { 7_u8 }; Inflate.decompress(bad)' \
  "invalid DEFLATE block type: 3"

# 3. Stored block length corruption (NLEN != ~LEN)
prove_panic "stored_bad_len" \
  'bad = make_bytes(7) { 0_u8 }; bad[0] = 1_u8; bad[1] = 5_u8; bad[3] = 5_u8; Inflate.decompress(bad)' \
  "stored block length check failed"

# 4. Invalid zlib header check formula
prove_panic "zlib_bad_check" \
  'good = Zlib.compress(make_bytes(10) { 65_u8 }, 6); bad = good.dup; bad[1] = 0_u8; Zlib.decompress(bad)' \
  "invalid zlib header check"

# 5. Corrupt Adler-32 in zlib footer
prove_panic "zlib_bad_adler" \
  'good = Zlib.compress(make_bytes(10) { 65_u8 }, 6); bad = good.dup; bad[bad.size - 1] = (bad[bad.size - 1] ^ 0xFF_u8); Zlib.decompress(bad)' \
  "zlib Adler-32 checksum mismatch"

# 6. Invalid gzip magic bytes
prove_panic "gzip_bad_magic" \
  'good = Gzip.compress(make_bytes(10) { 65_u8 }, 6); bad = good.dup; bad[0] = 0_u8; Gzip.decompress(bad)' \
  "not in gzip format"

# 7. Corrupt CRC-32 in gzip footer
prove_panic "gzip_bad_crc" \
  'good = Gzip.compress(make_bytes(10) { 65_u8 }, 6); bad = good.dup; bad[bad.size - 8] = (bad[bad.size - 8] ^ 0xFF_u8); Gzip.decompress(bad)' \
  "gzip CRC-32 checksum mismatch"

# 8. Corrupt ISIZE in gzip footer
prove_panic "gzip_bad_isize" \
  'good = Gzip.compress(make_bytes(10) { 65_u8 }, 6); bad = good.dup; bad[bad.size - 1] = (bad[bad.size - 1] ^ 0x01_u8); Gzip.decompress(bad)' \
  "gzip ISIZE length mismatch"

# -----------------------------------------------------------------------------
# Proving the checks can fail via patched copies of std/compress.iyi
# -----------------------------------------------------------------------------
echo
echo "== proving the exercise checks can fail when compress operations are broken"

prove_fails() {
  local label="$1" dir="$2" bad_pattern="$3" sed_script="$4"
  local patch_dir="$WORK/$dir"
  SETUP_INCLUDE "$patch_dir"
  sed -e "$sed_script" "$REPO/src/std/compress.iyi" > "$patch_dir/std/compress.iyi"
  # A patch that matches nothing leaves the library intact, and an intact
  # library passes, which reads as "this check cannot fail" when the truth is
  # that nothing was broken to test it. Line-anchored patches drift.
  if cmp -s "$REPO/src/std/compress.iyi" "$patch_dir/std/compress.iyi"; then
    echo "  $label: the patch changed nothing, so this proves nothing"
    status=1
    return
  fi

  if ! IYI_PATH="$patch_dir:$REPO/src" "$IYI" build \
       -o "$patch_dir/program" "$REPO/bench/std_compress_exercise.iyi" \
       >"$patch_dir/build.log" 2>&1; then
    echo "  $label: the patched compress library did not build"
    sed -n '1,12p' "$patch_dir/build.log"
    status=1
    return
  fi

  "$patch_dir/program" >"$patch_dir/out" 2>&1
  local exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    echo "  $label: the exercise still passed, so it does not test this"
    status=1
    return
  fi

  if grep -q "$bad_pattern" "$patch_dir/out"; then
    echo "  $label: caught failure as expected ($bad_pattern)"
  else
    echo "  $label: failed, but with unexpected output (expected '$bad_pattern'):"
    sed -n '1,4p' "$patch_dir/out"
    status=1
  fi
}

# 1. Broken Adler-32
prove_fails "broken adler32" "fail_adler" "adler32: empty" \
  's/update(1_u64, data)/update(0_u64, data)/'

# 2. Broken CRC-32
prove_fails "broken crc32" "fail_crc" "crc32: single 'a'" \
  's/poly = 0xEDB88320_u64/poly = 0x12345678_u64/'

# 3. Broken Stored Block (corrupted NLEN emission)
prove_fails "broken stored block" "fail_stored" "stored block length check failed" \
  's/nlen = (chunk \^ 0xFFFF) & 0xFFFF/nlen = chunk/'

# 4. Broken Fixed Huffman (corrupt literal code mapping)
prove_fails "broken fixed huffman" "fail_fixed" "deflate fixed: text roundtrip" \
  's/code = 0x30 + sym/code = 0x31 + sym/'

# 5. Broken Dynamic Huffman table invariant (HLIT <= 286)
prove_fails "broken dynamic hlit invariant" "fail_dyn_hlit" "hlit error mismatch" \
  's/if hlit > 286 # DYNAMIC_HLIT_INVARIANT/if false # DYNAMIC_HLIT_INVARIANT/'

# 6. Broken Zlib header (violates (CMF*256+FLG)%31 == 0)
prove_fails "broken zlib header" "fail_zlib" "invalid zlib header check" \
  's/ptr\[1\] = 0x9C_u8/ptr[1] = 0x00_u8/'

# 7. Broken Gzip header (emits wrong magic byte)
prove_fails "broken gzip header" "fail_gzip" "not in gzip format" \
  's/ptr\[0\] = 0x1F_u8/ptr[0] = 0x00_u8/'

# 8a. Bypassed stored block limit guard (vector 01 05 00 fa ff 48 65 6c 6c 6f with limit 3)
prove_fails "bypassed stored limit" "fail_lim_stored" "expected DecompressLimitExceeded for stored limit overflow" \
  's/.*# GUARD_STORED_LIMIT/if false # GUARD_STORED_LIMIT/'

# 8b. Bypassed fixed-Huffman literal limit guard (vector f3 48 cd c9 c9 07 00 with limit 2)
prove_fails "bypassed literal limit" "fail_lim_lit" "expected DecompressLimitExceeded for fixed literal limit overflow" \
  's/.*# GUARD_LITERAL_LIMIT/if false # GUARD_LITERAL_LIMIT/'

# 8c. Bypassed LZ77 match copy limit guard (bomb with limit 75)
prove_fails "bypassed match limit" "fail_lim_match" "expected DecompressLimitExceeded for match limit overflow" \
  's/.*# GUARD_MATCH_LIMIT/if false # GUARD_MATCH_LIMIT/'
echo
if [ "$status" -eq 0 ]; then
  echo "ALL COMPRESS EXERCISE CHECKS AND FAILURE PROOFS PASSED"
else
  echo "SOME CHECKS FAILED (status $status)"
fi

rm -rf /tmp/compress_cross_vectors
exit "$status"
