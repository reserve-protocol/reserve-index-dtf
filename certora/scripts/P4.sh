#!/usr/bin/env bash

set -euo pipefail

certora/scripts/run-with-patch.sh \
    certora/confs/properties/P4-1.conf \
    certora/confs/properties/P4-2.conf \
    certora/confs/properties/P4-3.conf
