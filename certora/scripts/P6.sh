#!/usr/bin/env bash

set -euo pipefail

certora/scripts/run-with-patch.sh \
    certora/confs/properties/P6.conf \
    certora/confs/properties/P6-2.conf
