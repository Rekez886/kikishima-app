#!/usr/bin/env python3
"""Verify that a packaged Chrome extension contains its runtime dependencies."""

import json
import posixpath
import sys
import zipfile
from html.parser import HTMLParser


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script" and values.get("src"):
            self.paths.append(values["src"])
        if tag == "link" and values.get("href"):
            self.paths.append(values["href"])


def add_icon_paths(required, value):
    if isinstance(value, str):
        required.add(value)
    elif isinstance(value, dict):
        required.update(value.values())


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_extension_zip.py EXTENSION.zip")

    with zipfile.ZipFile(sys.argv[1]) as archive:
        names = set(archive.namelist())
        manifest = json.loads(archive.read("manifest.json"))
        required = {"manifest.json"}

        background = manifest.get("background", {})
        if background.get("service_worker"):
            required.add(background["service_worker"])

        action = manifest.get("action", {})
        popup = action.get("default_popup")
        if popup:
            required.add(popup)
        add_icon_paths(required, action.get("default_icon"))
        add_icon_paths(required, manifest.get("icons"))

        for script in manifest.get("content_scripts", []):
            required.update(script.get("js", []))
            required.update(script.get("css", []))

        missing = sorted(required - names)
        if missing:
            raise SystemExit("extension zip missing manifest files: " + ", ".join(missing))

        if popup:
            parser = AssetParser()
            parser.feed(archive.read(popup).decode("utf-8"))
            base = posixpath.dirname(popup)
            for path in parser.paths:
                if "://" in path or path.startswith(("data:", "#", "/")):
                    continue
                required.add(posixpath.normpath(posixpath.join(base, path)))

        missing = sorted(required - names)
        if missing:
            raise SystemExit("extension zip missing referenced files: " + ", ".join(missing))

    print(f"extension zip: {len(required)} runtime files present")


if __name__ == "__main__":
    main()
