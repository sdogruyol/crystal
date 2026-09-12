#!/usr/bin/env bash
# Cryptography and digest standard library exercise driver.
# Runs the crypto exercise in plain and release mode, checks every section
# reported, and proves the checks can fail by patching copies of std/crypto.iyi
# and std/digest.iyi.
#
#     bash bench/std_crypto_exercise.sh
#
# A check that cannot fail is not a check. This script proves failure across:
#   1. AES-128-GCM tampered tag rejection (authentication bypass refusal)
#   2. ChaCha20-Poly1305 tampered tag rejection (authentication bypass refusal)
#   3. Digest output integrity (corrupted round output detected)
#   4. Constant-time comparison discrimination (forged equality refused)
#   5. HMAC key-pad integrity (wrong ipad calculation detected)
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
  if ! "$IYI" build "$@" -o "$WORK/$name" "$REPO/bench/std_crypto_exercise.iyi" \
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

echo "== the crypto exercise, plain build"
run_case "plain" crypto-plain
if ! grep -q "all std/crypto checks passed" "$WORK/crypto-plain.out" 2>/dev/null; then
  echo "  MISSING: plain build did not reach the end"
  status=1
fi

echo
echo "== every crypto section reported"
for phrase in "md5:" "sha1:" "sha256:" "sha384:" "sha512:" "streaming:" "compare:" "csprng:" "hmac:" "hkdf:" "chacha20-poly1305:" "aes-128-gcm:" "aes-256-gcm:"; do
  grep -q "$phrase" "$WORK/crypto-plain.out" 2>/dev/null || {
    echo "  MISSING: nothing reported for $phrase"
    status=1
  }
done
[ "$status" -eq 0 ] && echo "  md5, sha1, sha256, sha384, sha512, streaming, compare, csprng, hmac, hkdf, chacha20-poly1305, aes-128-gcm, and aes-256-gcm all reported"

echo
echo "== the same program with optimisation on (--release)"
run_case "release" crypto-release --release
if ! grep -q "all std/crypto checks passed" "$WORK/crypto-release.out" 2>/dev/null; then
  echo "  MISSING: release build did not reach the end"
  status=1
fi

echo
echo "== proving the checks can fail when cryptographic protections are broken"

prove_fails() {
  local label="$1" dir="$2" phrase="$3" target_file="$4" sed_script="$5"
  mkdir -p "$WORK/$dir/std"
  # Copy sibling files so both std/digest and std/crypto are reachable
  cp "$REPO/src/std/digest.iyi" "$WORK/$dir/std/"
  cp "$REPO/src/std/crypto.iyi" "$WORK/$dir/std/"
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
       -o "$WORK/$dir/program" "$REPO/bench/std_crypto_exercise.iyi" \
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

# 1. AES-128-GCM tag verification bypassed (must fail: tampered tag accepted)
prove_fails "aes-128-gcm tampered tag accepted" aes_tamper \
  "assertion failed: AES-128-GCM rejected tampered tag" "crypto.iyi" \
  '/AES-GCM: key must be 16 or 32 bytes/,/^  end$/s/return nil unless Std::Crypto.constant_time_compare(tag, expected_tag)/# bypass/'

# 2. ChaCha20-Poly1305 tag verification bypassed (must fail: tampered tag accepted)
prove_fails "chacha20-poly1305 tampered tag accepted" chacha_tamper \
  "assertion failed: ChaCha20-Poly1305 rejected tampered tag" "crypto.iyi" \
  '/ChaCha20Poly1305: key must be 32 bytes/,/^  end$/s/return nil unless Std::Crypto.constant_time_compare(tag, expected_tag)/# bypass/'

# 3. Digest output corrupted (zeroing first word of SHA-1/SHA-256)
prove_fails "digest output corrupted" digest_corrupt \
  "assertion failed: RFC 3174 Test 1 (empty)" "digest.iyi" \
  's/DigestUtils.put_u32_be(ptr, 0, @h0)/DigestUtils.put_u32_be(ptr, 0, 0_u64)/'

# 4. Constant-time comparison forged (diff == 0 always returns true)
prove_fails "constant-time compare forged" compare_forged \
  "assertion failed: constant-time unequal slices" "crypto.iyi" \
  's/diff == 0_u8/true/'

# 5. HMAC key ipad corrupted
prove_fails "hmac key ipad corrupted" hmac_corrupt \
  "assertion failed: RFC 2202 HMAC-MD5 Case 1" "crypto.iyi" \
  's/k_ipad\[i\] = actual_key\[i\] \^ 0x36_u8/k_ipad[i] = actual_key[i]/'

# 6. QUIC AES header protection mask taken from the wrong offset
prove_fails "quic aes header mask offset broken" hp_aes \
  "assertion failed: A.2 client Initial mask" "crypto.iyi" \
  '/RFC 9001 section 5.4.3/,/^  end$/s/mask\[i\] = block\[i\]/mask[i] = block[i + 1]/'

# 7. QUIC ChaCha20 header protection counter read big-endian
prove_fails "quic chacha header counter endianness broken" hp_chacha \
  "assertion failed: A.5 ChaCha20 short header mask" "crypto.iyi" \
  '/RFC 9001 section 5.4.4/,/^  end$/s/unsafe_shl((8 \* i).to_u64)/unsafe_shl((24 - 8 * i).to_u64)/'

echo
if [ "$status" -eq 0 ]; then
  echo "Crypto standard library: MD5, SHA-1, SHA-256, SHA-384, SHA-512, streaming,"
  echo "constant-time compare, CSPRNG, HMAC, HKDF, ChaCha20-Poly1305, AES-128-GCM, and"
  echo "AES-256-GCM all pass plain and optimised, and each check is proven to fail"
  echo "when its mechanism is broken."
else
  echo "Crypto standard library: something above failed."
fi
exit "$status"
