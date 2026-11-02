from pathlib import Path
import sys

source = Path("Sources/Kikishima/ShootSimulation.swift").read_text()
start = source.index("enum ShootSessionPolicy {")
index = source.index("{", start)
depth = 0
while index < len(source):
    character = source[index]
    if character == "{":
        depth += 1
    elif character == "}":
        depth -= 1
        if depth == 0:
            index += 1
            break
    index += 1
if depth != 0:
    raise SystemExit("unbalanced ShootSessionPolicy braces")
Path(sys.argv[1]).write_text("import Foundation\n\n" + source[start:index] + "\n")
