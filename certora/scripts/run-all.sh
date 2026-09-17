#!/usr/bin/env bash

set -euo pipefail

configs=(
    certora/confs/folio_prerequisities.conf
    certora/confs/properties/*.conf
)

certora/scripts/run-with-patch.sh "${configs[@]}"
