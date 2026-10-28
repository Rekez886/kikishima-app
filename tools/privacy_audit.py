#!/usr/bin/env python3
"""Fail if tracked files contain likely secrets, personal paths or local-only files.

This is a gate, not a full privacy review. Add project-specific names to
`LOCAL_PATTERNS` before publishing a fork.
"""
from pathlib import Path
import re
import subprocess
import sys

# Add maintainer names, handles or private domains here before a release.
LOCAL_PATTERNS = [
    # r"your-personal-name",
    # r"your-private-domain\.example",
]

PATTERNS = {
    # Exempt only the documented fixture user names example and example2.
    "local user path": re.compile(r"/(?:Users|home)/(?!example2?(?![A-Za-z0-9._-]))[A-Za-z0-9._-]+"),
    "private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "OpenAI-style key": re.compile(r"sk-[A-Za-z0-9_-]{20,}"),
    "GitHub token": re.compile(r"(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}"),
    "AWS key": re.compile(r"AKIA[0-9A-Z]{16}"),
    "Slack token": re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
    "Cloudflare workers subdomain": re.compile(r"[A-Za-z0-9-]+\.workers\.dev"),
}
SENSITIVE_FILES = re.compile(
    r"(?:^|/)(?:r2\.env|\.env|.*\.(?:pem|p12|pfx|key|mobileprovision|provisionprofile))$",
    re.IGNORECASE,
)


def tracked_files() -> list[str]:
    return subprocess.check_output(["git", "ls-files"], text=True).splitlines()


def main() -> int:
    problems: list[str] = []
    for name in tracked_files():
        if SENSITIVE_FILES.search(name):
            problems.append(f"{name}: sensitive file type")
            continue
        path = Path(name)
        try:
            if path.stat().st_size > 2_000_000:
                continue
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    problems.append(f"{name}:{line_no}: {label}")
            for pattern in LOCAL_PATTERNS:
                if re.search(pattern, line, re.IGNORECASE):
                    problems.append(f"{name}:{line_no}: local pattern")
    if problems:
        print("Privacy audit failed:")
        for problem in problems:
            print("  " + problem)
        return 1
    print(f"Privacy audit passed: {len(tracked_files())} tracked files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
