#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../budget"
PUB_CACHE="$(mktemp -d)"
export PUB_CACHE
trap 'rm -rf -- "$PUB_CACHE"' EXIT
flutter pub get

python3 - <<'PY'
from pathlib import Path
import re
import json
from urllib.parse import unquote, urlparse

config = Path(".dart_tool/package_config.json").resolve()
packages = json.loads(config.read_text())["packages"]
package = next(item for item in packages if item["name"] == "value_layout_builder")
uri = urlparse(package["rootUri"])
root = Path(unquote(uri.path)) if uri.scheme == "file" else config.parent / unquote(uri.path)
files = list(root.glob("lib/src/value_layout_builder.dart"))
files += list(root.glob("lib/src/sliver_value_layout_builder.dart"))
if not files:
    raise RuntimeError("value_layout_builder source not found")
for path in files:
    source = path.read_text()
    if 'RenderObjectWithLayoutCallbackMixin' in source and 'rebuildIfNecessary();' not in source:
        print(f'Already patched {path}')
        continue
    patched = source.replace("rebuildIfNecessary();", "runLayoutCallback();")
    patched, count = re.subn(
        r"(RenderObjectWithChildMixin<[^>]+>\s*,)",
        r"\1 RenderObjectWithLayoutCallbackMixin,",
        patched,
    )
    if count == 0:
        raise RuntimeError(f"No RenderObjectWithChildMixin declaration matched in {path}")
    if patched == source:
        raise RuntimeError(f"No compatibility changes applied to {path}")
    path.write_text(patched)
    print(f"Patched {path}: mixins={count}")
PY

flutter test "$@"
