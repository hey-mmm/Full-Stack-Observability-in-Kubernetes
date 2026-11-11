#!/usr/bin/env bash
# Explicitly rebuild the two monitoring Pods; PVCs are retained.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/persistence.py" "$@"
