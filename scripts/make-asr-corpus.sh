#!/usr/bin/env bash
# Generate the synthetic half of the ASR eval corpus.
#
# WHAT THIS IS: `say(1)` reading known text into 16 kHz mono WAV — the same
# format AudioRecorder produces — so every case has an exactly-correct reference
# with no transcription step in between. That is the whole point: a human
# reference is guesswork about what was said; this one is the input.
#
# WHAT THIS IS NOT: a substitute for recorded human speech. TTS has no disfluency,
# no room tone, no accent, no clipping, perfect prosody and a constant speaker, so
# absolute WER here will be far better than reality — do NOT quote it as Parla's
# accuracy. Its job is regression detection: these numbers are stable, so a change
# that breaks whisper wiring, resampling, the marker stripper or the language pin
# moves them immediately. Cases are prefixed `syn-` so they can never be mistaken
# for the human corpus `eval/README.md` still asks for.
#
# Re-run after changing a case; the WAVs are committed so CI needs no `say`.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=eval/cases

emit() { # name, voice, category, text
  local name="$1" voice="$2" category="$3" text="$4"
  say -v "$voice" -o "$OUT/syn-$name.wav" --data-format=LEI16@16000 --channels=1 "$text"
  printf '%s\n' "$text" > "$OUT/syn-$name.raw.txt"
  { printf '# category: %s\n' "$category"; printf '%s\n' "$text"; } > "$OUT/syn-$name.golden.txt"
}

# Plain prose — the baseline. If this one regresses, something is badly wrong.
emit prose Samantha prose \
  "The meeting is on Thursday at four in the afternoon and we should bring the revised budget."

# Numbers and times: whisper's digit handling is a common regression site.
emit numbers Samantha numbers \
  "Transfer four hundred and twenty dollars on the fifteenth of March at nine thirty."

# Proper nouns and jargon — the case the personal dictionary exists to fix, and
# the one an initial_prompt change would move first.
emit jargon Alex jargon \
  "Deploy the Kubernetes cluster to the staging environment and check the Postgres replica lag."

# Code identifiers: camelCase and snake_case survive as words through ASR and are
# the code-mode rules' input.
emit code Alex code \
  "Rename the function to parse user input and update the call site in the audio recorder."

# Long-form, past the fifteen second freeze threshold, so the streaming window's
# cut-and-freeze path is actually exercised rather than skipped.
emit longform Samantha longform \
  "I have been thinking about how we should structure the next quarter of work, and my view is that we start with the reliability problems because they are the ones our users actually notice, then move on to the new features once the foundation is genuinely solid, and only after that do we revisit the pricing question that keeps coming up in every planning meeting."

# A second speaker on the same content as `prose`: any change that helps one
# voice and hurts the other is overfitting, and this pair is how you see it.
emit prose-alt Daniel prose \
  "The meeting is on Thursday at four in the afternoon and we should bring the revised budget."

# Near-silence. whisper hallucinates on this — it is where [BLANK_AUDIO] and the
# repetition guards earn their place. Reference is deliberately empty.
say -v Samantha -o "$OUT/syn-quiet.wav" --data-format=LEI16@16000 --channels=1 "[[slnc 1500]]"
printf '' > "$OUT/syn-quiet.raw.txt"
printf '# category: silence\n' > "$OUT/syn-quiet.golden.txt"

echo "wrote $(ls "$OUT"/syn-*.wav | wc -l | tr -d ' ') synthetic cases to $OUT"
