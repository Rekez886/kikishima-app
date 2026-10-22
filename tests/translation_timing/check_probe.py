"""Exercise the actual task delegate with an unresumed task; no HTTP is sent."""
from pathlib import Path
import sys
source = Path('Sources/Kikishima/Translate.swift').read_text()
prefix = source[:source.index('// API key 存储')]
proxy = source[source.index('func translateViaProxy('):]
assert 'if timing != nil { req.setValue("1", forHTTPHeaderField: "X-Kikishima-Timing") }' in proxy
assert 'probe.receivedHeaders(resp)' in proxy
Path(sys.argv[1]).write_text(prefix + Path('tests/translation_timing/probe.swift').read_text())
