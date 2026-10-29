import json
import subprocess
import sys
from pathlib import Path

script, candidate, manifest, restore, commit, out = sys.argv[1:]
out = Path(out)
out.mkdir(exist_ok=False)
base = json.loads(Path(manifest).read_text())
cases = [('wrong hash', dict(base, sha256='0'*64), commit),
         ('wrong size', dict(base, bytes=1), commit),
         ('wrong source', base, '0'*40)]
for i, (name, body, expected_commit) in enumerate(cases):
    file = out / f'bad-manifest-{i}.json'
    file.write_text(json.dumps(body))
    r = subprocess.run([sys.executable, script, candidate, str(file), restore, expected_commit], capture_output=True, text=True)
    assert r.returncode != 0, (name, r.stdout)
    assert '"byteChecksPassed": true' not in r.stdout
    print('PASS reject:', name)
r = subprocess.run([sys.executable, script, restore, manifest, candidate, commit], capture_output=True, text=True)
assert r.returncode != 0
print('PASS reject: swapped candidate and restore')
print('Scope: byte/provenance validation only, not Apple codesign or hardware behavior')
