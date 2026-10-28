"""Check rendered production frame coverage and width-gate results."""
import json, sys
from pathlib import Path

rows = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[2])
expected = 110  # 22 retained status rows in five languages
assert len(rows) == expected and len({(r['id'], r['language']) for r in rows}) == expected
failed = [row for row in rows if not row['pass']]
(root / 'width-gate.json').write_text(json.dumps({'total': len(rows), 'failed': len(failed)}) + '\n')
print(f"{'FAIL' if failed else 'PASS'} status width gate: {len(rows)} cells, {len(failed)} overflow")
if failed:
    raise SystemExit(1)
