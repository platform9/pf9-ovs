#!/bin/bash
# Copyright (c) 2026 Platform9 Systems Inc.
#
# Fails when packaged source changed but PF9_REVISION was not incremented.
#
# PF9_REVISION is the PF9 package revision: it is the only thing that tells
# apt and dnf that a new build of this component differs from the installed
# one (see PF9_VERSIONING.md). Every change that must reach hosts has to bump it.
#
# Usage: build-aux/pf9-check-revision.sh [base-ref]     (default: origin/main)
# Env:   PF9_REVISION_FILE    counter file (default PF9_REVISION)
#        PF9_REVISION_EXEMPT  ERE of paths that never need a bump
set -euo pipefail

BASE_REF=${1:-origin/main}
REV_FILE=${PF9_REVISION_FILE:-PF9_REVISION}
EXEMPT=${PF9_REVISION_EXEMPT:-'^(\.github/|Documentation/|tests/)|\.(md|rst)$|^PF9_REVISION$'}

cd "$(git rev-parse --show-toplevel)"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$REV_FILE" ] || fail "$REV_FILE is missing"
cur=$(tr -d '[:space:]' < "$REV_FILE")
[[ "$cur" =~ ^[1-9][0-9]*$ ]] || fail "$REV_FILE must hold a positive integer, found '$cur'"

base=$(git merge-base "$BASE_REF" HEAD) || fail "cannot find a merge base with $BASE_REF"
changed=$(git diff --name-only "$base" HEAD | grep -Ev "$EXEMPT" || true)
if [ -z "$changed" ]; then
    echo "OK: no packaged source changed since $BASE_REF ($REV_FILE=$cur)"
    exit 0
fi

old=$(git show "$base:$REV_FILE" 2>/dev/null | tr -d '[:space:]' || true)
if [ -z "$old" ]; then
    echo "OK: $REV_FILE is new (=$cur)"
    exit 0
fi
if [ "$cur" -gt "$old" ]; then
    echo "OK: $REV_FILE bumped $old -> $cur"
    exit 0
fi

echo "$changed" | sed 's/^/    /' >&2
fail "packaged source changed since $BASE_REF but $REV_FILE is still $cur (base: $old). Increment $REV_FILE in this change; builds with an unchanged counter are not upgraded on hosts."
