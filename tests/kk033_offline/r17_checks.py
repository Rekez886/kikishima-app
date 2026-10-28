from pathlib import Path
import re
sources=list(Path('Sources').rglob('*.swift'))+list(Path('Vendor').rglob('*.swift'))
texts=[p.read_text() for p in sources]
assert sum(len(re.findall(r'\bMenuBarExtra\s*\{',s)) for s in texts)==1
assert not any(re.search(r'NSStatusBar\s*\.\s*system\s*\.\s*statusItem\s*\(',s) for s in texts)
app=Path('Sources/Kikishima/App.swift').read_text()
label=app.split('private var menuStatusLabel: String {')[1].split('private var menuAccessPresented')[0]
assert '.accessibilityLabel(tr("Kikishima 字幕") + " · " + menuStatusLabel)' in app
assert '.help(tr("Kikishima 字幕") + " · " + menuStatusLabel)' in app
s=Path('Sources/Kikishima/ShootOpenMenu.swift').read_text()
assert 'if #available(macOS 27, *)' in s
assert all(x not in s for x in ['performClick(', 'sendAction(', 'CGEvent(', 'NSEvent(', 'AXUIElement'])
assert 'expandedInterfaceDelegate' in s and '_beginExpandedInterfaceSession:' in s
assert 'greatestFiniteMagnitude' in s and 'exit(' not in s and 'OPEN_MENU failed:' in s and 'requested = false' in s
assert 'if ShootSimulation.requestedOpenMenu && !presented' not in app
print('PASS one native menu, no manual status item creation, bounded session wiring and accessibility labels')
