#!/usr/bin/env bash
set -euo pipefail

# Backwards-compatible wrapper. The main verifier now checks both Isaac Sim and Isaac Lab.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/verify_develop_install.sh" "$@"
