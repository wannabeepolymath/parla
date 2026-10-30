# Parla: dictation website research

**Research date: 31 October 2026.**

The strongest finding: **on-device transcription, bring-your-own-key, and open source already form an occupied position.** Parla can distinguish itself through a simpler explanation of that control and a convincing demonstration of what happens at the cursor.

This report covers all 14 requested products, plus Typeless and BetterDictation. It examines public marketing pages and linked media, not their repositories.

**Evidence limits:** live pages were fetched, but rendered browser inspection was unavailable. Section lists therefore describe document order, with duplicate responsive markup removed. Hero media is identified from HTML, accessible descriptions, and asset URLs; playback was not tested. **Background colors, accent colors, light/dark presentation, and typefaces are UNVERIFIED for every site.** CSS/font files and response headers could not be inspected reliably. Framework signals below are evidence-based inferences.

Headlines and CTA labels below are verbatim. Long subheads are explicitly marked **excerpt**, followed by a summary of the remaining meaning. Performance, privacy, certification, and customer-count statements are **vendor claims**, not independently validated results.

## 1. Wispr Flow

- **Hero:** “Don’t type, just speak.” Subhead: “The voice-to-text AI that turns speech into clear, polished writing in every app.” Primary CTA: “Download for free”. Hero video/animation type **UNVERIFIED**. [Homepage](https://wisprflow.ai/)
- **Section order:** hero → employer logos → typing-speed comparison → three-part explanation → language/vocabulary/snippets/styles → privacy → testimonials and case studies → FAQ → combined dictation/notetaker download.
- **Visual language:** app/message UI, company logos, and testimonial portraits are present. Palette and fonts **UNVERIFIED**.
- **Dictation demonstration:** rambling speech becomes a concise message; interface labels identify fillers, corrections, and repetitions. Keyboard-versus-voice comparison displays 45 versus 220 WPM. A separate browser demo is linked.
- **Pricing/proof:** separate pricing page; free desktop allowance of 2,000 words/week; Pro $15/user/month or $12 with annual billing. Growth and Enterprise add administration. Homepage emphasizes customer-company logos, named founders, quantified case studies, and security certifications. [Pricing](https://wisprflow.ai/pricing)
- **Site technology:** `cdn.prod.website-files.com` assets strongly suggest Webflow.
- **Distinctive:** shows the specific editorial operations performed on messy speech. **Generic:** speed multiplier, employer-logo strip, and polished-writing promise.

## 2. Superwhisper

- **Hero:** “Just speak. Write faster.” Subhead: “Turn your voice into polished text. Works in Slack, Gmail and any other site or app.” Primary CTA: “Download”. Hero includes Cursor/Slack/Notes selectors and shortcut instructions. [Homepage](https://superwhisper.com/)
- **Section order:** hero demo → employer proof → tone variations → feature grid → custom modes/model configuration → app compatibility → coding-agent workflows → mobile → testimonials → pricing → tutorials → FAQ.
- **Visual language:** recreated application text, configuration UI, keyboard imagery, and portraits. Palette and fonts **UNVERIFIED**.
- **Dictation demonstration:** explicitly invites visitors to select an app and dictate using Option+Space. Successful microphone interaction **UNVERIFIED**. Also offers a demo video, tone examples, and tutorial videos.
- **Pricing/proof:** Free, Pro, Enterprise; monthly/yearly/lifetime selector; BYOK appears under Pro; 30-day refund. The extracted Pro amount is malformed, so **exact price and active billing period are UNVERIFIED**. Uses prominent Karpathy, Levels, Wilkinson, and Rauch testimonials.
- **Site technology:** same-origin image assets; framework **UNVERIFIED**.
- **Distinctive:** try-before-download dictation alongside unusually detailed mode controls. **Generic:** extensive logo/testimonial proof and broad feature grid.

Its marketing explicitly describes automatic pasting through clipboard integration; that establishes a useful contrast with Parla’s stated insertion method.

## 3. MacWhisper — Good Snooze

The current dedicated marketing site links directly to Good Snooze’s Gumroad checkout.

- **Hero:** normalized headline: “The all-in-one Mac app to transcribe it all.” Supporting copy begins “Like lectures, videos, podcasts and private files.” **Excerpt:** subsequent text introduces meetings and system-wide dictation. Prominent CTA: “Buy now”; navigation also offers a free trial. [Homepage](https://www.macwhisper.com/)
- **Section order:** expanded hero → file/use-case demonstrations → local privacy → accuracy/speakers/export/editing → AI summaries/chat/prompts/providers → reviews/press → Free/Pro pricing and feature comparison → FAQ.
- **Visual language:** product screenshots and meeting-detection notifications. Headline words appear as numerous separate heading nodes; animation **UNVERIFIED**. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** dictation is one part of a larger transcription suite; UI examples and feature comparison explain it.
- **Pricing/proof:** free tier; €64 one-time Pro license with lifetime updates. Press links, Apple-keynote references, and customer reviews. Markets local transcription and user-supplied AI keys.
- **Site technology:** `framerusercontent.com` imagery suggests Framer; checkout uses Gumroad.
- **Distinctive:** sells an encompassing audio-workbench product. **Generic:** broad all-in-one positioning and extensive testimonial material.

## 4. Aqua Voice

- **Hero:** “Speak into your apps.” Subhead: “Aqua transcribes you perfectly and pastes the text where your cursor is.” Navigation CTA: “Get Started on Mac”; hero demo CTA: “Start Free”. [Homepage](https://aquavoice.com/)
- **Section order:** application demo → company logos/social testimonials → speed comparison → coding workflows → messages/email → realtime writing → mobile → feature grid → Avalon benchmark → pricing → final CTA.
- **Visual language:** elaborate Claude Code, Slack, Codex, and other app mockups; an iMac/wave-display image asset. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** shortcut prompt and mode choices in hero; voice-versus-keyboard text race; app-specific scenarios; realtime refinement imagery. Actual microphone behavior **UNVERIFIED**.
- **Pricing/proof:** 1,000 free words; Pro $12/month or $10/month annually; Max $24 or $19 annually; Business $24/seat or $19 annually. Shows testimonials, privacy-mode claims, security credentials, and a linked technical-term benchmark: Avalon 97.4% versus Whisper Large v3 65.1%. These are vendor benchmark results. [Pricing](https://aquavoice.com/pricing)
- **Site technology:** `/_next/image` is a strong Next.js signal.
- **Distinctive:** technical-vocabulary benchmark with a methodology link. **Generic:** speed race and app-logo abundance.

## 5. Willow Voice

- **Hero:** “Speak naturally, Willow writes it”. Subhead **excerpt:** “AI voice dictation that actually works. Speak into any app, and Willow turns it into perfect text…” The remaining clause promises no editing. CTA: “Download for free”. [Homepage](https://willowvoice.com/)
- **Section order:** hero → professional/company proof → statement about work → speed/time figures → Alexis Ohanian testimonial → three-step demonstrations → dictation/Scribe/mobile explanations → features → testimonial wall → final download.
- **Visual language:** Slack, ChatGPT, Notes, Gmail, and iPhone screenshots, plus testimonial portraits. Hero media playback, palette, and fonts **UNVERIFIED**.
- **Dictation demonstration:** focus a field → hold hotkey and speak → release and receive formatted text. Repeats this sequence across messages, prompts, and notes.
- **Pricing/proof:** Basic free; Pro displays $15/$12 per user/month; Business $35/$28; monthly/annual controls and custom Enterprise. Claims 150,000+ professionals, four-times writing speed, five hours reclaimed weekly, offline operation, and security compliance. [Pricing](https://willowvoice.com/pricing)
- **Site technology:** extensive `framerusercontent.com` assets suggest Framer.
- **Distinctive:** consistently teaches the physical interaction in three illustrated steps. **Generic:** perfect-text language and celebrity-founder testimonials.

## 6. VoiceInk

- **Hero:** “Write at the speed of thought”. Subhead **excerpt:** “VoiceInk uses local AI models to instantly transcribe what you say to text…” It continues with accuracy/privacy claims. CTA: “Buy Now”. [Homepage](https://tryvoiceink.com/)
- **Section order:** hero/badges/user proof → app compatibility → email and AI prompting → vocabulary/replacements → cleanup/structured notes/email/selected-text rewriting/journal examples → testimonials → lifetime pricing → FAQ → source/privacy explanation.
- **Visual language:** text/UI examples, privacy/open-source badges, and customer avatars. Hero video, palette, and fonts **UNVERIFIED**.
- **Dictation demonstration:** unusually extensive spoken-input/finished-output examples, including selected-text rewriting and saving a timestamped Markdown journal entry.
- **Pricing/proof:** $25 for one Mac, $39 for two, $49 for three; lifetime updates and 14-day refund. Claims 13,469+ users in hero, 200k+ downloads, and 4.9 average rating elsewhere. FAQ distinguishes local audio transcription from optional cloud processing of the transcript.
- **Site technology:** framework **UNVERIFIED**; JavaScript fallback and Google Tag Manager do not identify it.
- **Distinctive:** concrete rewriting and journal workflows. **Generic:** speed-of-thought headline and testimonial wall.

**Direct relevance:** privacy, open source, optional cloud enhancement, and voice rewriting already overlap substantially with Parla.

## 7. Handy

- **Hero:** “speak into any text field”. Subhead: “the free and open source app for speech to text”. CTA: “download handy apple silicon v0.9.8”. [Homepage](https://handy.computer/)
- **Section order:** short hero/download → demonstration video and transcript → zero-cost rationale → source availability → offline privacy → single-purpose explanation → sponsors → donation options/footer.
- **Visual language:** creator/product walkthrough rather than a large library of marketing mockups. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** actual HTML video with an accessible transcript. CJ explains shortcut activation, hold-and-release, toggle mode, and remapping. The transcript explicitly describes pasting into the active field.
- **Pricing/proof:** free and sponsor-supported; accessibility is the stated reason for avoiding a paywall. Named sponsors include Wordcab, Epicenter, Bolt AI, and Canty Digital. Claims audio stays on the computer.
- **Site technology:** directly served WebM video; framework **UNVERIFIED**.
- **Distinctive:** an exceptionally short page with a human walkthrough and an accessibility argument for its funding model. **Generic:** familiar privacy/source/simplicity benefits, although presented with much less marketing machinery.

## 8. OpenWhispr

- **Hero:** “Privacy first voice assistant for meeting notes and dictation”. Subhead **excerpt:** “Write 3x faster with your voice.” It also introduces bot-free meetings, local operation, open source, and IT buyers. CTA: “Download for free”. [Homepage](https://openwhispr.com/)
- **Section order:** hero/comparison → a16z backing → privacy → model/feature controls → voice instructions → vocabulary/languages → app compatibility → offline → testimonials → compliance → FAQ/download.
- **Visual language:** product tabs, Slack comparison, provider controls, and app logos. Palette/fonts **UNVERIFIED**; a `hero-bg-light.webp` filename does not establish the rendered theme.
- **Dictation demonstration:** speech-to-text/meeting/chat/upload tabs; approximately 40 versus 150 WPM comparison; spoken instruction/output examples.
- **Pricing/proof:** free local models/BYOK, 2,000 hosted words weekly and five meeting hours monthly. Pro $80/year; Business $160/year; Enterprise custom. Shows MIT/source inspection, privacy claims, backing, testimonials, and compliance badges. Certification status **UNVERIFIED**. [Pricing](https://openwhispr.com/pricing)
- **Site technology:** framework **UNVERIFIED**.
- **Distinctive:** personal model choice extends into enterprise deployment controls. **Generic:** keyboard-speed comparison and privacy badges.

## 9. Monologue — Every

- **Hero:** “Builders think out loud.” Subhead **excerpt:** “Monologue is a voice dictation and notes app for Mac and iPhone.” It continues with polished cross-app text, bot-free meetings, and AI-tool connections. CTA: “Download for Mac”. [Homepage](https://www.monologue.to/)
- **Section order:** model announcement → hero/product tabs → employer logos → product introduction → dictation use cases → notes workflow → agent connections → adaptive features → platform support → testimonial → pricing → download.
- **Visual language:** Mac/iPhone email and Messages UI; a dictation-video poster asset supports a video-backed demonstration. Actual playback, palette, and fonts **UNVERIFIED**.
- **Dictation demonstration:** coding, messaging, email, correction, and formatting scenarios; notes become material for AI tools.
- **Pricing/proof:** trial includes 1,000 dictated words and ten recorded notes. Pro $15/month or $144/year; also included in an Every bundle. Uses company logos, Ben Tossell’s endorsement, a three-times speed claim, and offline-model messaging. [Pricing](https://www.monologue.to/pricing)
- **Site technology:** deployment query resembles Vercel identifiers, but this is only an inference; framework **UNVERIFIED**.
- **Distinctive:** a coherent builder audience connects speech, notes, and agent context. **Generic:** logo proof and expansive feature coverage.

## 10. Spokenly

- **Hero:** “Think out loud” / “Work 4x faster”. Subhead **excerpt:** “Dictate prompts, messages, and docs in every app on Mac, Windows, Linux, and iPhone.” Remaining sentence introduces free offline models. Navigation CTA: “Download”; separate hero-body CTA **UNVERIFIED**. [Homepage](https://spokenly.app/)
- **Section order:** user/rating/privacy proof → hero → AI-tool icons → reviews → demonstration video → differentiators → pricing → FAQ → footer.
- **Visual language:** logo, coding-tool compatibility icons, review text, and YouTube demo thumbnail. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** linked video; copy explains streaming text, cleanup, and app-aware formatting.
- **Pricing/proof:** Free includes unlimited local Whisper/Parakeet and BYOK; Local+ $29 once; managed-cloud Pro $12/month billed annually. Claims 100,000+ active users and 4.8 App Store rating. Local-only mode reportedly blocks every network request. [Pricing](https://spokenly.app/pricing)
- **Site technology:** `/_next/image` assets strongly suggest Next.js.
- **Distinctive:** understandable separation of free local/BYOK, paid extras, and managed cloud. **Generic:** productivity multiplier and AI-tool icon row.

## 11. FluidVoice

**Canonical domain: `fluidvoice.com`.** Its homepage explicitly disclaims affiliation with `fluidvoice.org`.

- **Hero:** “Your words. Your device.” Subhead **excerpt:** “FluidVoice turns rough, rambling speech into polished, ready-to-send text. Local by default.” Remaining text identifies Mac availability and Windows/iPhone betas. CTA: “Download for Mac”. [Homepage](https://fluidvoice.com/)
- **Section order:** release/hero → domain warning/proof → videos → terminal simulation → processing pipeline → community metrics → cleanup models → audiences/privacy → features → app-specific tone → performance → testimonials → FAQ/download.
- **Visual language:** macOS setting, terminal recreation, model explanations, and application examples. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** Speed/Accuracy video choices; automatically replaying terminal scenario with Option-key replay; raw-to-clean text and app-tone examples.
- **Pricing/proof:** free forever, sponsorship-supported, GPLv3. Claims 350,000+ downloads and local processing by default. Explains local cleanup models and optional external providers.
- **Site technology:** framework **UNVERIFIED**.
- **Distinctive:** locally executed cleanup gets a concrete model family and pipeline explanation. **Generic:** speed statistics and testimonial/feature grids.

This is a close positioning competitor, not merely another cloud dictation service.

## 12. TypeWhisper

- **Hero:** “Speak once. Keep writing everywhere.” Subhead **excerpt:** “Dictate into your apps and turn spoken thoughts into finished text.” Remaining sentence offers local processing or providers chosen by the user. CTA: “Download for macOS”. [Homepage](https://www.typewhisper.com/en/)
- **Section order:** hero/proof → before/after examples → screen recording → trust principles → screenshot features → local-engine comparison → use cases → add-ons → press → premium features → pricing → FAQ/download.
- **Visual language:** real settings screenshots and email/chat/note examples. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** filler words struck out before finished text; embedded screen recording; screenshots make configuration choices tangible.
- **Pricing/proof:** free GPLv3 core; separate commercial licenses listed from €5/month individual, €19 team, €199 enterprise. Donations are separate. Claims no telemetry/no account, shows 2.1k GitHub stars and press links. [Pricing](https://www.typewhisper.com/en/pricing/)
- **Site technology:** same-origin screenshots; framework **UNVERIFIED**.
- **Distinctive:** engine comparison and add-on ecosystem substantiate provider control. **Generic:** cleaned-text transformation and universal-app promise.

Its explicit user-selected cloud processing is especially close to Parla’s proposed argument.

## 13. Voquill

**Domain caveat:** the root now markets a medical-laboratory product. The general dictation landing page remains at `/dictation/`.

- **Hero:** “Your keyboard is holding you back.” Subhead **excerpt:** “Make voice your new keyboard. Type 4x faster with private, open source AI dictation.” Remaining text lists local, BYOK, hosted, and on-premise options. CTA: “Download for free”. [Dictation page](https://voquill.com/dictation/)
- **Section order:** hero → YC proof → explanatory video → app compatibility → speed comparison → privacy/source → cleanup → offline → pricing → community → final download.
- **Visual language:** text-led page, keyboard/voice comparison, video, and privacy/offline iconography. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** YouTube walkthrough, approximately 45 versus 220 WPM comparison, cleanup explanation.
- **Pricing/proof:** Personal free with local/BYOK; Pro $8/month billed annually; Enterprise custom. YC backing, source link, and offline claims. An annual-price line also appears under custom Enterprise; **actual Enterprise pricing UNVERIFIED**.
- **Site technology:** framework **UNVERIFIED**.
- **Distinctive:** personal local use through enterprise on-premise deployment. **Generic:** keyboard antagonism, speed multiplier, and animated lock.

## 14. Amical

- **Hero:** “Type 4x Faster With Your Voice”. Subhead **excerpt:** “AI-powered speech-to-text that auto-formats your dictation for any app — emails, messages, code and more.” Remaining sentence claims open-source/private/free. CTA: “Download”. [Homepage](https://amical.ai/)
- **Section order:** source banner → hero/app examples → local/cloud/vocabulary/shortcuts/languages → contextual formatting → native-dictation comparison → multilingual reviews → FAQ → download/footer.
- **Visual language:** recreated email, team chat, editor, notes, issue comments, ChatGPT, Discord, and family messaging. Motion, palette, and fonts **UNVERIFIED**.
- **Dictation demonstration:** multiple application fields demonstrate output styles; vocabulary and shortcuts are illustrated; native dictation receives a comparison section.
- **Pricing/proof:** free unlimited local plus 2,000 hosted words weekly. Premium card shows $7/month billed annually; comparison table shows $10/month. Billing interpretation **UNVERIFIED**. Enterprise custom. SOC 2 is explicitly described as in progress. Homepage/mobile availability also conflicts with “soon” in pricing. [Pricing](https://amical.ai/pricing)
- **Site technology:** framework **UNVERIFIED**.
- **Distinctive:** multilingual community proof and varied everyday writing contexts. **Generic:** four-times headline, future-of-dictation framing, and comparison superlatives.

## 15. Typeless — additional competitor

- **Hero:** “Speak, don't type”. Subhead: “Voice dictation that turns messy thoughts into clear writing in any app. 4x faster than typing.” CTA: “Download”. Embedded hero videos are confirmed by HTML fallback text. [Homepage](https://www.typeless.com/)
- **Section order:** hero/speed videos → compatibility icons → dictation cleanup/personalization → translation → selected-text editing/questions/actions → privacy → devices → testimonials → final download → AI-assistant evaluation links.
- **Visual language:** extensive app iconography, feature UI, and video. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** 45 versus 220 WPM comparison videos; correction/formatting explanations; selected-text voice-editing scenarios.
- **Pricing/proof:** Free, Pro, Enterprise. Pro $30 monthly or $12/month billed annually. Claims zero cloud retention, no model training, local history, security compliance, and one day saved weekly. Displays Product Hunt awards and named testimonials. [Pricing](https://www.typeless.com/pricing)
- **Site technology:** custom static-asset domain; framework **UNVERIFIED**.
- **Distinctive:** selected read-only text can become the subject of spoken questions and actions. **Generic:** speak-instead-of-type headline and speed race.

Local history storage should not be mistaken for verified local transcription.

## 16. BetterDictation — additional competitor

- **Hero:** “Type so fast your boss will think there's 3 of you”. Subhead **excerpt:** “Meet your personal scribe.” Remaining text promises cross-app dictation in 100+ languages. CTA: “Buy Now”. Hero includes an embedded video. [Homepage](https://betterdictation.com/)
- **Section order:** hero → company proof → day-in-the-life app examples → accuracy → punctuation → speed/race → accents/languages → optional cleanup → testimonials → pricing → upgrade → FAQ.
- **Visual language:** Mail/Slack/Claude/Notes scenarios, comparison text, video, and customer portraits. Palette/fonts **UNVERIFIED**.
- **Dictation demonstration:** timed everyday tasks; punctuation before/after; typing race; messy speech becomes a structured message.
- **Pricing/proof:** $39 lifetime single-device, $49 three-device, $149 ten-device; optional Pro cleanup $2/month billed annually, with per-device terms for Studio. Claims 6,000+ users and local base transcription. FAQ says Pro requires internet.
- **Site technology:** framework **UNVERIFIED**.
- **Distinctive:** prices the local app and optional hosted cleanup separately. **Generic:** speed-of-thought messaging and absolute accuracy language.

## Synthesis: what Parla should take from this

### Category clichés

No single cliché appears on every site. Handy is a clear counterexample to the large SaaS landing-page pattern. These devices nevertheless recur heavily:

| Repeated device | Examples | Implication for Parla |
|---|---|---|
| Speaking-versus-typing multiplier | Wispr, Aqua, Willow, Spokenly, Amical, Typeless | Another unexplained multiplier will contribute little. |
| Keyboard framed as the obstacle | Voquill, Typeless, BetterDictation | Show the useful interaction immediately. |
| Messy speech becomes polished prose | Wispr, VoiceInk, TypeWhisper, BetterDictation | Useful evidence, but already standard category education. |
| Compatibility expressed through logo abundance | Superwhisper, Aqua, Spokenly, Typeless | A few demonstrated target apps can communicate more clearly. |
| Privacy summarized by badges or ownership language | OpenWhispr, Voquill, VoiceInk | Explain the actual audio/transcript route. |
| Famous-person proof and long testimonial walls | Wispr, Superwhisper, Willow | Use attributable, task-specific evidence when available. |

These patterns are visible across the linked [Wispr](https://wisprflow.ai/), [Aqua](https://aquavoice.com/), [TypeWhisper](https://www.typewhisper.com/en/), and [Voquill](https://voquill.com/dictation/) pages.

### What is already occupied

**Parla should not claim exclusive ownership of local + BYOK + open source.** OpenWhispr, FluidVoice, TypeWhisper, Voquill, and Amical market overlapping combinations. VoiceInk also overlaps on local transcription, optional cloud enhancement, open source, and selected-text rewriting. These are deliberate marketing themes, not obscure documentation details. [OpenWhispr](https://openwhispr.com/), [FluidVoice](https://fluidvoice.com/), [TypeWhisper](https://www.typewhisper.com/en/)

Likewise, **text appearing in the focused app is category-standard positioning**. The potentially valuable distinction is the insertion mechanism and its observable consequences. Aqua, Superwhisper, and Handy explicitly describe pasting; other sites’ use of “type” or “insert” does not establish their underlying mechanism. [Aqua](https://aquavoice.com/), [Superwhisper](https://superwhisper.com/), [Handy](https://handy.computer/)

### Underused positions that fit Parla

I did **not** establish a wholly unoccupied feature position. These are promising presentation opportunities, with exclusivity **UNVERIFIED**:

1. **A clearly explained two-stage privacy promise.**  
   Explain that whisper.cpp transcribes audio on the Mac. Separately explain that optional cleanup sends the transcript to the user’s selected provider—or to local Ollama. Put this beside the demo. Avoid an unconditional all-local claim when external cleanup is enabled.

2. **Demonstrated clipboard preservation.**  
   No explicit preservation test was found in the inspected page text, transcripts, or demo descriptions. Videos were not exhaustively watched, so “nobody demonstrates this” remains **UNVERIFIED**. If Parla preserves the clipboard in the demonstrated path, prove it visibly.

3. **A small, understandable macOS utility.**  
   Several competitors now market dictation alongside meetings, notes, agents, enterprise administration, and cross-device services. Parla can present a tightly bounded interaction: hold, speak, release; select, command, rewrite. This is a positioning recommendation, not a unique-feature claim.

4. **Control that appears approachable.**  
   Show the default local experience first. Introduce provider choice as an optional improvement with a clear data route. A provider-logo wall alone makes setup look more complicated.

## Recommendations for Parla

### Positioning line options

These are new drafts based on the product brief, not competitor quotations.

**Recommended**

> **Speak. Parla types at your cursor.**

Supporting copy:

> Hold a hotkey, speak, and release. Parla transcribes on your Mac and types into the app you’re using. Add cleanup with your own AI provider when you want it.

**Privacy-led**

> **Dictation on your Mac. Cleanup on your terms.**

Supporting copy:

> Transcribe locally with whisper.cpp. Keep the transcript as spoken, refine it with your own provider, or use Ollama locally.

**Utility-led**

> **A small menu-bar app for the words you’d rather say.**

Supporting copy:

> Dictate into your focused app, then select text and tell Parla how to rewrite it. Open source, with optional AI cleanup using your own key.

Use **“Download for macOS”** as the primary CTA and **“View source”** as the secondary link. Place the signed-DMG detail, version, and verified system requirements beside the download.

### Recommended section order

1. **Hero with the real interaction.** Positioning line, short explanation, download, source link, and immediately visible demo.
2. **Hold → speak → release.** Explain the physical interaction with three small states.
3. **Where your words go.** A simple diagram showing local audio transcription and the optional transcript-cleanup route.
4. **Rewrite selected text by voice.** Show one concrete command and its replacement in the original app.
5. **Choose cleanup when useful.** Show raw transcription, cleaned output, and provider selection. Distinguish hosted providers from local Ollama.
6. **Open source and ready to install.** Signed DMG, release history, source, license, and a brief permissions explanation.
7. **A few demonstrated apps.** Show tested examples instead of making an unqualified universal-compatibility promise.
8. **Cost and requirements.** State Parla’s actual distribution terms, external API billing, model downloads, and hardware support.
9. **Short FAQ and final download.** Cover offline use, cleanup data, command mode, and supported systems. Label Android/Linux as **in progress**.

Avoid making roadmap platforms look available.

### The single most persuasive demo device

**One short, uncut screen recording in a real Mac app, with audible speech, a visible hotkey indicator, and a clipboard check.**

Suggested sequence:

1. Copy a distinctive phrase before starting.
2. Focus a real email or note.
3. Hold the hotkey and dictate with cleanup disabled.
4. Release; show the actual processing delay and text insertion.
5. Paste the previously copied phrase to demonstrate clipboard preservation.
6. Select a sentence and speak a rewrite command.
7. Show the replacement, with the actual cleanup provider identified.

Keep the recording at normal speed. Label recorded media clearly; a keyboard-triggered replay should not be presented as live microphone input.

This single device can substantiate Parla’s interaction, local transcription, direct typing, clipboard behavior, and command mode. Those observable details give the visitor more evidence than another waveform or speed multiplier.