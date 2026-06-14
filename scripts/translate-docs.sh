#!/usr/bin/env bash
# Regenerate the non-English READMEs from the English source (README.md) by
# driving the Claude Code CLI headlessly. English is the single source of truth;
# README.zh-CN.md / README.ja.md / README.es.md are generated and should never be
# hand-edited. README.ko.md is maintained by hand (not regenerated).
#
# Usage:
#   ./scripts/translate-docs.sh                 # translate all targets
#   ./scripts/translate-docs.sh ja es           # only the given language codes
#
# Requirements:
#   - `claude` on PATH (Claude Code CLI). Locally that's your normal install;
#     in CI install `@anthropic-ai/claude-code` and set ANTHROPIC_API_KEY.
# Override the model with CLAUDE_MODEL (default: claude-sonnet-4-6).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

SOURCE="README.md"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"

# code → endonym shown in the language bar (function, not an assoc array, so this
# stays portable to macOS's stock bash 3.2).
lang_name() {
  case "$1" in
    ko)    printf '한국어' ;;
    zh-CN) printf '中文' ;;
    ja)    printf '日本語' ;;
    es)    printf 'Español' ;;
    *)     return 1 ;;
  esac
}
ALL_CODES=(zh-CN ja es)

# Language-bar entry order (code|label|file); English is always the base file.
BAR_ORDER=("en|English|README.md" "ko|한국어|README.ko.md" "zh-CN|中文|README.zh-CN.md" "ja|日本語|README.ja.md" "es|Español|README.es.md")

command -v claude >/dev/null 2>&1 || { echo "✗ 'claude' CLI not found on PATH" >&2; exit 2; }
[ -f "$SOURCE" ] || { echo "✗ source $SOURCE not found" >&2; exit 2; }

codes=("$@"); [ ${#codes[@]} -eq 0 ] && codes=("${ALL_CODES[@]}")

# Build the language-bar line for a given current language code.
langbar() {
  local current="$1" out="" e code label file
  for e in "${BAR_ORDER[@]}"; do
    IFS='|' read -r code label file <<<"$e"
    [ -n "$out" ] && out+=" · "
    if [ "$code" = "$current" ]; then out+="**${label}**"; else out+="[${label}](${file})"; fi
  done
  printf '%s' "$out"
}

translate_one() {
  local code="$1" out="README.${1}.md" lang
  lang="$(lang_name "$code")" || { echo "✗ unknown language code: $code (known: ${ALL_CODES[*]})" >&2; return 1; }

  local bar; bar="$(langbar "$code")"
  echo "==> $code ($lang) → $out  [model: $MODEL]"

  local prompt
  prompt=$(cat <<EOF
You are a professional technical translator. Translate the Markdown README below into ${lang}.

Hard rules:
- Output ONLY the translated Markdown file content. No preamble, no explanation, no surrounding code fence.
- Preserve the document structure exactly: headings, tables, lists, blockquotes, badges, images, and link targets.
- Do NOT translate: code blocks, inline code, CLI commands and flags, file paths, env vars, and identifiers
  (e.g. ElectronicClam, eclam, SMAppService, IOPMSetSystemPowerSetting, LSUIElement, kqueue, mach service).
- Keep the product name "Electronic Clam" in English everywhere.
- Under the "# Electronic Clam" title, keep the first bold English tagline ("Keeps your Mac awake while it matters — and lets it sleep when it's safer to.") verbatim, and translate the tagline line after it.
- Keep image/GIF embeds (docs/assets/*.gif, *.png) and their paths exactly as-is; translate only alt text.
- Replace the language-bar line (the line after the "<!-- i18n-langbar -->" comment) with exactly this, keeping the comment line above it:
${bar}
- Translate the final <sub> note about generated translations into ${lang}.

README to translate:
---
$(cat "$SOURCE")
EOF
)

  local result
  result="$(printf '%s' "$prompt" | claude -p --model "$MODEL" 2>/dev/null)" || {
    echo "✗ claude invocation failed for $code" >&2; return 1; }

  # Strip an accidental wrapping ```markdown ... ``` fence if the model added one.
  result="$(printf '%s\n' "$result" \
    | sed -e '1{/^```/d;}' -e '${/^```$/d;}')"

  # Sanity check: must start with the centered div and contain the title.
  case "$result" in
    *'# Electronic Clam'*) : ;;
    *) echo "✗ output for $code failed sanity check (no title); not written" >&2; return 1 ;;
  esac

  printf '%s\n' "$result" > "$out"
  echo "    wrote $out ($(wc -l <"$out" | tr -d ' ') lines)"
}

rc=0
for c in "${codes[@]}"; do translate_one "$c" || rc=1; done
exit "$rc"
