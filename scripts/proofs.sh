#!/usr/bin/env bash
# Checks the Lean proofs in Proofs/ (see Proofs/MAPPING.md): builds them and
# fails if a proof is unfinished or relies on an axiom beyond Lean's
# standard three.
#
# Needs Lean 4.34.0 (`elan` picks it from Proofs/lean-toolchain). No Mathlib.
set -euo pipefail

cd "$(dirname "$0")/../Proofs"

if [[ ! -w ${TMPDIR:-/tmp} ]]; then
    export TMPDIR=$PWD/../.context/tmp
    mkdir -p "$TMPDIR"
fi

if grep -rnwE 'sorry|admit' --include='*.lean' . --exclude-dir=.lake \
    || grep -rnE '^[[:space:]]*(private[[:space:]]+)?axiom[[:space:]]' --include='*.lean' . --exclude-dir=.lake; then
    echo "error: unfinished proof or new axiom" >&2
    exit 1
fi

lake build

axioms=$(lake env lean Axioms.lean)
unexpected=$(grep -vE "does not depend on any axioms|depends on axioms: \[(propext|Classical\.choice|Quot\.sound)(, (propext|Classical\.choice|Quot\.sound))*\]" <<<"$axioms" || true)
if [[ -n $unexpected ]]; then
    echo "error: theorems depend on unexpected axioms:" >&2
    echo "$unexpected" >&2
    exit 1
fi
echo "$(grep -c . <<<"$axioms") theorems checked: no sorry, only standard axioms"
