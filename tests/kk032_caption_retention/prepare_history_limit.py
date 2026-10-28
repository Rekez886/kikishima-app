"""Extract the current island types and prepare the fixed history-limit matrix."""
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = Path('Sources/Kikishima/CaptionIsland.swift').read_text()
hierarchy = source[source.index('enum CaptionHierarchy {'):source.index('\n\nenum CaptionToolbarMode')]
row = source[source.index('struct CaptionRowText:'):source.index('/// The outer island')]
(root / 'hierarchy.swift').write_text('import Foundation\n' + hierarchy + row)
matrix = root / 'history_limit'
matrix.mkdir()
(matrix / 'main.swift').write_text('''import Foundation
for size in 13...24 { for mode in [(true,true),(true,false),(false,true)] {
 for banner in [false,true] { for paused in [false,true] { for height in [64.0,100,148,153,240,600] {
 print(size,mode.0,mode.1,banner,paused,height,CaptionHierarchy.historyLimit(userSize:Double(size),showTranslation:mode.0,showSource:mode.1,banner:banner || paused,height:height))
 }}}}
}
precondition(CaptionHierarchy.maximumHistory == 3)
''')
