cask "eclam" do
  version "0.8.1"
  sha256 "80bc729156bde8a213084f07eecfcd7698a3c720e749fbe921dc08ac330bc8ae"

  url "https://github.com/jadhvank/eclam/releases/download/v#{version}/ElectronicClam-#{version}.zip"
  name "ElectronicClam"
  desc "Keep the system awake while agents work, with safety guards"
  homepage "https://github.com/jadhvank/eclam"
  auto_updates true

  # build.sh is arm64-only (no universal binary yet — docs/TODO.md). Without
  # this gate an Intel brew install succeeds and the app crashes at launch.
  depends_on arch: :arm64
  depends_on macos: :ventura

  app "ElectronicClam.app"
  # ADR-0007 §E — symlink the same Mach-O so users can type `eclam on`.
  binary "#{appdir}/ElectronicClam.app/Contents/MacOS/ElectronicClam", target: "eclam"

  # Developer ID signed + notarized + stapled (ADR-0020 §③). Gatekeeper accepts
  # the download on its own, so the old quarantine-strip postflight is gone.

  # v0.3.3 — strip our hook entries from agent configs BEFORE the app bundle
  # is removed, so the user isn't left with dangling hook commands pointing at
  # a deleted ElectronicClam.app. We only touch the marker-delimited blocks our
  # installer wrote; the rest of each user config is preserved.
  # Structured steps require a current Homebrew (verified with 7.0.9).
  # The command uses atomic replacement, so sandbox writes need each config's
  # parent directory, not just the existing file. No other home paths are writable.
  uninstall_preflight_steps do
    run "/usr/bin/python3",
        writable_paths: ["~/.codex", "~/.hermes", "~/.claude"],
        must_succeed:   false,
        args:           ["-c", <<~PYTHON, "~"]
          from pathlib import Path
          import json
          import os
          import stat
          import sys
          import tempfile

          home = Path(sys.argv[1]).expanduser()

          def replace(path, transform):
              if path.is_symlink() or not path.is_file():
                  return
              try:
                  original = path.read_text()
                  updated = transform(original)
                  if updated == original:
                      return
                  fd, temp = tempfile.mkstemp(prefix='.eclam-cleanup-', dir=str(path.parent))
                  try:
                      os.fchmod(fd, stat.S_IMODE(path.stat().st_mode))
                      with os.fdopen(fd, 'w') as f:
                          f.write(updated)
                          f.flush()
                          os.fsync(f.fileno())
                      os.replace(temp, path)
                  finally:
                      if os.path.exists(temp):
                          os.unlink(temp)
              except (OSError, UnicodeError, ValueError, TypeError):
                  # Missing, malformed or unwritable configs must not block uninstall.
                  return

          def strip_marked(text):
              lines = text.splitlines(keepends=True)
              output, pending = [], None
              for line in lines:
                  if pending is None:
                      if line.strip() == '# >>> eclam-hook':
                          pending = [line]
                      else:
                          output.append(line)
                  else:
                      pending.append(line)
                      if line.strip() == '# <<< eclam-hook':
                          pending = None
              if pending is not None:
                  # Incomplete marker pairs cannot safely identify our whole block.
                  output.extend(pending)
              return ''.join(output)

          def strip_claude(text):
              root = json.loads(text)
              if not isinstance(root, dict):
                  return text
              hooks = root.get('hooks')
              if hooks is not None and not isinstance(hooks, dict):
                  return text
              changed = False
              if isinstance(hooks, dict):
                  for key in ('PreToolUse', 'PostToolUse'):
                      entries = hooks.get(key)
                      if isinstance(entries, list):
                          kept = [entry for entry in entries if not (isinstance(entry, dict) and entry.get('_eclam') is True)]
                          if kept != entries:
                              hooks[key] = kept
                              changed = True
              if '_eclam_hook_version' in root:
                  del root['_eclam_hook_version']
                  changed = True
              return json.dumps(root, indent=2, ensure_ascii=False) + '\n' if changed else text

          replace(home / '.codex/config.toml', strip_marked)
          replace(home / '.hermes/config.yaml', strip_marked)
          replace(home / '.claude/settings.json', strip_claude)
        PYTHON
  end

  uninstall quit: "com.jadhvank.eclam"

  # `brew uninstall --zap` clears user data including the Claude hook entry,
  # which is JSON and harder to surgically edit from a shell.
  zap trash: [
    "~/Library/Application Support/com.jadhvank.eclam",
    "~/Library/Caches/com.jadhvank.eclam",
    "~/Library/Preferences/com.jadhvank.eclam.plist",
  ]
end
