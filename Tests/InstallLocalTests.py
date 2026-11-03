#!/usr/bin/env python3
"""Exercise the installer with a disposable checkout and fake OS commands."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

INSTALLER = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'scripts/install-local.sh'

def case(failure='', running=False):
    with tempfile.TemporaryDirectory(prefix='eclam-install-test-') as td:
        root = Path(td)
        scripts = root / 'scripts'; scripts.mkdir()
        fake = root / 'bin'; fake.mkdir()
        dest = root / 'installed/ElectronicClam.app'; dest.mkdir(parents=True)
        (dest / 'old').write_text('original')
        backup = root / 'backups'
        backup.mkdir()
        for i in range(4):
            old_backup = backup / f'ElectronicClam-2000010{i}-000000-0-old.app.bak'
            old_backup.mkdir()
            os.utime(old_backup, (2000000000, 2000000000))
        os.utime(dest, (100, 100))  # newly backed-up app can have an ancient build mtime
        # Keep the unmodified upstream revision safely inside the fixture too.
        source = INSTALLER.read_text().replace('DEST="/Applications/ElectronicClam.app"', 'DEST="$ECLAM_INSTALL_DEST"')
        (scripts / 'install-local.sh').write_text(source)
        def executable(path, body):
            path.write_text('#!/usr/bin/env bash\nset -eu\n' + body + '\n'); path.chmod(0o755)
        executable(scripts / 'build.sh', '''mkdir -p "$FIXTURE/build/ElectronicClam.app/Contents/MacOS"
cat > "$FIXTURE/build/ElectronicClam.app/Contents/MacOS/ElectronicClam" <<'BIN'
#!/usr/bin/env bash
if [[ "$1" == "$FAIL_AT" ]]; then exit 9; fi
exit 0
BIN
chmod +x "$FIXTURE/build/ElectronicClam.app/Contents/MacOS/ElectronicClam"''')
        executable(fake / 'pgrep', '[[ -f "$FIXTURE/running" ]]')
        executable(fake / 'osascript', 'if [[ "$FAIL_AT" == quit_hang ]]; then exec /bin/sleep 30; fi\nif [[ "$FAIL_AT" != quit ]]; then rm -f "$FIXTURE/running"; fi')
        executable(fake / 'sleep', ':')
        executable(fake / 'open', '[[ "$FAIL_AT" != open ]]')
        executable(fake / 'ditto', '''if [[ "$FAIL_AT" == copy ]]; then mkdir -p "$2"; touch "$2/partial"; exit 7; fi
cp -R "$1" "$2"''')
        if running: (root / 'running').touch()
        env = dict(os.environ, FIXTURE=str(root), FAIL_AT=failure, ECLAM_INSTALL_DEST=str(dest), ECLAM_BACKUP_DIR=str(backup), ECLAM_QUIT_TIMEOUT='1', ECLAM_SIGN_ID='-', PATH=f'{fake}:/usr/bin:/bin:/usr/sbin:/sbin')
        proc = subprocess.Popen(['bash', str(scripts / 'install-local.sh')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=4)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
            raise AssertionError('quit request exceeded its timeout')
        output = stdout + stderr
        if failure == 'copy':
            assert proc.returncode != 0, output
            assert (dest / 'old').exists() and not (dest / 'partial').exists(), 'copy failure did not restore original app\n' + output
        elif failure in ('quit', 'quit_hang'):
            assert proc.returncode != 0 and (dest / 'old').exists(), 'must refuse replacement while app is running\n' + output
        elif failure:
            assert proc.returncode != 0 and '==> Done.' not in output, 'failure was reported as successful installation\n' + output
        else:
            assert proc.returncode == 0 and (dest / 'Contents/MacOS/ElectronicClam').exists(), output
            backups = list(backup.glob('*.app.bak'))
            assert len(backups) == 3, 'keep exactly the three most recent replacements'
            assert any((p / 'old').exists() for p in backups), 'latest backup pruned because original bundle was old'
            assert 'caller' in output.lower() and 'ad-hoc' in output.lower(), 'development signing warning missing'
        print('PASS install-local:', failure or 'success')

case('copy')
case('quit', running=True)
case('quit_hang', running=True)
case('repair')
case('status')
case('open')
case(running=True)
