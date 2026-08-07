# Parla Flow UI Clone Spec

> **What this file is:** static inspection of a competitor's shipped app —
> Parla Flow 1.5.1146, read out of the installed Electron bundle — kept as
> visual and reference material. It is not a Parla roadmap and nothing in it is
> a commitment. In use: the Visual Identity tokens and the Flow Bar spec, which
> the Hub window and the HUD pill were built from. Account, Teams,
> Plans/Billing, Connectors, MCP, Notetaker/meetings, calendar reminders, and
> the onboarding tour describe features Parla has no backing for.

Source inspected locally:
- Installed app: `/Applications/Parla Flow.app`
- Version: 1.5.1146
- Downloaded DMG found: `Flow-v1.5.1095.dmg`

Scope note: this is based on static inspection of the installed Electron app, extracted renderer bundles, bundled assets, localization labels, app database schema, and representative assets. I did not launch the app or interact with live authenticated screens.

## Product Shape

Parla Flow is not one window. It is a set of small desktop surfaces plus a larger settings/dashboard hub:

- Flow Bar / overlay: the always-available dictation control.
- Hub: main desktop app for history, notes, settings, plan, team, connectors, dictionaries, and setup.
- Scratchpad: rich note editor.
- Meeting Recorder / Notetaker: live recording, transcript, notes, chat/summary surface.
- Calendar reminder: lightweight upcoming-meeting prompt.
- Context menu: compact command palette-style menu.
- Feature tour / onboarding: first-run education, permissions, setup, personalization.
- Status window: transient status/toast/notification surfaces.

## Visual Identity

Overall mood:
- Soft, calm desktop utility.
- Mostly off-white and sand surfaces.
- Dark graphite text, low-contrast borders.
- Purple/lavender accent for brand, upgrade, highlight, and “AI magic” moments.
- Coral/red used for recording stop/error/destructive actions.
- Green used for success/connected states.

Core colors from bundled CSS:

```css
--sand-50: #fcfcfb;
--sand-100: #faf9f7;
--sand-200: #f8f7f3;
--sand-300: #f7f6f2;
--sand-500: #f5f4f0;
--sand-600: #eeebe3;
--sand-950: #4d4a42;

--vast-900: #30302f;
--vast-950: #1a1a1a;

--brand-50: #fdfbff;
--brand-100: #fcf7ff;
--brand-300: #f7ebff;
--brand-500: #f0d7ff;
--brand-700: #a26ec1;
--brand-800: #6c358c;
--brand-950: #3c2947;

--red-500: #ef4444;
--green-500: #10b981;
--blue-500: #3b82f6;
--pink-500: #ffbcf2;
--yellow-400: #facc15;
--fathom-950: #034f46;

--success-500: #4fbf78;
--warning-400: #ffd467;
--destructive-500: #ee6a6a;
```

Dark mode tokens exist. Dark mode flips neutral surfaces to near-black and keeps lavender/green accents brighter.

Fonts referenced:
- Primary UI: Figtree or Manrope.
- Platform fallback: `SF Pro Text`, `Segoe UI`, sans-serif.
- Serif accent: EBGaramond.
- Code/monospace: GoogleSansCode, Menlo, Consolas, Monaco.

Recommended clone typography:
- App body: 13-14px, medium line height, Figtree.
- Sidebar items: 13-14px, medium weight.
- Page title: 22-28px, semibold.
- Section headings: 13-15px, semibold.
- Supporting descriptions: 12-13px, muted sand/vast gray.
- Small labels/chips: 11-12px.

Radii and surfaces:
- App cards/settings rows: 8-12px radius.
- Flow Bar: large pill radius, fully rounded.
- Buttons: 8-10px radius.
- Icon buttons: circular or rounded square.
- Modal/dialog: 14-20px radius, soft shadow.

## Core Components

### Flow Bar

The most recognizable UI element.

Observed asset: `images/flow-bar-listening.png`, 205x60.

Listening state:
- Black rounded pill container.
- Thin purple-ish outer glow/ring.
- Left circular cancel button: gray circle with white X.
- Center waveform: white vertical bars/dots, animated while recording.
- Right circular stop button: coral/pink circle with white square stop icon.
- Compact height around 44-60px.
- Should float above other apps.

States to implement:
- Idle: small pill/mic affordance.
- Listening: waveform active, cancel and stop visible.
- Processing: spinner/progress or “processing” state.
- Success/paste: brief confirmation.
- Error: red/error toast or status.
- Hidden for one hour.
- Meeting recording state.
- Screen-share-hidden mode.

### Hub Shell

HTML shell uses full height/width and hidden body overflow.

Suggested layout:
- Left sidebar: fixed width around 220-280px.
- Main content: scrollable settings/detail pane.
- Background: white or sand.
- Sidebar: sand/near-white, subtle right border.
- Sidebar bottom/status area: update status, account/team/plan shortcuts.

Sidebar pages found:
- Account
- Connectors
- Data and Privacy
- General
- MCP
- Notetaker
- Plans and Billing
- System
- Team
- Experimental
- Extensions
- Internal
- Testing
- Vibe coding

Likely sidebar item anatomy:
- Icon on left.
- Label.
- Active state with filled pale sand/lavender row.
- Optional badge/lock/update indicator.

### Settings Row

Common pattern:
- Section heading.
- Row/card with label on the left.
- Description under label.
- Control on the right.
- Controls include toggle, select, button, keyboard shortcut pill, segmented option, or chevron.
- Rows separated by thin borders or vertical spacing.

Implement row variants:
- Toggle row.
- Button row.
- Select/dropdown row.
- Shortcut-capture row.
- Danger row.
- Upgrade-gated row.
- Connected integration row.

### Dialogs / Modals

Common modal anatomy:
- Centered card over dim backdrop.
- Title.
- Subtitle/body.
- Primary action.
- Secondary/cancel action.
- Destructive actions in red.
- Confirmation dialogs for sign out, delete account, delete transcripts, reset app.

### Toasts / Notifications

Status surfaces include:
- Success toast.
- Error toast.
- Progress/loading toast.
- Action toast with CTA.
- Meeting detected notification.
- Summary ready notification.
- Transcript recovery notification.

Notification center modal:
- Title: Notifications.
- Filters: New, Archived.
- Actions: Archive, Archive all, Mark all as read.
- Empty state: “No notifications yet”.
- Caught-up state.

## Hub Pages

### Account

UI elements:
- Page title: Account.
- Profile picture uploader.
- First name input.
- Last name input.
- Email label/field.
- Save button.
- Sign out button.
- Delete account button.

States:
- Profile updated success.
- File too large, maximum 5MB.
- Could not read selected file.
- Could not save/update profile photo.
- Validation: first and last name cannot be empty.
- Validation: name looks like password.
- Sign out confirmation.
- Delete account confirmation.

### General

UI elements:
- Page title: General.
- App Language setting.
- Dictation Languages setting.
- Microphone setting.
- Shortcuts setting.

Language dialog:
- Search language input.
- System Default option for app language.
- Dictation option: Auto-detect (99 languages).
- Selected language preview: “x and n more”.
- Empty state: no matches/no languages selected.

Microphone dialog:
- Title: Microphone.
- Subtitle: used for dictation; Notetaker uses auto-detect.
- Device list.
- Recommended built-in mic style.
- Device ranking/preference editing.
- Forget/remove device.
- Bluetooth/AirPods warning states.

Shortcuts dialog:
- Title: Shortcuts.
- Subtitle about choosing preferred shortcuts.
- Hint: Hold [shortcut] and speak.
- Shortcut rows with current keybinding, change/reset controls.

Shortcut actions to include:
- Push to talk.
- Hands-free mode.
- Cancel.
- Paste last transcript.
- Command Mode.
- Instruct Mode.
- Transform.
- Open Scratchpad.
- Join meeting / start recording.
- Press Enter.
- Focus Mode.
- Mouse Flow.

### System

Sections:
- App settings.
- Sound.
- Notifications.
- Data.
- Extras.
- Scratchpad.
- Notetaker.

App settings:
- Launch app at login.
- Show app in dock.
- Show Flow Bar at all times.
- Reset app.

Sound:
- Dictation and notification sounds.
- Mute music while dictating.

Extras:
- Creator mode: show “Dictating with Parla Flow” when dictating.
- Email auto signature.
- Add Parla Flow to LinkedIn.

Email signature states:
- Disabled description: add signature when dictating email.
- Enabled description with signature body.
- Signature options: “Spoken with Parla Flow”, “Written with Parla Flow”.

Dictation reminder:
- Modes: Off, all apps, specific apps, previously used apps.
- Specific app categories:
  - AI apps.
  - Email.
  - Work messengers.
  - Personal messengers.
  - Documents and notes.

Smart Formatting:
- Toggle.
- Description: automatically formats dictation.

Reset app dialog:
- Title: Reset and restart?
- Body: deletes local data; dictionary, stats, settings re-sync on restart.
- CTA: Reset & restart.

### System / Notetaker Settings

Meeting detection:
- Calendar reminders.
- When meeting detected: Notify me / Do nothing.
- Auto Detect.

Recording:
- Auto-end recording.
- Maximum recording length:
  - 30 minutes
  - 1 hour
  - 2 hours
  - 4 hours
  - 6 hours
- Recording window.
- Auto-start recording on new note.
- Open notepad automatically.
- Split-screen on join.
- Change shortcut for join/start recording.
- Hide during screen sharing.

Transcript:
- Live transcript toggle.
- Speaker names toggle.
- Auto-detect speaker names toggle.

### Notetaker Page

Separate page title: Notetaker.

Appearance:
- Transcript and Chat text size.
- Options: Regular, Compact.

### Data And Privacy

UI elements:
- Page title: Data and Privacy.
- Privacy Mode toggle/card.
- Private Cloud Sync controls.
- Local data retention controls.
- Notetaker transcript retention controls.
- HIPAA Business Associate Agreement dialog.
- Delete all transcripts.
- Delete account.
- Refresh/sync notes.

Privacy mode description:
- Dictation data not used to train or improve AI models by Parla or third parties.

Retention options:
- Local dictation storage: store locally, auto-delete every 24 hours, never store locally.
- Notetaker retention: 1 day, 7 days, 30 days, 90 days, 180 days, 365 days, never delete.

States:
- Notes refreshed.
- Syncing notes.
- Failed to refresh notes.
- HIPAA enabled/revoked/locked by org.

### Team

UI elements:
- Create team flow.
- Join/request/rejoin team flow.
- Team member table.
- Invite teammates flow.
- Admin portal link.
- Team FAQ/contact links.
- Team logo.

Create team flow:
- Add team name.
- Invite users by email.
- Auto-add future users from same domain.
- Accept/decline invite.
- Success timeline: today and day 15 billing message.
- Trial unavailable warning.

Member management:
- Tabs:
  - Team members.
  - Requests.
  - Other users on your domain.
- Table columns:
  - Name.
  - Role.
  - Status.
- Roles:
  - Member.
  - Admin.
  - IT admin.
  - Super admin.
- Status:
  - Active.
  - Pending.
  - In trial, ends date.
- Actions:
  - Add.
  - Add new user.
  - Approve.
  - Deny.
  - Contact admins.
  - Add billing info.

States:
- No users found.
- SCIM-managed users.
- Request submitted/declined/auto-accepted.
- Rejoin team.
- Team unavailable.

### Connectors

UI elements:
- Page title: Connectors.
- Integration rows/cards with icon, name, description, status, button.
- Buttons:
  - Connect.
  - Connected.
  - Reconnect.
  - Loading.

Connectors found:
- Google Calendar.
- Gmail / Google Automations.
- GitHub.
- Linear.
- Notion.
- Slack.

Descriptions:
- Google Calendar enables calendar tool integrations.
- Gmail/Google Automations enable email and calendar automation integrations.
- GitHub enables GitHub tool integrations.
- Linear enables project management integrations.
- Notion enables Notion tool integrations.
- Slack enables Slack workspace integrations.

### MCP

UI elements:
- Page title: MCP.
- Lead text: connect Parla Flow to AI tools so you can work with notes anywhere.
- Server URL field.
- Copy server URL button.
- Learn more link.
- Three-step instructions:
  - Add Parla Flow MCP to AI tool using URL.
  - Sign in through browser to authorize.
  - Chat, search, and work with notes anywhere.

States:
- URL copied to clipboard.
- Could not copy URL.

### Vibe Coding

UI elements:
- File Tagging in Chat toggle/card.
- Variable recognition toggle/card.
- Setup button for variable recognition.
- Setup dialog.

Setup dialog:
- Title: Set up variable recognition.
- Subtitle: reads open file to better understand code as you dictate; requires Screen Reader mode in IDE.
- Steps:
  - Open Command Palette.
  - Search for and run command.
  - Confirm “Screen Reader Optimized” flag appears in bottom bar.

Supported apps mentioned:
- Cursor.
- Windsurf.
- VS Code.

### Experimental / Extensions / Internal / Testing

These are likely feature-flagged/developer surfaces.

Testing page elements found:
- Feature Flags section.
- Select a flag.
- Enabled/disabled state.
- Variant input.
- Apply.
- Reset.
- Reset all flags to server values.
- Onboarding test controls:
  - Restart Onboarding.
  - Preserve intents when restarting.
  - Reset Style Personalization.

## History UI

Expected in Hub:
- Transcript list.
- Search/filter.
- Per-row transcript text.
- App/source metadata.
- Timestamp.
- Duration/word count/stats.
- Copy button.
- More menu.

History menu actions:
- Copy transcript.
- Send feedback.
- More options.
- Retry transcript.
- Delete transcript.
- Extract audio.
- Undo AI edit.
- Redo AI edit.
- View history row.
- Cancel/delete confirmation.

States:
- Cancelled transcript tooltip with recovery instruction.
- Cannot retry while dictating.
- Cannot retry because audio older than 14 days.
- Retry failed.

## Scratchpad UI

Window:
- Separate renderer titled Scratchpad.
- Rich text editor.
- Note/tab model.
- Pinned notes.
- New note and resume last note behavior.

Editor formatting classes found:
- Paragraph.
- H2 / H6 headings.
- Bold.
- Italic.
- Underline.
- Strikethrough.
- Inline code.
- Quote.
- Horizontal rule.
- Ordered list.
- Unordered list.
- Nested list.
- Checklist checked/unchecked.
- Table and table header cell.
- Link.
- Image.
- Collapsible container/title/content.
- Citation/elaboration popover.

Scratchpad settings:
- Resume last note.
- Open last active pinned note.
- Open in new tab.
- Always open new tab behavior.

Data model confirms:
- Notes.
- Note versions.
- Note images.
- Searchable content.
- Pinned/finalized/deleted/synced states.

## Meeting Recorder / Notetaker UI

Window:
- Separate renderer titled Meeting Recorder.
- Notepad plus live transcript.
- Recording controls.
- Mic/system audio capture states.
- Meeting summary/chat/actions after recording.

Core controls:
- Start recording.
- Resume recording.
- Stop recording.
- View meeting.
- Copy meeting as Markdown.
- Transcript view.
- Notes editor.
- Ask/chat about meeting.
- Share notes.
- Visibility controls.
- Speaker assignment.

Meeting detection prompts:
- Google Meet detected.
- Zoom detected.
- Teams detected.
- Slack meeting detected.
- Webex detected.
- Generic meeting detected.
- Actions: Start Notetaker, Dismiss.

Nudge prompts:
- “Transcribe this meeting with Flow?”
- “In a meeting? Let Flow take notes.”
- Actions: Start Notetaker, Try it out, Remind me later, Don’t remind me.

Recording states:
- Recording started.
- Connection lost, recording saved.
- Recording did not start, retry.
- Stopped meeting, recording saved.
- Stopped meeting, nothing recorded.
- Summary ready.
- Auto-start nudge after quick stops.
- Auto-start disabled toast.

Audio health states:
- Mic no audio detected.
- Escalated no-audio warning.
- System audio turned off.
- Actions: microphone settings, ignore, turn on system audio.

Screen share state:
- Educational toast/modal explaining Flow Bar recording state and Notepad are hidden from screen share.

Cloud sync state:
- Meeting saved only on this device.
- CTA to turn on Private Cloud Sync.

Retention state:
- Admin-set Notetaker transcript retention notice.

## Context Menu UI

Separate transparent renderer titled Context Menu.

Likely compact menu/palette surface:
- Transparent body.
- Search input.
- List sections.
- Row actions.
- Keyboard-focused navigation.

Context menu features found:
- Auto Apply After Dictation toggle.
- Configure transforms.
- Effective language picker:
  - Add more.
  - Enable all.
- Link fetch/recent links menu:
  - Search links.
  - Recents.
  - Pinned.
  - Copy only.
  - Open and copy.
  - Pin/unpin.
  - Remove.
  - Empty states for no copied links, no recent links, no matches.

## Command / Transform UI

Command Mode:
- Disabled state with “Go to settings”.
- Busy-server state.
- Upgrade-to-Pro state.

Transform / Polish:
- Highlight text then press shortcut.
- No-selection first-time help.
- Textbox detection failed.
- Max words error: under 1000 words.
- Timeout error.
- Empty response error.
- No changes state.
- Auto edit ready with Reveal edit.
- Cancelled state.
- Running state blocks dictation.
- Servers busy state.
- Not editable state saves text to clipboard.

UI pattern:
- Small floating status card/toast.
- CTA button for reveal/settings/upgrade/retry.
- Transform name injected into messages.

## Onboarding / Feature Tour

Window:
- Transparent body, renderer titled Feature Tour.
- Uses video/GIF posters and onboarding assets.

Flow:
- Sign up.
- Permissions.
- Set up.
- Learn.
- Personalize.
- Get started.

Onboarding video:
- Watch short video to get the most out of Flow.
- Try Flow in another app.
- Steps:
  - Go to any app.
  - Click a text box.
  - Hold push-to-talk shortcut.
- Buttons:
  - Next.
  - Finish.
  - Skip.
  - Keep watching.

Personalization:
- Work messages.
- Personal messages.
- Emails.
- Other apps.
- Skip option.

Assets:
- `videos/onboarding_gifs/ptt.gif`
- `videos/onboarding_gifs/popo.gif`
- `videos/onboarding_gifs/speak.gif`
- `videos/onboarding_gifs/whisper.gif`
- `illustrations/whispering.gif`
- `illustrations/keyboard-rollerskate.gif`
- `images/login_page_background.png`

## Calendar Reminder UI

Separate transparent renderer titled Calendar Reminder.

Expected anatomy:
- Small floating card.
- Upcoming meeting name/time.
- App/platform icon if available.
- CTA to join/start recording.
- Dismiss/snooze action.
- Integrates with Notetaker calendar reminders.

## Assets To Mirror

Logos and product images:
- `images/flowLogo.png`, 427x123.
- `logos/parla-logo.png`, 256x256.
- `tray/TrayIconMac@2x.png`, 32x32.
- `tray/TrayIconWindows.png`, 32x32.
- `images/flow-bar-listening.png`, 205x60.

App logos bundled:
- ChatGPT, Claude, Gmail, Google Calendar, Google Docs, Google Meet, Google Drive.
- Slack, Notion, Linear, GitHub, Teams, Zoom, Webex.
- Cursor, VS Code, Windsurf-adjacent assets, terminal, JetBrains.
- WhatsApp, iMessage, Discord, Telegram, Messenger, LinkedIn, X, Reddit.
- Chrome, Safari, Firefox, Arc, Brave.
- Word, Excel, PowerPoint, OneNote.

Icon categories:
- Account, settings, system, team, data/privacy, billing, dictionary, snippets.
- Mic, waveform, stop, play, keyboard, mouse.
- Search, copy, share, edit, delete, upload/download, refresh.
- Bell, announcement, archive, feedback, support.
- Wand/sparkles/polish for AI transform features.
- Plug/connectors.
- Crown/lock for Pro/upgrade-gated features.

## Database-Backed UI Areas

Local database tables suggest these UI modules:
- `History`: dictation transcripts/history.
- `Dictionary`: custom words, replacements, snippets.
- `Polish`: transform/polish runs.
- `Notes`, `NoteVersions`, `NoteImages`: Scratchpad.
- `Meetings`, `MeetingVersions`: Notetaker.
- `Todos`: meeting/action tasks.
- `CalendarEvents`: reminders and meeting context.
- `Links`: fetched/pinned/recent links menu.
- `Automations`: Gmail/calendar automations.
- `InstructHistory`, `InstructChatSession`: instruct/chat UI.
- `UserContext`, `UserVoicePreferences`: personalization and style.

## End-To-End Clone Checklist

Build these in order:

1. Design tokens: colors, typography, spacing, radii, shadows, dark mode.
2. Shared shell: sidebar, page header, settings section, settings row, buttons, toggles, selects, shortcut pills, dialogs, toasts.
3. Flow Bar: idle/listening/processing/success/error/meeting states.
4. Hub pages: General, System, Account, Data/Privacy, Plans/Billing, Team, Connectors, MCP, Notetaker, Vibe Coding.
5. History screen with transcript rows and row action menu.
6. Dictionary/snippets management.
7. Scratchpad rich editor with notes list, pinned notes, images, formatting.
8. Meeting recorder with live transcript, notepad, audio warnings, recording controls, summary/chat/tasks.
9. Context menu command palette with transforms, language picker, recent/pinned links.
10. Onboarding and feature tour.
11. Calendar reminder and meeting-detected nudges.
12. Notification center and transient status/toast system.
13. Plan/team gating states: free/pro/student/enterprise, locks, trial, past due, team admin roles.

## Practical Implementation Notes

Recommended clone stack:
- Electron or Tauri for desktop shell.
- React for renderer UI.
- Zustand/Jotai/Redux for state.
- SQLite for local persistence.
- TipTap/Lexical for Scratchpad rich editor.
- CSS variables for theme tokens.
- Framer Motion or CSS animations for Flow Bar waveform/toasts.
- Native global shortcuts for push-to-talk and command/transform shortcuts.

Do not reuse proprietary Parla Flow assets or copied code unless you have rights. For a clean clone, recreate assets with the same functional role and visual proportions, but use your own artwork/icons/logos.

