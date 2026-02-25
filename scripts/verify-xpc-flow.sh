#!/usr/bin/env bash
set -euo pipefail

echo "scripts/verify-xpc-flow.sh is deprecated. Running pure CLI verification instead." >&2
exec "$(cd "$(dirname "$0")" && pwd)/verify-cli-flow.sh" "$@"
