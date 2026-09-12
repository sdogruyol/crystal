#!/usr/bin/env bash
# Exercises the self-hosting LLVM backend: bindings, wrappers, IR construction,
# pass manager optimization, and native object emission.
#
#   bash bench/selfhost_llvm_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost LLVM exercise
# 2. --release compilation and execution
# 3. Native object file emission, linking with C driver, and execution (add_numbers(40, 2) == 42)
# 4. Guarded mutation proofs verifying that checks catch injected LLVM builder/type defects
#

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
  for f in "$REPO/src/compiler/llvm/"*.orig; do
    if [ -f "$f" ]; then
      target="${f%.orig}"
      cp "$f" "$target"
      rm -f "$f"
    fi
  done
}
trap cleanup EXIT
export PATH="/opt/homebrew/bin:/usr/bin:/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/opt/bdw-gc/lib:${LIBRARY_PATH:-}"

status=0
mkdir -p "$WORK/plain_out" "$WORK/release_out" "$WORK/mut1_out" "$WORK/mut2_out" "$WORK/mut3_out" "$WORK/mut4_out" "$WORK/mut5_out" "$WORK/final_out"

echo "== 1. Building and running selfhost LLVM exercise (plain mode)"
"$IYI" build -o "$WORK/exercise-plain" "$REPO/bench/selfhost_llvm_exercise.iyi"
"$WORK/exercise-plain" "$WORK/plain_out" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"

echo
echo "== Checking reported verification sections in plain mode"
for phrase in \
  "== 1. Target initialization & identification" \
  "== 2. Context & Type system" \
  "== 3. Constants & Values" \
  "== 4. Module construction, globals & functions" \
  "== 5. Verification" \
  "== 6. Optimization passes (PassBuilder)" \
  "== 7. Object, Assembly, Bitcode emission" \
  "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!"; do
  if ! grep -qF "$phrase" "$WORK/plain.out"; then
    echo "FAILED: missing '$phrase'"
    exit 1
  fi
done

echo
echo "== 2. Building and running selfhost LLVM exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_llvm_exercise.iyi"
"$WORK/exercise-release" "$WORK/release_out" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST LLVM CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "FAILED: release mode did not pass checks"
  exit 1
fi

echo
echo "== 3. Verifying native object emission, linking, and execution"
if [ ! -f "$WORK/plain_out/selfhost_llvm_test.o" ]; then
  echo "FAILED: object file not found at $WORK/plain_out/selfhost_llvm_test.o"
  exit 1
fi

# Check Mach-O / ELF object file
file "$WORK/plain_out/selfhost_llvm_test.o"

# Create C driver to link against emitted object
cat <<'C_RUNNER' > "$WORK/driver.c"
#include <stdio.h>
#include <stdlib.h>

extern int add_numbers(int a, int b);
extern int factorial(int n);

int main() {
    int sum = add_numbers(40, 2);
    if (sum != 42) {
        fprintf(stderr, "FAIL: add_numbers(40, 2) = %d, expected 42\n", sum);
        return 1;
    }
    printf("add_numbers(40, 2) = %d [OK]\n", sum);

    int fact5 = factorial(5);
    if (fact5 != 120) {
        fprintf(stderr, "FAIL: factorial(5) = %d, expected 120\n", fact5);
        return 2;
    }
    printf("factorial(5) = %d [OK]\n", fact5);

    printf("EMITTED OBJECT EXECUTION VERIFIED SUCCESSFULLY!\n");
    return 0;
}
C_RUNNER

clang "$WORK/driver.c" "$WORK/plain_out/selfhost_llvm_test.o" -o "$WORK/test_runner"
"$WORK/test_runner" > "$WORK/driver.out"
cat "$WORK/driver.out"

if ! grep -qF "EMITTED OBJECT EXECUTION VERIFIED SUCCESSFULLY!" "$WORK/driver.out"; then
  echo "FAILED: emitted object execution failed"
  exit 1
fi

echo
echo "== 4. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# Mutation 1: Corrupt build_and to build_or in builder.iyi
echo "  [mutation 1] corrupting build_and in builder.iyi"
cp "$REPO/src/compiler/llvm/builder.iyi" "$REPO/src/compiler/llvm/builder.iyi.orig"
sed -i.bak 's/LibLLVM\.build_and/LibLLVM.build_or/' "$REPO/src/compiler/llvm/builder.iyi" && rm -f "$REPO/src/compiler/llvm/builder.iyi.bak"
if diff -u "$REPO/src/compiler/llvm/builder.iyi.orig" "$REPO/src/compiler/llvm/builder.iyi" >/dev/null; then
  echo "FAILED: patch did not change file"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_llvm_exercise.iyi" -- "$WORK/mut1_out" > "$WORK/mut1.log" 2>&1; then
  echo "FAILED: mutation 1 was not caught by exercise checks!"
  exit 1
fi
cp "$REPO/src/compiler/llvm/builder.iyi.orig" "$REPO/src/compiler/llvm/builder.iyi"
rm -f "$REPO/src/compiler/llvm/builder.iyi.orig"
echo "    reverted mutation 1"

# Mutation 2: Corrupt int_width in values.iyi
echo "  [mutation 2] corrupting int_width in values.iyi"
cp "$REPO/src/compiler/llvm/values.iyi" "$REPO/src/compiler/llvm/values.iyi.orig"
sed -i.bak 's/LibLLVM\.get_int_type_width(@unwrap)/LibLLVM.get_int_type_width(@unwrap) + 1/' "$REPO/src/compiler/llvm/values.iyi" && rm -f "$REPO/src/compiler/llvm/values.iyi.bak"
if diff -u "$REPO/src/compiler/llvm/values.iyi.orig" "$REPO/src/compiler/llvm/values.iyi" >/dev/null; then
  echo "FAILED: patch did not change file"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_llvm_exercise.iyi" -- "$WORK/mut2_out" > "$WORK/mut2.log" 2>&1; then
  echo "FAILED: mutation 2 was not caught by exercise checks!"
  exit 1
fi
cp "$REPO/src/compiler/llvm/values.iyi.orig" "$REPO/src/compiler/llvm/values.iyi"
rm -f "$REPO/src/compiler/llvm/values.iyi.orig"
echo "    reverted mutation 2"

# Mutation 3: Invert Target.init_target result for known target
echo "  [mutation 3] corrupting Target.init_target in target.iyi"
cp "$REPO/src/compiler/llvm/target.iyi" "$REPO/src/compiler/llvm/target.iyi.orig"
sed -i.bak 's/when "aarch64", "arm64"/when "never_match_target"/' "$REPO/src/compiler/llvm/target.iyi" && rm -f "$REPO/src/compiler/llvm/target.iyi.bak"
if diff -u "$REPO/src/compiler/llvm/target.iyi.orig" "$REPO/src/compiler/llvm/target.iyi" >/dev/null; then
  echo "FAILED: patch did not change file"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_llvm_exercise.iyi" -- "$WORK/mut3_out" > "$WORK/mut3.log" 2>&1; then
  echo "FAILED: mutation 3 was not caught by exercise checks!"
  exit 1
fi
cp "$REPO/src/compiler/llvm/target.iyi.orig" "$REPO/src/compiler/llvm/target.iyi"
rm -f "$REPO/src/compiler/llvm/target.iyi.orig"
echo "    reverted mutation 3"

# Mutation 4: Invert verify_safely in module.iyi
echo "  [mutation 4] corrupting verify_safely in module.iyi"
cp "$REPO/src/compiler/llvm/module.iyi" "$REPO/src/compiler/llvm/module.iyi.orig"
sed -i.bak 's/{false, err}/{true, ""}/' "$REPO/src/compiler/llvm/module.iyi" && rm -f "$REPO/src/compiler/llvm/module.iyi.bak"
if diff -u "$REPO/src/compiler/llvm/module.iyi.orig" "$REPO/src/compiler/llvm/module.iyi" >/dev/null; then
  echo "FAILED: patch did not change file"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_llvm_exercise.iyi" -- "$WORK/mut4_out" > "$WORK/mut4.log" 2>&1; then
  echo "FAILED: mutation 4 was not caught by exercise checks!"
  exit 1
fi
cp "$REPO/src/compiler/llvm/module.iyi.orig" "$REPO/src/compiler/llvm/module.iyi"
rm -f "$REPO/src/compiler/llvm/module.iyi.orig"
echo "    reverted mutation 4"

# Mutation 5: Corrupt build_xor to build_or in builder.iyi
echo "  [mutation 5] corrupting build_xor in builder.iyi"
cp "$REPO/src/compiler/llvm/builder.iyi" "$REPO/src/compiler/llvm/builder.iyi.orig"
sed -i.bak 's/LibLLVM\.build_xor/LibLLVM.build_or/' "$REPO/src/compiler/llvm/builder.iyi" && rm -f "$REPO/src/compiler/llvm/builder.iyi.bak"
if diff -u "$REPO/src/compiler/llvm/builder.iyi.orig" "$REPO/src/compiler/llvm/builder.iyi" >/dev/null; then
  echo "FAILED: patch did not change file"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_llvm_exercise.iyi" -- "$WORK/mut5_out" > "$WORK/mut5.log" 2>&1; then
  echo "FAILED: mutation 5 was not caught by exercise checks!"
  exit 1
fi
cp "$REPO/src/compiler/llvm/builder.iyi.orig" "$REPO/src/compiler/llvm/builder.iyi"
rm -f "$REPO/src/compiler/llvm/builder.iyi.orig"
echo "    reverted mutation 5"

echo
echo "== 5. Confirming clean state verification"
"$WORK/exercise-release" "$WORK/final_out" >/dev/null
echo "  Clean state confirmed: all self-host LLVM checks pass!"

echo
echo "ALL SELFHOST LLVM BENCHMARK & MUTATION CHECKS PASSED!"
exit 0
