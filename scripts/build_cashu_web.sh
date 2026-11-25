#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
cashu_flutter_version=3.50.1

if ! command -v flutter >/dev/null; then
  cashu_flutter_dir="${TMPDIR:-/tmp}/cashu-flutter-${cashu_flutter_version}"
  if [[ ! -x "$cashu_flutter_dir/bin/flutter" ]]; then
    git clone --quiet --depth 1 --branch "$cashu_flutter_version" \
      https://github.com/flutter/flutter.git "$cashu_flutter_dir"
  fi
  export PATH="$cashu_flutter_dir/bin:$PATH"
fi

# A fresh Flutter install prints tool and dependency setup before the JSON.
cashu_installed_version="$(flutter --version --machine | python3 -c '
import json
import re
import sys

output = sys.stdin.read()
match = re.search(r"^\s*\{(?=\s*\"frameworkVersion\")", output, re.M)
if match is None:
    sys.exit("Could not read the Flutter version.")
version, _ = json.JSONDecoder().raw_decode(output, match.end() - 1)
print(version["frameworkVersion"])
')"
if [[ "$cashu_installed_version" != "$cashu_flutter_version" ]]; then
  echo "CashU requires Flutter $cashu_flutter_version (found $cashu_installed_version)." >&2
  exit 1
fi

cd budget
if [[ "${1:-}" != "--no-pub" ]]; then
  flutter pub get --enforce-lockfile
fi
python3 ../scripts/prepare_flutter_compat.py web
cashu_build_args=()
if [[ -n "${CASHEW_GOOGLE_WEB_CLIENT_ID:-}" ]]; then
  cashu_build_args+=(--dart-define="CASHEW_GOOGLE_WEB_CLIENT_ID=$CASHEW_GOOGLE_WEB_CLIENT_ID")
fi
flutter build web --release --no-pub --no-tree-shake-icons --no-wasm-dry-run "${cashu_build_args[@]}"
