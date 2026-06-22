cask "eclam" do
  version "0.6.0"
  sha256 "5832b11937278d673e670ec6b562067e5f999be03b61175982e5486c52cd0145"

  url "https://github.com/jadhvank/eclam/releases/download/v#{version}/ElectronicClam-#{version}.zip"
  name "ElectronicClam"
  desc "Menu bar app: keep macOS awake while agents work; safe sleep when conditions degrade"
  homepage "https://github.com/jadhvank/eclam"

  depends_on macos: :ventura
  # build.sh is arm64-only (no universal binary yet — docs/TODO.md). Without
  # this gate an Intel brew install succeeds and the app crashes at launch.
  depends_on arch: :arm64

  app "ElectronicClam.app"

  # ADR-0007 §E — symlink the same Mach-O so users can type `eclam on`.
  binary "#{appdir}/ElectronicClam.app/Contents/MacOS/ElectronicClam", target: "eclam"

  # Developer ID signed + notarized + stapled (ADR-0020 §③). Gatekeeper accepts
  # the download on its own, so the old quarantine-strip postflight is gone.

  # v0.3.3 — strip our hook entries from agent configs BEFORE the app bundle
  # is removed, so the user isn't left with dangling hook commands pointing at
  # a deleted ElectronicClam.app. We only touch the marker-delimited blocks our
  # installer wrote; the rest of each user config is preserved.
  uninstall_preflight do
    sed_block_args = ["-i", "", "/# >>> eclam-hook/,/# <<< eclam-hook/d"]
    ["~/.codex/config.toml", "~/.hermes/config.yaml"].each do |relative|
      abs = File.expand_path(relative)
      next unless File.exist?(abs)
      system_command "/usr/bin/sed", args: sed_block_args + [abs], must_succeed: false
    end
    # Claude is JSON — sed is unsafe; remove exactly the entries the installer
    # tagged with `"_eclam": true` (HookInstaller) via python3 (proposal §6).
    # Best-effort: malformed/missing file exits 0 and leaves everything alone.
    claude_cleanup = <<~PYTHON
      import json, sys, os
      p = sys.argv[1]
      if not os.path.exists(p): sys.exit(0)
      try:
          with open(p) as f: root = json.load(f)
      except Exception: sys.exit(0)
      if not isinstance(root, dict): sys.exit(0)
      hooks = root.get("hooks") or {}
      changed = False
      for k in ("PreToolUse", "PostToolUse"):
          arr = hooks.get(k)
          if isinstance(arr, list):
              kept = [e for e in arr if not (isinstance(e, dict) and e.get("_eclam"))]
              if len(kept) != len(arr):
                  hooks[k] = kept; changed = True
      if root.pop("_eclam_hook_version", None) is not None: changed = True
      if changed:
          root["hooks"] = hooks
          with open(p, "w") as f: json.dump(root, f, indent=2, ensure_ascii=False)
    PYTHON
    system_command "/usr/bin/python3",
                   args: ["-c", claude_cleanup, File.expand_path("~/.claude/settings.json")],
                   must_succeed: false
  end

  uninstall quit: "com.jadhvank.eclam"

  # `brew uninstall --zap` clears user data including the Claude hook entry,
  # which is JSON and harder to surgically edit from a shell.
  zap trash: [
    "~/Library/Preferences/com.jadhvank.eclam.plist",
    "~/Library/Caches/com.jadhvank.eclam",
    "~/Library/Application Support/com.jadhvank.eclam",
  ]
end
