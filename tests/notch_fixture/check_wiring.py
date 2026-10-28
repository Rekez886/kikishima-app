from pathlib import Path

root = Path(__file__).resolve().parents[2]
host = (root / 'Sources/Kikishima/ShootNotch.swift').read_text()
island = (root / 'Sources/Kikishima/IslandNotch.swift').read_text()
vendor = (root / 'Vendor/DynamicNotchKit/Sources/DynamicNotchKit/Utility/NSScreen+Extensions.swift').read_text()
assert 'if let height = ShootNotch.menuBarHeight(on: scr) { notchH = height }' in island
assert 'ShootNotchInjection.menuBarHeight = configuration.menubar' in host
assert 'return configuration?.menubar' in host
assert 'if let height = ShootNotchInjection.menuBarHeight(for: self) { return height }' in vendor
assert 'candidate === screen ? menuBarHeight : nil' in vendor
assert 'ShootNotchInjection.size = CGSize(width: configuration.width, height: configuration.top)' in host
assert 'return CGSize(width: configuration.width, height: configuration.top)' in host
assert 'if let size = ShootNotchInjection.size(for: self) { return size }' in vendor
assert 'guard let size = size(on: screen), let configuration' in host
assert 'ShootNotchMask(frame: CGRect(origin: .zero, size: size)' in host
assert 'y: screen.frame.maxY - size.height, width: size.width, height: size.height)' in host
assert 'if let size = ShootNotch.size(on: scr) { display.toolbarNotchHeight = size.height }' in island
print('PASS SHOOT wiring: menu height separate from physical mask/notch/toolbar height')
