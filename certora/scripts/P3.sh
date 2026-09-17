#!/usr/bin/env bash

set -euo pipefail

certora/scripts/run-with-patch.sh \
    certora/confs/properties/P3-1.conf \
    certora/confs/properties/P3-2.conf
