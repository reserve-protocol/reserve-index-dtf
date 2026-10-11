#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

configs=(
    "$SCRIPT_DIR/../confs/folio_prerequisities.conf"
    "$SCRIPT_DIR/../confs/properties/"*.conf
)

"$SCRIPT_DIR/run-with-patch.sh" "${configs[@]}"
