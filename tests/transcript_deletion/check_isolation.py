#!/usr/bin/env python3
"""Check the transcript test's injected file operations before compiling it."""

import argparse
from pathlib import Path
import re
import sys


FORBIDDEN = (
    ".Trash", ".trashDirectory", "NSHomeDirectory", "homeDirectoryForCurrentUser",
    "UserDefaults", "NSWorkspace", "recycle",
    "NSTemporaryDirectory", "temporaryDirectory",
)


def code_only(source):
    """Blank comments and Swift strings while preserving source offsets."""
    chars = list(source)
    i = 0
    while i < len(source):
        start = i
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = len(source) if end < 0 else end
        elif source.startswith("/*", i):
            i += 2
            depth = 1
            while i < len(source) and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            if depth:
                raise ValueError("Unclosed comment")
        else:
            literal = re.match(r'(#+)?("""|")', source[i:])
            if not literal:
                i += 1
                continue
            hashes = literal.group(1) or ""
            ending = literal.group(2) + hashes
            i += len(literal.group(0))
            while i < len(source):
                if source.startswith(ending, i):
                    i += len(ending)
                    break
                if source.startswith("\\" + hashes, i):
                    i += len(hashes) + 2
                else:
                    i += 1
            else:
                raise ValueError("Unclosed string")
        for j in range(start, i):
            if chars[j] != "\n":
                chars[j] = " "
    return "".join(chars)


def closing(code, start):
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = []
    for i in range(start, len(code)):
        if code[i] in pairs:
            stack.append(pairs[code[i]])
        elif code[i] in pairs.values():
            if not stack or code[i] != stack.pop():
                raise ValueError("Unbalanced delimiters")
            if not stack:
                return i
    raise ValueError("Unclosed delimiter")


def arguments(code):
    parts = []
    start = i = 0
    while i < len(code):
        if code[i] in "([{":
            i = closing(code, i)
        elif code[i] == ",":
            part = code[start:i]
            parts.append((part.strip(), start + len(part) - len(part.lstrip())))
            start = i + 1
        i += 1
    part = code[start:]
    parts.append((part.strip(), start + len(part) - len(part.lstrip())))
    return parts


def check(source):
    errors = [f"Forbidden text: {word}" for word in FORBIDDEN if word in source]
    try:
        code = code_only(source)
        classes = list(re.finditer(
            r"\bfinal\s+class\s+SandboxTrashFileManager\s*:\s*FileManager"
            r"(?:\s*,\s*@unchecked\s+Sendable)?\s*\{", code))
        methods = list(re.finditer(
            r"\boverride\s+func\s+(trashItem)\s*\(\s*at\s+\w+\s*:\s*URL\s*,"
            r"\s*resultingItemURL\s+\w+\s*:\s*AutoreleasingUnsafeMutablePointer"
            r"\s*<\s*NSURL\s*\?\s*>\s*\?\s*\)\s*throws\s*\{", code))
        if len(classes) != 1 or len(methods) != 1:
            errors.append("Require one final SandboxTrashFileManager and its exact override")
        else:
            body_start = classes[0].end() - 1
            body_end = closing(code, body_start)
            method = methods[0]
            before = code[body_start + 1:method.start()]
            if not (body_start < method.start() < body_end) or before.count("{") != before.count("}"):
                errors.append("The override must be a direct member of SandboxTrashFileManager")
            if closing(code, method.end() - 1) > body_end:
                errors.append("The override must stay inside SandboxTrashFileManager")
        allowed_names = {method.start(1) for method in methods}
        for occurrence in re.finditer("trashItem", source):
            if occurrence.start() not in allowed_names:
                errors.append("trashItem may only appear as the sandbox override declaration")

        manager_bindings = list(re.finditer(
            r"\blet\s+(\w+)\s*:\s*SandboxTrashFileManager\s*=\s*SandboxTrashFileManager\s*\(", code))
        managers = {binding.group(1) for binding in manager_bindings}
        allowed_uses = {binding.start(1) for binding in manager_bindings}
        for name in tuple(managers):
            declarations = re.findall(r"\b(?:let|var)\s+" + re.escape(name) + r"\b", code)
            typed_bindings = re.findall(r"\b" + re.escape(name) + r"\s*:", code)
            if len(declarations) != 1 or len(typed_bindings) != 1:
                managers.remove(name)
                errors.append("Sandbox manager bindings must be unique immutable declarations")
        calls = list(re.finditer(r"\btrashTranscript\s*\(", code))
        visible_calls = {call.start() for call in calls}
        for occurrence in re.finditer(r"\btrashTranscript\s*\(", source):
            if occurrence.start() not in visible_calls:
                errors.append("A trashTranscript call must not be hidden in a string or comment")
        if not calls:
            errors.append("Require a trashTranscript call to validate")
        for call in calls:
            end = closing(code, call.end() - 1)
            injected = [(part, offset) for part, offset in arguments(code[call.end():end])
                        if re.match(r"fileManager\s*:", part)]
            binding = re.fullmatch(r"fileManager\s*:\s*(\w+)", injected[0][0]) if len(injected) == 1 else None
            if binding is None or binding.group(1) not in managers:
                line = source.count("\n", 0, call.start()) + 1
                errors.append(f"Line {line}: inject an explicitly typed SandboxTrashFileManager binding")
            else:
                allowed_uses.add(call.end() + injected[0][1] + binding.start(1))
        # This fixed fixture uses managers only in their declarations, injected
        # arguments, and call-count assertions. Reject all other identifier uses
        # instead of attempting Swift name resolution for shadowing bindings.
        for name in managers:
            allowed_uses.update(match.start() for match in re.finditer(
                r"\b" + re.escape(name) + r"\s*\.\s*calls\b", code))
            for occurrence in re.finditer(r"\b" + re.escape(name) + r"\b", code):
                if occurrence.start() not in allowed_uses:
                    errors.append(f"Unrecognized use or shadowing of sandbox manager: {name}")
    except ValueError as error:
        errors.append(str(error))
    return errors


def self_test():
    valid = """
final class SandboxTrashFileManager: FileManager, @unchecked Sendable {
    override func trashItem(at url: URL,
        resultingItemURL result: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {}
}
let isolated: SandboxTrashFileManager = SandboxTrashFileManager(root: root, behavior: .move)
let value = try trashTranscript(at: source, fileManager: isolated)
"""
    if check(valid):
        raise AssertionError("The safe fixture must pass")
    violations = {
        "direct operation": valid + "try isolated.trashItem(at: source, resultingItemURL: nil)",
        "missing override": valid.replace("override func", "func"),
        "wrong class": valid.replace("final class SandboxTrashFileManager", "final class OtherManager"),
        "wrong superclass": valid.replace(": FileManager,", ": NSObject,"),
        "omitted injection": valid.replace(", fileManager: isolated", ""),
        "default injection": valid.replace("fileManager: isolated", "fileManager: .default"),
        "qualified default": valid.replace("fileManager: isolated", "fileManager: FileManager.default"),
        "wrong type": valid.replace("isolated: SandboxTrashFileManager", "isolated: FileManager"),
        "unverified initializer": valid.replace("= SandboxTrashFileManager(", "= OtherManager("),
        "nested label": valid.replace("fileManager: isolated", "options: wrap(fileManager: isolated)"),
        "system temporary path": valid + "let path = NSTemporaryDirectory()",
        "system temporary URL": valid + "let path = FileManager.default.temporaryDirectory",
        "shadowed binding": valid + "let isolated = FileManager()",
        "shadowed parameter": valid + """
func unsafe(isolated: FileManager) {
    try trashTranscript(at: source, fileManager: isolated)
}
""",
        "shadowed loop binding": valid + """
for isolated in [FileManager.default] {
    try trashTranscript(at: source, fileManager: isolated)
}
""",
        "shadowed closure binding": valid + """
[FileManager.default].forEach { isolated in
    try trashTranscript(at: source, fileManager: isolated)
}
""",
        "shadowed tuple binding": valid + """
do {
    let (isolated, _) = (FileManager.default, 0)
    try trashTranscript(at: source, fileManager: isolated)
}
""",
        "interpolated call": valid + r'let unsafe = "\(try trashTranscript(at: source))"',
        "string disguised declaration": valid.replace("let isolated:", 'let fake = "let isolated:'),
    }
    violations.update({word: valid + f'\nlet forbidden = "{word}"' for word in FORBIDDEN})
    for name, source in violations.items():
        if not check(source):
            raise AssertionError(f"Unsafe fixture was accepted: {name}")
    print(f"PASS: transcript isolation self-test ({len(violations)} rejected fixtures)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    path = Path(__file__).with_name("main.swift")
    errors = check(path.read_text())
    if errors:
        for error in errors:
            print(f"FAIL: {path.name}: {error}", file=sys.stderr)
        return 1
    print("PASS: transcript isolation scan")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
