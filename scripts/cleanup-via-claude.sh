#!/bin/sh
# parla-eval --cleanup-cmd adapter, for A/B-ing models you have a CLI for but no
# API key:
#
#   swift run parla-eval --cleanup-only --model claude-haiku-4-5 \
#     --cleanup-cmd scripts/cleanup-via-claude.sh --out /tmp/haiku.json
#
#   $1 = system prompt   $2 = model id (from --model)   stdin = user message
#   stdout = cleaned text
#
# Both prompts are built by Parla's own PromptBuilder, so this measures Parla's
# prompt and moves only the transport. Compare two of these runs with each
# other, never with eval/results.json: a CLI wraps its own harness around the
# model, so the absolute scores are not the same measurement.
#
# The tools are off and the working directory is a scratch one on purpose. The
# corpus has an `injection` category — instruction-shaped speech that must be
# transcribed and never obeyed — and handing that to an agent that can run Bash
# in this repo would be both a wrong measurement and a bad idea.
set -e
work="${TMPDIR:-/tmp}/parla-eval-cleanup-sandbox"
mkdir -p "$work"
cd "$work"
exec claude -p --model "$2" --system-prompt "$1" \
  --disallowedTools "Bash" "Read" "Write" "Edit" "Glob" "Grep" "WebFetch" "WebSearch" "Task" "NotebookEdit" "TodoWrite"
