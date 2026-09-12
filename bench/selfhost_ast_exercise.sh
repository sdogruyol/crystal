#!/usr/bin/env bash
# Exercises the self-hosting compiler AST model, visitor, transformer, and out-of-band NodeMap side storage.
#
#   bash bench/selfhost_ast_exercise.sh
#
# Verifies:
# 1. Plain compilation and execution of selfhost AST exercise
# 2. --release compilation and execution
# 3. Complete coverage of all 104 concrete AST node kinds across:
#    - Construction
#    - Cloning (with location, end_location, doc, visibility, and instance identity isolation)
#    - Structural equality and hash distribution
#    - to_s string formatting
# 4. Visitor and ToSVisitor traversal
# 5. Transformer framework tree modification
# 6. Out-of-band NodeMap side storage without reopening node types
# 7. Guarded mutation proofs verifying that test checks catch injected AST/visitor/transformer defects
#
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
IYI="$REPO/bin/iyi"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

status=0

echo "== 1. Building and running selfhost AST exercise (plain mode)"
"$IYI" build -o "$WORK/exercise-plain" "$REPO/bench/selfhost_ast_exercise.iyi"
"$WORK/exercise-plain" > "$WORK/plain.out" 2>&1
cat "$WORK/plain.out"

echo
echo "== Checking reported verification counts in plain mode"
for phrase in \
  "testing construction of all 104 concrete AST node kinds... ok (104 node kinds constructed)" \
  "testing cloning for all 104 concrete AST node kinds... ok (104 node kinds cloned with location and identity isolation)" \
  "testing equality and hashing for all 104 concrete AST node kinds... ok (104 node kinds verified for structural equality and hashing)" \
  "testing to_s string formatting for all 104 concrete AST node kinds... ok (104 node kinds verified for to_s formatting)" \
  "testing Visitor and ToSVisitor traversal... ok (visitor traversal and ToSVisitor formatting verified)" \
  "testing Transformer framework... ok (transformer tree modification verified)" \
  "testing out-of-band NodeMap side storage (no reopening of node types)... ok (NodeMap out-of-band side storage verified)" \
  "ALL SELFHOST AST CHECKS PASSED SUCCESSFULLY!"; do
  # Join the exercise's two-line "testing ... ok (...)" pair before matching.
  joined="$(tr '\n' ' ' < "$WORK/plain.out")"
  if ! grep -qF "$phrase" <<< "$joined"; then
    echo "FAIL: Missing verification phrase in plain output:"
    echo "  $phrase"
    status=1
  fi
done

echo
echo "== 2. Building and running selfhost AST exercise (--release mode)"
"$IYI" build --release -o "$WORK/exercise-release" "$REPO/bench/selfhost_ast_exercise.iyi"
"$WORK/exercise-release" > "$WORK/release.out" 2>&1
cat "$WORK/release.out"

if ! grep -qF "ALL SELFHOST AST CHECKS PASSED SUCCESSFULLY!" "$WORK/release.out"; then
  echo "FAIL: selfhost AST exercise did not complete successfully in release mode"
  status=1
fi

echo
echo "== 3. Guarded mutation proofs (verify patch applies, exercise fails, revert passes)"

# Mutation 1: Alter ASTNode#clone to drop doc preservation
echo "  [mutation 1] altering ASTNode#clone doc preservation"
cp "$REPO/src/compiler/syntax/ast.iyi" "$REPO/src/compiler/syntax/ast.iyi.orig"
sed -i.bak 's/c[.]doc[ ]*=[ ]*@doc/c.doc = nil/' "$REPO/src/compiler/syntax/ast.iyi" && rm -f "$REPO/src/compiler/syntax/ast.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi" >/dev/null; then
  echo "FAIL: mutation 1 patch did not apply"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi" > "$WORK/mut1.log" 2>&1; then
  echo "FAIL: selfhost AST exercise succeeded despite corrupted clone doc"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi"
rm -f "$REPO/src/compiler/syntax/ast.iyi.orig"
echo "    reverted mutation 1"

# Mutation 2: Alter Var#== structural equality
echo "  [mutation 2] altering Var#== structural equality"
cp "$REPO/src/compiler/syntax/ast.iyi" "$REPO/src/compiler/syntax/ast.iyi.orig"
sed -i.bak 's/(@name[ ]*==[ ]*other[.]name)/false/' "$REPO/src/compiler/syntax/ast.iyi" && rm -f "$REPO/src/compiler/syntax/ast.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi" >/dev/null; then
  echo "FAIL: mutation 2 patch did not apply"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi" > "$WORK/mut2.log" 2>&1; then
  echo "FAIL: selfhost AST exercise succeeded despite corrupted Var equality"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi"
rm -f "$REPO/src/compiler/syntax/ast.iyi.orig"
echo "    reverted mutation 2"

# Mutation 3: Alter NodeMap#[]= side storage assignment
echo "  [mutation 3] altering NodeMap#[]= key storage"
cp "$REPO/src/compiler/syntax/ast.iyi" "$REPO/src/compiler/syntax/ast.iyi.orig"
sed -i.bak 's/@store\[node[.]node_id\][ ]*=[ ]*value/@store[0_u64] = value/' "$REPO/src/compiler/syntax/ast.iyi" && rm -f "$REPO/src/compiler/syntax/ast.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi" >/dev/null; then
  echo "FAIL: mutation 3 patch did not apply"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi" > "$WORK/mut3.log" 2>&1; then
  echo "FAIL: selfhost AST exercise succeeded despite corrupted NodeMap"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/ast.iyi.orig" "$REPO/src/compiler/syntax/ast.iyi"
rm -f "$REPO/src/compiler/syntax/ast.iyi.orig"
echo "    reverted mutation 3"

# Mutation 4: Alter Transformer#transform(Assign) target transformation
echo "  [mutation 4] altering Transformer#transform(Assign) target recursion"
cp "$REPO/src/compiler/syntax/transformer.iyi" "$REPO/src/compiler/syntax/transformer.iyi.orig"
sed -i.bak 's/node[.]target[ ]*=[ ]*node[.]target[.]transform(self)/# node.target bypassed/' "$REPO/src/compiler/syntax/transformer.iyi" && rm -f "$REPO/src/compiler/syntax/transformer.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/transformer.iyi.orig" "$REPO/src/compiler/syntax/transformer.iyi" >/dev/null; then
  echo "FAIL: mutation 4 patch did not apply"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi" > "$WORK/mut4.log" 2>&1; then
  echo "FAIL: selfhost AST exercise succeeded despite corrupted transformer"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/transformer.iyi.orig" "$REPO/src/compiler/syntax/transformer.iyi"
rm -f "$REPO/src/compiler/syntax/transformer.iyi.orig"
echo "    reverted mutation 4"

# Mutation 5: Alter ToSVisitor#visit(Assign) formatting
echo "  [mutation 5] altering ToSVisitor#visit(Assign) formatting"
cp "$REPO/src/compiler/syntax/visitor.iyi" "$REPO/src/compiler/syntax/visitor.iyi.orig"
sed -i.bak 's/node[.]to_s(@sb)/@sb << "mutated"/' "$REPO/src/compiler/syntax/visitor.iyi" && rm -f "$REPO/src/compiler/syntax/visitor.iyi.bak"
if diff -u "$REPO/src/compiler/syntax/visitor.iyi.orig" "$REPO/src/compiler/syntax/visitor.iyi" >/dev/null; then
  echo "FAIL: mutation 5 patch did not apply"
  exit 1
fi
echo "    patch verified applied in working tree"
if "$IYI" run "$REPO/bench/selfhost_ast_exercise.iyi" > "$WORK/mut5.log" 2>&1; then
  echo "FAIL: selfhost AST exercise succeeded despite corrupted ToSVisitor formatting"
  status=1
else
  echo "    mutation caught: exercise failed as expected"
fi
cp "$REPO/src/compiler/syntax/visitor.iyi.orig" "$REPO/src/compiler/syntax/visitor.iyi"
rm -f "$REPO/src/compiler/syntax/visitor.iyi.orig"
echo "    reverted mutation 5"

echo
echo "== Verification clean state confirmed"
"$WORK/exercise-release" >/dev/null

echo
if [ "$status" -eq 0 ]; then
  echo "PASS: selfhost AST exercise and mutation suite passed cleanly"
else
  echo "FAIL: selfhost AST exercise had failures"
fi

exit $status
