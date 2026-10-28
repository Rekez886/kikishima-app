from pathlib import Path
import sys
s=Path('Sources/Kikishima/CaptionIsland.swift').read_text()
h=s[s.index('enum CaptionHierarchy {'):s.index('\n\nenum CaptionToolbarMode')]
r=s[s.index('struct CaptionRowText:'):s.index('/// The outer island')]
Path(sys.argv[1]).write_text('import Foundation\n'+h+r)
