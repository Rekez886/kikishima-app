#!/usr/bin/env python3
"""Pull the live Sparkle appcast with a Cloudflare-safe User-Agent."""

import sys
import urllib.request
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: pull_appcast.py URL OUTPUT")

    request = urllib.request.Request(
        sys.argv[1], headers={"User-Agent": "Kikishima-release/1.0"}
    )
    try:
        data = urllib.request.urlopen(request, timeout=15).read()
        if b"<rss" not in data:
            raise ValueError("response is not an RSS appcast")
        Path(sys.argv[2]).write_bytes(data)
        print("appcast: pulled live copy")
    except Exception as error:
        print("appcast: live copy unavailable,", error)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
