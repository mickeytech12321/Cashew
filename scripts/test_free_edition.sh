#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../budget"
PUB_CACHE="$(mktemp -d)"
export PUB_CACHE
trap 'rm -rf -- "$PUB_CACHE"' EXIT
flutter pub get

python3 ../scripts/prepare_flutter_compat.py test

flutter test "$@"
