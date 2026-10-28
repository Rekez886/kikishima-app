from pathlib import Path
p=Path('Sources/Kikishima/CaptionPanel.swift').read_text()
assert 'CaptionHierarchy.desktopHistoryCount(' in p, 'desktop height capacity'
assert 'CaptionReadingPolicy.desktopLayout(' in p, 'desktop ordered queue'
assert 'alignment: .bottomLeading' in p, 'bottom alignment'
assert '.milliseconds(250)' in p, 'timeout runs without incoming updates'
assert 'CaptionReadingPolicy.desktopText(' in p, 'retain latest wrapped text'
assert '.lineLimit(current.translated ? 2 : 1)' in p, 'desktop two-line limit'
assert '.lineLimit(current ? nil : 1)' in p, 'island unchanged'
print('PASS desktop wiring')
