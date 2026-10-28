#!/usr/bin/env python3
"""Agent-friendly lints for Kikishima (prototype, proto/agent-friendly).

R1 incomplete-transition-gate: a .disabled(...) gate that blocks on one meeting
   transition flag (state.switchingMeetingLanguage or state.resuming) must block on
   BOTH, unless it also gates on state.running (which already covers both, since
   both transitions happen while running). Fix: add the missing flag, or better,
   call the SessionControls gate in Sources/Kikishima/SessionLifecycle.swift.
R2 raw-generation-compare (ratchet): hand-written `generation ==` / `== owner` checks
   outside SessionScope.swift must not grow beyond tools/agent_lint/baseline.json.
Usage: lint_agent_rules.py [--update-baseline] FILE_OR_DIR...
Exceptions: append `// agent-lint: allow R1 reason=... until=YYYY-MM-DD by=<maintainer>` on the line.
"""
import json, os, re, sys
R1 = re.compile(r"\.disabled\(([^)]*)\)")
TRANSITIONS = ("state.switchingMeetingLanguage", "state.resuming")
def r1_violation(expr):
    hits = [t for t in TRANSITIONS if re.search(re.escape(t) + r"\b", expr)]
    if not hits or len(hits) == len(TRANSITIONS): return None
    if re.search(r"state\.running\b", expr): return None
    return [t for t in TRANSITIONS if t not in hits]
R2 = re.compile(r"(\bgeneration\s*[!=]=|[!=]=\s*generation\b|[!=]=\s*owner\b)")
OWNERS = {"Sources/Kikishima/CaptionState.swift", "Sources/Kikishima/SessionLifecycle.swift"}
SCOPE = "Sources/Kikishima/SessionScope.swift"
BASE = os.path.join(os.path.dirname(__file__), "baseline.json")

def files(args):
    for a in args:
        if os.path.isdir(a):
            for r, _, fs in os.walk(a):
                for f in fs:
                    if f.endswith(".swift"): yield os.path.join(r, f)
        else: yield a

def main(argv):
    upd = "--update-baseline" in argv
    args = [a for a in argv if not a.startswith("--")]
    errs, counts = [], {}
    for path in files(args):
        name = os.path.basename(path)
        rel = os.path.relpath(path).replace(os.sep, "/")
        for i, line in enumerate(open(path, encoding="utf-8"), 1):
            if "agent-lint: allow" in line: continue
            m = R1.search(line)
            if rel not in OWNERS and m and (missing := r1_violation(m.group(1))):
                errs.append(f"{path}:{i}: R1 incomplete-transition-gate `.disabled({m.group(1).strip()})` "
                            f"missing {', '.join(missing)} -> add it or use SessionControls "
                            "(SessionLifecycle.swift); see 976a896793 / b7aa91649e.")
            if rel != SCOPE and R2.search(line):
                counts[name] = counts.get(name, 0) + 1
    if upd and os.environ.get("AGENT_LINT_BASELINE_APPROVED_BY") is None:
        print("refusing: raising the baseline needs a reviewer; set AGENT_LINT_BASELINE_APPROVED_BY=<name> (a maintainer review)"); return 2
    if upd:
        json.dump(counts, open(BASE, "w"), indent=1, sort_keys=True); print("baseline updated"); return 0
    base = json.load(open(BASE)) if os.path.exists(BASE) else {}
    for n, c in sorted(counts.items()):
        if c > base.get(n, 0):
            errs.append(f"{n}: R2 raw-generation-compare {c} > baseline {base.get(n,0)} -> "
                        "wrap session-scoped async work in SessionScope.run(generation:) instead of comparing generations by hand.")
    print("\n".join(errs) or "agent-lint: OK")
    return 1 if errs else 0
if __name__ == "__main__": sys.exit(main(sys.argv[1:]))
