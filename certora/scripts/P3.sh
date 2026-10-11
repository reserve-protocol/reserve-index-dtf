#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

"$SCRIPT_DIR/run-with-patch.sh" \
    "$SCRIPT_DIR/../confs/properties/P3-1.conf" \
    "$SCRIPT_DIR/../confs/properties/P3-2.conf"
