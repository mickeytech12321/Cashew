#!/usr/bin/env python3
"""Apply narrowly scoped fixes to the resolved Flutter dependency cache."""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET


def package_roots(config):
    packages = json.loads(config.read_text())["packages"]
    for package in packages:
        uri = urlparse(package["rootUri"])
        path = Path(unquote(uri.path))
        if uri.scheme == "file":
            yield package["name"], path
        elif not uri.scheme:
            yield package["name"], (config.parent / path).resolve()


def patch_layout(root):
    for name in ("value_layout_builder.dart", "sliver_value_layout_builder.dart"):
        path = root / "lib" / "src" / name
        original = path.read_text()
        if "rebuildIfNecessary();" not in original:
            continue
        patched, count = re.subn(
            r"(RenderObjectWithChildMixin<[^>]+>\s*,)",
            r"\1 RenderObjectWithLayoutCallbackMixin,",
            original.replace("rebuildIfNecessary();", "runLayoutCallback();"),
        )
        if count == 0:
            raise RuntimeError(f"Layout callback declaration changed in {path}")
        path.write_text(patched)
        print(f"Patched {path}")


def patch_android(name, android):
    if not android.is_dir():
        return
    for path in sorted(android.rglob("*")):
        if path.suffix not in (".gradle", ".kts") or not path.is_file():
            continue
        original = path.read_text()
        patched = re.sub(r"\bjcenter\s*\(\s*\)", "mavenCentral()", original)
        if path == android / "build.gradle" and not re.search(r"\bnamespace\b", patched):
            manifest = android / "src/main/AndroidManifest.xml"
            namespace = ET.parse(manifest).getroot().get("package") if manifest.is_file() else None
            if not namespace:
                namespace = f"dev.cashew.legacy.{name}"
            if not re.fullmatch(r"[A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)+", namespace):
                raise RuntimeError(f"Invalid Android namespace in {path}")
            patched += f'\nandroid {{ namespace "{namespace}" }}\n'
        if (path == android / "build.gradle.kts" and "kotlin {" in patched
                and "org.jetbrains.kotlin.android" not in patched
                and 'kotlin("android")' not in patched):
            if "plugins {" not in patched:
                raise RuntimeError(f"Kotlin extension without a plugins block in {path}")
            patched = patched.replace(
                "plugins {", 'plugins {\n    id("org.jetbrains.kotlin.android")', 1,
            )
        if patched != original:
            path.write_text(patched)
            print(f"Patched {path}")


def patch_web(packages):
    legacy_sqlite = packages["sqlite3"] / "lib/src/wasm/js_interop/file_system_access.dart"
    if not legacy_sqlite.is_file() or "extension type LegacySyncFileHandle" not in legacy_sqlite.read_text():
        return
    drift = packages["drift"] / "lib/src/web/wasm_setup/shared.dart"
    if not drift.is_file():
        return
    original = drift.read_text()
    patched = original.replace(
        "callMethod<Object?>(openedFile, 'getSize', []);",
        "callMethod<Object?>(openedFile.inner as Object, 'getSize', []);",
    )
    if original != patched:
        drift.write_text(patched)
        print(f"Patched {drift}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("test", "android", "web"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    packages = dict(package_roots(root / "budget/.dart_tool/package_config.json"))
    patch_layout(packages["value_layout_builder"])
    if args.platform == "android":
        for name, package in sorted(packages.items()):
            if name != "budget":
                patch_android(name, package / "android")
    elif args.platform == "web":
        patch_web(packages)


if __name__ == "__main__":
    main()
