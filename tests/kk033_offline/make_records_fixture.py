"""Create one wholly fictional, recoverable Markdown record only in <dir>."""
from pathlib import Path
import base64
import json
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: make_records_fixture.py <dir>')
directory = Path(sys.argv[1])
directory.mkdir(parents=True, exist_ok=True)
record = {
    'version': 1,
    'header': '# Fictional Moon Garden Planning\n\n2026-01-01 · English / 日本語 → English\n\n',
    'incompleteLabel': '译文未完成，原文已保留',
    'settings': {'targetLanguage': 'English', 'glossary': '', 'model': 'gpt-4o-mini', 'useProxy': True},
    'rows': [
        {'source': 'The imaginary moon garden opens on Starday.', 'translation': 'The imaginary moon garden opens on Starday.',
         'complete': True, 'marker': False, 'stamp': '00:00', 'previousSource': ''},
        {'source': '架空の月の庭に青い花を植えましょう。', 'translation': '',
         'complete': False, 'marker': False, 'stamp': '00:05', 'previousSource': 'The imaginary moon garden opens on Starday.'},
    ],
}
# TranscriptRecovery.body + markdown() wire format. Exhaustion is represented
# on disk by complete=false and empty translation, not by an attempts field.
body = record['header']
for row in record['rows']:
    body += f"`{row['stamp']}` {row['source']}\n\n{row['translation']}\n\n"
    if not row['complete']:
        body += f"*{record['incompleteLabel']}*\n\n"
payload = base64.b64encode(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()).decode()
path = directory / 'Kikishima 2026-01-01 00.00.00 · Fictional Moon Garden.md'
# Refuse to overwrite an existing record, including a symlink out of this dir.
with path.open('x', encoding='utf-8') as file:
    file.write(body + '<!-- kikishima-recovery-v1:' + payload + ' -->\n')
print(path)
