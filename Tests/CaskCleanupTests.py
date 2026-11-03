#!/usr/bin/env python3
"""Run the cask's literal cleanup payload against disposable user configs."""
import json
import re
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap

cask = (Path(__file__).resolve().parents[1] / 'tap/Casks/eclam.rb').read_text()
payload = re.search(r'args:\s*\["-c", <<~PYTHON, "~"\]\n(.*?)^\s*PYTHON$', cask, re.S | re.M)
assert payload, "literal cleanup command missing"
code = textwrap.dedent(payload.group(1))
with tempfile.TemporaryDirectory(prefix='eclam-cask-test-') as td:
    home = Path(td).resolve()
    for name in ('.codex', '.hermes', '.claude'):
        (home / name).mkdir()
    codex = home / '.codex/config.toml'
    hermes = home / '.hermes/config.yaml'
    claude = home / '.claude/settings.json'
    other = {'matcher': '*', 'hooks': [{'command': 'my-command'}]}
    initial = {'hooks': {'PreToolUse': [{'_eclam': True}, other], 'OtherEvent': [other]}, 'keep': 42, '_eclam_hook_version': 3}
    codex.write_text('keep = true\n# >>> eclam-hook\nour-hook = true\n# <<< eclam-hook\nafter = true\n')
    codex.chmod(0o600)
    hermes.write_text('keep: true\n# >>> eclam-hook\nincomplete: true\n')
    claude.write_text(json.dumps(initial))
    # The same directory write boundaries declared by writable_paths. Test the
    # atomic temporary-file + rename path with all other file writes denied.
    profile = '(version 1)(allow default)(deny file-write*)' + ''.join(
        '(allow file-write* (subpath ' + json.dumps(str(home / name)) + '))'
        for name in ('.codex', '.hermes', '.claude'))
    def run():
        subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, '/usr/bin/python3', '-c', code, str(home)], check=True)
    run()
    assert codex.read_text() == 'keep = true\nafter = true\n'
    assert stat.S_IMODE(codex.stat().st_mode) == 0o600
    assert hermes.read_text() == 'keep: true\n# >>> eclam-hook\nincomplete: true\n'
    result = json.loads(claude.read_text())
    assert result == {'hooks': {'PreToolUse': [other], 'OtherEvent': [other]}, 'keep': 42}
    unchanged = [p.read_bytes() for p in (codex, hermes, claude)]
    run()
    assert unchanged == [p.read_bytes() for p in (codex, hermes, claude)]
    for malformed in ('{broken', '[]', '{"hooks": "leave me alone"}'):
        claude.write_text(malformed); run(); assert claude.read_text() == malformed
    codex.unlink(); hermes.unlink(); claude.unlink(); run()
    assert not codex.exists() and not hermes.exists() and not claude.exists()
    outside = home / 'untouched.toml'; outside.write_text('# >>> eclam-hook\nkeep\n# <<< eclam-hook\n')
    codex.symlink_to(outside); run(); assert 'keep' in outside.read_text()
    print('PASS cask cleanup: sandboxed atomic writes, exact markers, other hooks preserved, malformed/missing/symlink configs, permissions, idempotence')
