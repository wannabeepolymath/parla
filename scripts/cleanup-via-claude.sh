#!/bin/sh
# parla-eval --cleanup-cmd adapter.
#   $1 = system prompt   $2 = model id (from --model)   stdin = user message
#   stdout = cleaned text
# Tools off and cwd an empty sandbox on purpose: the corpus has an `injection`
# category of instruction-shaped speech that must be transcribed, never obeyed.
cd "$(dirname "$0")/sandbox" || exit 1
exec claude -p --model "$2" --system-prompt "$1" \
  --disallowedTools "Bash" "Read" "Write" "Edit" "Glob" "Grep" "WebFetch" "WebSearch" "Task" "NotebookEdit" "TodoWrite"
