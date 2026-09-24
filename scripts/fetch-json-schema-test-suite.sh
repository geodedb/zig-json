#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fetch the official JSON-Schema-Test-Suite into testdata/JSON-Schema-Test-Suite
# at the commit `zig build test-schema` runs against. The suite is not
# vendored, and it is pinned so a compromised or retargeted upstream `main`
# cannot silently change what the schema suite validates against (ASR-025).
# CI (test:json-schema-suite in .gitlab-ci.yml) runs this script too.
set -euo pipefail

SUITE_URL=https://github.com/json-schema-org/JSON-Schema-Test-Suite.git
SUITE_SHA=fe8c2f0de2041943975932b6bf4bd882625b6cfb
DEST=testdata/JSON-Schema-Test-Suite

cd "$(dirname "$0")/.."
if [ ! -e "$DEST/.git" ]; then
    git clone --filter=blob:none --no-checkout "$SUITE_URL" "$DEST"
fi
git -C "$DEST" checkout --quiet "$SUITE_SHA"
echo "JSON-Schema-Test-Suite at $SUITE_SHA in $DEST"
