#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

cd "$repo_root"
docker compose up -d emulate

cd "$repo_root/NativeApp"
INBOX_ZERO_EMULATE=1 exec npx --yes @native-sdk/cli@0.5.3 dev . --yes "$@"
