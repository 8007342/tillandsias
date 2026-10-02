#!/usr/bin/env python3
"""Supplement the unchanged 13-case manifest with actual CRLF bytes."""
import base64
import hashlib
import json
from pathlib import Path
import measure

base = Path(__file__).resolve().parent
root = base / 'actual CRLF case root'
(root / '.git').mkdir(parents=True, exist_ok=True)
measure.write(root / 'plan/index.yaml', b'packets: []\n')
source = measure.blob(measure.REF, 'scripts/fixtures/source agreements/tray-crlf.rs')
assert b'\r' not in source, 'the explicit LF-to-CRLF transform assumes LF source'
crlf = source.replace(b'\n', b'\r\n')
assert crlf.count(b'\r\n') > 0
canonical = measure.CANONICAL['source']
measure.write(root / canonical, crlf)
measure.write(root / 'space bearing source/tray source.rs', crlf)
measure.write(root / measure.GUARDS['tray_process_naming'],
              measure.blob(measure.REF + '^', measure.GUARDS['tray_process_naming']))
case = {'id': 'actual-crlf-canonical', 'operation': 'tray_process_naming',
        'root': str(root), 'args': [canonical]}
old = measure.run(case, 'old')
new = {p: measure.run(case, p) for p in ['debug', 'release']}
spaces = dict(case, id='actual-crlf-space-bearing-argument',
              args=['space bearing source/tray source.rs'])
space_results = {p: measure.run(spaces, p) for p in ['debug', 'release']}
receipt = {
    'purpose': 'supplemental actual CRLF input, not timing; original 13-case run remains unchanged',
    'source': 'e6e5e0e64:scripts/fixtures/source agreements/tray-crlf.rs',
    'transform': 'replace each LF byte with CRLF; same transformed input given to old and new',
    'original_bytes': len(source), 'original_crlf_count': source.count(b'\r\n'),
    'input_bytes': len(crlf), 'input_crlf_count': crlf.count(b'\r\n'),
    'input_sha256': hashlib.sha256(crlf).hexdigest(),
    'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'old': old, 'new': new,
    'equal': {p: measure.same(old, v) for p, v in new.items()},
    'space_argument_new': space_results,
    'space_argument_equal': {p: measure.same(old, v) for p, v in space_results.items()},
    'space_argument_note': 'supplemental success-output comparison; primary old/new named spelling is identical canonical path, while this arm exercises a literal spaced Lua argument',
}
raw = (json.dumps(receipt, indent=2) + '\n').encode()
measure.write(base / 'crlf-receipts.json', raw)
print(json.dumps({'receipt': str(base / 'crlf-receipts.json'),
                  'sha256': hashlib.sha256(raw).hexdigest(),
                  'input_crlf_count': receipt['input_crlf_count'],
                  'equal': receipt['equal'],
                  'space_argument_equal': receipt['space_argument_equal']}, indent=2))
