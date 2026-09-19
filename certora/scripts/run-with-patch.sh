#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)

if (( $# == 0 )); then
    echo "Usage: $0 <config.conf> [<config.conf> ...]" >&2
    exit 1
fi

PATCH_FILE="$ROOT_DIR/certora/patches/Folio.patch"
PATCH_APPLIED=false

cleanup() {
    if [[ $PATCH_APPLIED == true ]]; then
        git -C "$ROOT_DIR" apply --reverse "$PATCH_FILE"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if git -C "$ROOT_DIR" apply --check "$PATCH_FILE"; then
    git -C "$ROOT_DIR" apply "$PATCH_FILE"
    PATCH_APPLIED=true
elif ! git -C "$ROOT_DIR" apply --reverse --check "$PATCH_FILE"; then
    echo "Folio.patch cannot be applied cleanly." >&2
    exit 1
fi

for config in "$@"; do
    "$ROOT_DIR/certora/scripts/run-prover.sh" "$config"
done
