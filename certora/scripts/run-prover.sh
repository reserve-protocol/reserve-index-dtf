#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
TOOLS_DIR=${CERTORA_TOOLS_DIR:-"$ROOT_DIR/.certora"}

if [[ ! -x $TOOLS_DIR/prover/certoraRun.py ]]; then
    echo "Local CertoraProver is not installed. Run ./certora/scripts/setup-local-prover.sh first." >&2
    exit 1
fi

export CERTORA="$TOOLS_DIR/prover"
export JAVA_HOME="$TOOLS_DIR/jdk"
export PATH="$JAVA_HOME/bin:$CERTORA:$TOOLS_DIR/bin:$PATH"

cd "$ROOT_DIR"
exec "$TOOLS_DIR/venv/bin/python" "$CERTORA/certoraRun.py" "$@"
