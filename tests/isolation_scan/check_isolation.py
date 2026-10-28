#!/usr/bin/env python3
"""Conservative source guard for Swift test isolation; no test code is executed."""

from pathlib import Path
import argparse
import re
import sys


FORBIDDEN = (
    ("shared defaults", r"\bUserDefaults\s*\.\s*standard\b"),
    ("legacy shared defaults", r"\bstandardUserDefaults\b"),
    ("system trash directory", r"\.\s*trashDirectory\b"),
    ("home trash path", r"/\.Trash\b"),
    ("home path function", r"\bNSHomeDirectory\b"),
    ("home directory property", r"\bhomeDirectoryForCurrentUser\b"),
    ("pasteboard", r"\bNSPasteboard\b"),
    ("sound", r"\bNSSound\b"),
    ("beep", r"\bNSBeep\b"),
    ("audio player", r"\bAVAudioPlayer\b"),
    ("calendar store", r"\bEKEventStore\s*(?:\.\s*init\s*)?\("),
)


def structural_source(source):
    """Blank comments and strings, retaining offsets and newlines for diagnostics.

    Swift nested block comments, raw/multiline strings and interpolated strings
    are handled here. Forbidden spellings are also checked in the original text.
    """
    result = list(source)

    def blank(start, end):
        for index in range(start, end):
            if result[index] != "\n":
                result[index] = " "

    def comment_end(start):
        if source.startswith("//", start):
            end = source.find("\n", start)
            return len(source) if end < 0 else end
        depth, index = 1, start + 2
        while index < len(source) and depth:
            if source.startswith("/*", index):
                depth += 1
                index += 2
            elif source.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        return index

    def string_end(start):
        opener = re.match(r'(#*)(' + '"""|"' + r')', source[start:])
        if not opener:
            return None
        hashes, quotes = opener.groups()
        ending, escape = quotes + hashes, "\\" + hashes
        index = start + len(opener.group())
        while index < len(source):
            if source.startswith(ending, index):
                return index + len(ending)
            if source.startswith(escape, index):
                index += len(escape)
                if index < len(source) and source[index] == "(":
                    depth, index = 1, index + 1
                    while index < len(source) and depth:
                        if source.startswith(("//", "/*"), index):
                            index = comment_end(index)
                            continue
                        nested_end = string_end(index)
                        if nested_end is not None:
                            index = nested_end
                            continue
                        depth += (source[index] == "(") - (source[index] == ")")
                        index += 1
                else:
                    index += 1
            else:
                index += 1
        return len(source)

    index = 0
    while index < len(source):
        if source.startswith(("//", "/*"), index):
            end = comment_end(index)
        else:
            end = string_end(index)
        if end is None:
            index += 1
        else:
            blank(index, end)
            index = end
    return "".join(result)


def closing_index(source, opening):
    pairs = {"(": ")", "[": "]", "{": "}"}
    if opening >= len(source) or source[opening] not in pairs:
        return None
    stack = []
    for index in range(opening, len(source)):
        char = source[index]
        if char in pairs:
            stack.append(pairs[char])
        elif char in ")]}":
            if not stack or char != stack.pop():
                return None
            if not stack:
                return index
    return None


def has_argument(source, opening, closing, label):
    """Only labels on this call count, never labels in nested calls/closures."""
    index = opening + 1
    while index < closing:
        match = re.match(r"\s*" + re.escape(label) + r"\s*:", source[index:closing])
        if match:
            return True
        while index < closing:
            if source[index] in "([{":
                end = closing_index(source, index)
                if end is None:
                    return False
                index = end + 1
            elif source[index] == ",":
                index += 1
                break
            else:
                index += 1
    return False


def has_trailing_closure(source, call_start, closing):
    if not re.match(r"\s*\{", source[closing + 1:]):
        return False
    # A control-flow body's opening brace is not an injected closure. Track
    # pending headers at each delimiter depth, including multiline conditions.
    # Explicit parentheses around a closure-bearing expression disambiguate it.
    headers = [False]
    pattern = r"\b(?:if|guard|while|for|switch|catch)\b|[(){}\[\];]"
    for match in re.finditer(pattern, source[:call_start]):
        part = match.group()
        if part in ("(", "["):
            headers.append(False)
        elif part == "{":
            headers[-1] = False
            headers.append(False)
        elif part in (")", "]", "}"):
            if len(headers) > 1:
                headers.pop()
        elif part == ";":
            headers[-1] = False
        else:
            headers[-1] = True
    return not headers[-1]


def trash_override_ranges(source):
    classes = []
    for match in re.finditer(r"\bclass\s+\w+[^{}]*\{", source):
        opening = match.end() - 1
        closing = closing_index(source, opening)
        if closing is not None:
            is_manager = bool(re.search(r":\s*(?:Foundation\s*\.\s*)?FileManager\b", match.group()))
            classes.append((opening, closing, is_manager))
    ranges = []
    for match in re.finditer(r"\boverride\s+func\s+trashItem\s*\(", source):
        closing = closing_index(source, match.end() - 1)
        if closing is None:
            continue
        body = re.match(r"\s*(?:throws\s*)?\{", source[closing + 1:])
        if not body:
            continue
        opening = closing + body.end()
        end = closing_index(source, opening)
        owners = [item for item in classes if item[0] < match.start() < item[1]]
        if end is not None and owners and max(owners)[2]:
            ranges.append((opening, end))
    return ranges


def violations(source):
    errors = []
    structure = structural_source(source)

    def reject(index, reason):
        errors.append((source.count("\n", 0, index) + 1, reason))

    def matches(pattern):
        # Keep raw matches for interpolation and path strings, plus masked
        # matches so inserted comments cannot hide a call or member access.
        found = {}
        for variant in (source, structure):
            for match in re.finditer(pattern, variant):
                found[(match.start(), match.end())] = match
        return found.values()

    # Deliberately conservative: forbidden API spellings in comments or strings
    # also fail. This includes executable code inside string interpolation.
    for reason, pattern in FORBIDDEN:
        for match in matches(pattern):
            reject(match.start(), reason)

    overrides = trash_override_ranges(structure)
    for match in matches(r"\.\s*trashItem\s*\("):
        if not any(start < match.start() < end for start, end in overrides):
            reject(match.start(), "trashItem call outside a FileManager override")

    for name, label, reason in (
        ("UserDefaults", "suiteName", "defaults construction without suiteName"),
        ("MeetingSummaryStore", "trashItem", "summary store without injected trashItem"),
    ):
        pattern = r"\b" + name + r"\s*(?:\.\s*init\s*)?\("
        for match in matches(pattern):
            opening = match.end() - 1
            closing = closing_index(structure, opening)
            if closing is None:
                reject(match.start(), reason)
                continue
            if has_argument(structure, opening, closing, label):
                continue
            if name == "MeetingSummaryStore" and has_trailing_closure(structure, match.start(), closing):
                continue
            reject(match.start(), reason)
    return sorted(errors)


def self_test():
    bad = [
        ("shared defaults", "let d = UserDefaults.standard"),
        ("shared defaults", "let d = UserDefaults /* comment */ . standard"),
        ("legacy shared defaults", "let d = standardUserDefaults()"),
        ("defaults construction without suiteName", "let d = UserDefaults()"),
        ("defaults construction without suiteName", "let d = UserDefaults.init()"),
        ("defaults construction without suiteName", "let d = UserDefaults(other(suiteName: name))"),
        ("trashItem call outside a FileManager override", "try manager.trashItem(at: url, resultingItemURL: nil)"),
        ("system trash directory", "let d = FileManager.SearchPathDirectory.trashDirectory"),
        ("home trash path", 'let d = "/.Trash/item"'),
        ("home path function", "let d = NSHomeDirectory()"),
        ("home directory property", "let d = manager.homeDirectoryForCurrentUser"),
        ("pasteboard", "let p = NSPasteboard.general"),
        ("sound", "let s = NSSound()"),
        ("beep", "NSBeep()"),
        ("audio player", "let a = AVAudioPlayer()"),
        ("calendar store", "let c = EKEventStore()"),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore()"),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore /* comment */ ()"),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore(fileManager: manager)"),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore(fileManager: make(trashItem: operation))"),
        ("summary store without injected trashItem", 'let s = MeetingSummaryStore(fileManager: make("trashItem:"))'),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore(/* trashItem: fake */)"),
        ("summary store without injected trashItem", "let s = MeetingSummaryStore(); run { _ in nil }"),
        ("summary store without injected trashItem", "switch MeetingSummaryStore() { default: break }"),
        ("summary store without injected trashItem", "if case let store = MeetingSummaryStore() { print(store) }"),
        ("summary store without injected trashItem", "if case let store =\n MeetingSummaryStore()\n { print(store) }"),
        ("summary store without injected trashItem", "while case let store = MeetingSummaryStore() { print(store) }"),
        ("summary store without injected trashItem", "for store in MeetingSummaryStore() { print(store) }"),
        ("trashItem call outside a FileManager override", "class Other { override func trashItem(at: URL, resultingItemURL: Any) { try manager.trashItem(at: url) } }"),
        ("trashItem call outside a FileManager override", "class Mock: FileManager { func helper() { try manager.trashItem(at: url) } }"),
    ]
    for expected, source in bad:
        if expected not in [reason for _, reason in violations(source)]:
            raise AssertionError(f"Self-test missed: {expected}")
    good = [
        'let d = UserDefaults(suiteName: "isolated")',
        "let s = MeetingSummaryStore(trashItem: operation)",
        "let s = MeetingSummaryStore(fileManager: make(nested: [1, 2]), trashItem: { _ in nil })",
        "let s = MeetingSummaryStore(fileManager: manager) /* closure */ { _ in nil }",
        "let s = MeetingSummaryStore() { _ in nil }",
        "if case let store = (MeetingSummaryStore() { _ in nil }) { print(store) }",
        "switch (MeetingSummaryStore() { _ in nil }) { default: break }",
        "if case let store = MeetingSummaryStore(trashItem: { _ in nil }) { print(store) }",
        "if true { let store = MeetingSummaryStore() { _ in nil } }",
        'let s = MeetingSummaryStore(fileManager: make(#"(,})"#)) { _ in nil }',
        'let s = MeetingSummaryStore(fileManager: make("value \\(join(\"(\"))")) { _ in nil }',
        'let s = MeetingSummaryStore(fileManager: make("""\n( } )\n""")) { _ in nil }',
        "let s = MeetingSummaryStore(/* outer /* nested */ comment */ trashItem: { _ in nil })",
        "final class Mock: FileManager { override func trashItem(at url: URL, resultingItemURL result: Any) throws { try delegate.trashItem(at: url) } }",
    ]
    for source in good:
        if violations(source):
            raise AssertionError(f"Self-test rejected an isolated fixture: {violations(source)}")
    print(f"PASS: isolation scan self-test ({len(bad)} rejected, {len(good)} accepted)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    root = Path(__file__).resolve().parents[2]
    paths = sorted((root / "tests").rglob("*.swift"))
    failures = 0
    for path in paths:
        for line, reason in violations(path.read_text(encoding="utf-8")):
            print(f"{path.relative_to(root)}:{line}: {reason}", file=sys.stderr)
            failures += 1
    if not paths:
        print("No Swift tests found", file=sys.stderr)
        return 1
    if failures:
        return 1
    print(f"PASS: isolation scan ({len(paths)} Swift files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
