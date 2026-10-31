const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ---------- hero: hold the pill (or Space) to dictate ---------- */
const takes = [
  { raw: 'so um can we move the review to five, actually make it six', clean: 'Can we move the review to six?' },
  { raw: 'uh tell priya the build is green and um the release notes are in the doc', clean: 'Tell Priya the build is green, and the release notes are in the doc.' },
  { raw: 'okay three things first fix the login bug second update the docs third ship it', clean: 'Three things:\n1. Fix the login bug\n2. Update the docs\n3. Ship it' },
];
const pill = $('#hero-pill'), pillLabel = $('#pill-label'), out = $('#hero-out'), said = $('#hero-said');
const cleanupSwitch = $('#hero-cleanup'), cleanupRead = $('#cleanup-read');
let take = 0, holding = false, timers = [];
const later = (fn, ms) => timers.push(setTimeout(fn, ms));
const clearTimers = () => { timers.forEach(clearTimeout); timers = []; };
const cleanupOn = () => cleanupSwitch.getAttribute('aria-checked') === 'true';

function typeInto(el, text, done) {
  el.classList.add('is-typing');
  if (reduced) { el.textContent = text; el.classList.remove('is-typing'); return done?.(); }
  // ponytail: Parla pastes in one go; the type-on only makes the arrival readable here.
  let i = 0;
  const step = () => {
    i = Math.min(text.length, i + 2);
    el.textContent = text.slice(0, i);
    if (i < text.length) later(step, 18); else { el.classList.remove('is-typing'); done?.(); }
  };
  step();
}

function startHold() {
  if (holding) return;
  holding = true; clearTimers();
  const words = takes[take].raw.split(' ');
  pill.classList.add('is-live');
  pillLabel.textContent = 'Listening';
  out.textContent = ''; out.classList.add('is-typing');
  let n = 0;
  const speak = () => {
    if (!holding) return;
    n += 1;
    said.textContent = `You said: “${words.slice(0, n).join(' ')}${n >= words.length ? '”' : ''}`;
    if (n < words.length) later(speak, 140);
  };
  speak();
}

function endHold() {
  if (!holding) return;
  holding = false; clearTimers();
  const t = takes[take];
  said.textContent = `You said: “${t.raw}”`;
  pill.classList.remove('is-live');
  pillLabel.textContent = 'Transcribing…';
  later(() => { pillLabel.textContent = cleanupOn() ? 'Formatting…' : 'Pasting…'; }, 350);
  later(() => typeInto(out, cleanupOn() ? t.clean : t.raw, () => {
    pillLabel.textContent = 'Pasted';
    later(() => { pillLabel.textContent = 'Hold to talk'; }, 1800);
  }), 900);
  take = (take + 1) % takes.length;
}

pill.addEventListener('pointerdown', (e) => { pill.setPointerCapture(e.pointerId); startHold(); });
pill.addEventListener('pointerup', endHold);
pill.addEventListener('pointercancel', endHold);
pill.addEventListener('keydown', (e) => { if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); e.stopPropagation(); startHold(); } });
pill.addEventListener('keyup', (e) => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); endHold(); } });
// Space anywhere on the first screen, unless the visitor is in a field or on a control.
const busyTarget = (el) => el.closest?.('input, textarea, [contenteditable], button, a');
const heroVisible = () => $('.hero').getBoundingClientRect().bottom > innerHeight * 0.4;
addEventListener('keydown', (e) => { if (e.code === 'Space' && !e.repeat && !busyTarget(e.target) && heroVisible()) { e.preventDefault(); startHold(); } });
addEventListener('keyup', (e) => { if (e.code === 'Space' && holding) { e.preventDefault(); endHold(); } });

cleanupSwitch.addEventListener('click', () => {
  const on = !cleanupOn();
  cleanupSwitch.setAttribute('aria-checked', String(on));
  cleanupRead.textContent = on ? 'On' : 'Off';
  const last = takes[(take + takes.length - 1) % takes.length];
  if (!holding) { clearTimers(); typeInto(out, on ? last.clean : last.raw); }
});

/* ---------- showcase: a tiny in-browser cleanup ---------- */
// ponytail: a handful of rules so the box answers back; the real cleanup is an LLM with context.
const FILLERS = /\b(?:um+|uh+|erm|hmm|you know|like,)\s*/gi;
const LEADS = /^(?:so|okay|ok|well|alright)\b[,\s]*/i;
const BACKTRACK = /[,\s]+(?:actually|no wait|sorry|scratch that)[,\s]+(?:make it\s+)?/i;
const ORDINALS = /\b(?:first|second|third|fourth|fifth)\b/i;
const QUESTION = /^(?:can|could|should|would|will|is|are|do|does|did|what|when|where|why|how|who)\b/i;
const NAMES = { priya: 'Priya', parla: 'Parla', slack: 'Slack', github: 'GitHub', monday: 'Monday', tuesday: 'Tuesday', wednesday: 'Wednesday', thursday: 'Thursday', friday: 'Friday' };

const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const tidy = (s) => s.replace(/\s+/g, ' ').replace(/\s+([,.?!:])/g, '$1').trim();

function clean(input) {
  let s = tidy(` ${input} `.replace(FILLERS, ' ')).replace(LEADS, '');
  // "five, actually six": the correction replaces the same number of words before the marker
  for (let m; (m = BACKTRACK.exec(s)); ) {
    const before = s.slice(0, m.index).split(' ');
    const rest = s.slice(m.index + m[0].length).split(' ');
    const fix = rest.splice(0, 1);
    before.splice(before.length - fix.length, fix.length, ...fix);
    s = [...before, ...rest].join(' ');
  }
  s = s.replace(/\b\w+\b/g, (w) => (w === 'i' ? 'I' : NAMES[w.toLowerCase()] ?? w));
  const parts = s.split(new RegExp(ORDINALS.source, 'gi'));
  if (parts.length >= 3) {
    const head = tidy(parts[0]).replace(/[,:]$/, '');
    const items = parts.slice(1).map((p) => cap(tidy(p).replace(/[,.]$/, ''))).filter(Boolean);
    return `${head ? cap(head) + ':\n' : ''}${items.map((it, i) => `${i + 1}. ${it}`).join('\n')}`;
  }
  s = tidy(s.replace(/,?\s+and\s+/i, ', and ')).replace(/[,.]+$/, '');
  return s ? cap(s) + (QUESTION.test(s) ? '?' : '.') : '';
}

const saidInput = $('#said'), answer = $('#answer');
const showAnswer = () => { answer.textContent = clean(saidInput.value) || '…'; };
saidInput.addEventListener('input', showAnswer);
$$('.example').forEach((b) => b.addEventListener('click', () => {
  saidInput.value = b.dataset.say; showAnswer();
  saidInput.focus(); saidInput.setSelectionRange(saidInput.value.length, saidInput.value.length);
}));
showAnswer();

/* ---------- features: the output follows the controls ---------- */
const state = { app: 'mail', command: 'none', dict: true, snip: true };
const body = {
  none: (n, k, cal) => [`The ${k} migration is done and the staging cluster is back up.`, `${n}, could you look over the alerts before Friday? ${cal}`],
  short: (n, k, cal) => [`${k} migration done, staging is up.`, `${n}, alerts review before Friday? ${cal}`],
  warm: (n, k, cal) => [`Good news: the ${k} migration is done, and the staging cluster is happily back up.`, `${n}, whenever you have a moment before Friday, would you mind looking over the alerts? ${cal}`],
  es: (n, k, cal) => [`La migración de ${k} está terminada y el clúster de staging vuelve a funcionar.`, `${n}, ¿podrías revisar las alertas antes del viernes? ${cal}`],
};
const frame = { none: ['Hi', 'Thanks,'], short: ['Hi', ''], warm: ['Hi', 'Thanks so much,'], es: ['Hola,', 'Gracias,'] };
const calLine = { none: 'Grab any slot that suits you: cal.com/daksh/30', short: 'cal.com/daksh/30', warm: 'Grab any slot that suits you: cal.com/daksh/30', es: 'Reserva cuando te venga bien: cal.com/daksh/30' };

function renderOut(changed) {
  const { app, command, dict, snip } = state;
  const plain = dict ? 'Priya' : 'Pria';
  const name = dict ? '<mark>Priya</mark>' : 'Pria';
  const k8s = dict ? '<mark>Kubernetes</mark>' : 'cooper netties';
  const cal = snip ? `<mark>${calLine[command]}</mark>` : 'my calendar link';
  const [a, b] = body[command](name, k8s, cal);
  const el = $('#out-body');
  if (app === 'mail') {
    const [hi, bye] = frame[command];
    el.innerHTML = `<p>${hi} ${plain}${command === 'es' ? ':' : ','}</p><p>${a}</p><p>${b}</p><p>${bye ? bye + '<br>' : ''}Daksh</p>`;
  } else {
    el.innerHTML = `<p>${a} ${b}</p>`;
  }
  $('#out-app').textContent = app === 'mail' ? 'Mail' : 'Slack';
  $('#out-to').textContent = app === 'mail' ? `To: ${plain} Raman` : '#infra';
  $('#out-pill-text').textContent = command === 'none' ? 'Pasted' : 'Selection replaced';
  if (changed && !reduced) { el.classList.remove('is-swap'); void el.offsetWidth; el.classList.add('is-swap'); }
}

function radioGroup(group, onPick) {
  const buttons = $$('button', group);
  const pick = (b) => {
    buttons.forEach((x) => { x.setAttribute('aria-checked', String(x === b)); x.tabIndex = x === b ? 0 : -1; });
    onPick(b.dataset.value);
  };
  buttons.forEach((b, i) => {
    b.tabIndex = b.getAttribute('aria-checked') === 'true' ? 0 : -1;
    b.addEventListener('click', () => pick(b));
    b.addEventListener('keydown', (e) => {
      const d = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[e.key];
      if (!d) return;
      e.preventDefault();
      const next = buttons[(i + d + buttons.length) % buttons.length];
      next.focus(); pick(next);
    });
  });
}

$$('[data-control]').forEach((ctl) => {
  const key = ctl.dataset.control;
  if (ctl.getAttribute('role') === 'switch') {
    ctl.addEventListener('click', () => { state[key] = !state[key]; ctl.setAttribute('aria-checked', String(state[key])); renderOut(true); });
  } else {
    radioGroup(ctl, (v) => { state[key] = v; renderOut(true); });
  }
});
renderOut(false);

/* ---------- privacy: switch the provider ---------- */
radioGroup($('.ledger .seg'), (v) => {
  $$('.ledger [data-cloud]').forEach((td) => {
    td.textContent = td.dataset[v];
    if (td.matches('.yes, .no')) { td.classList.toggle('yes', v === 'cloud'); td.classList.toggle('no', v === 'local'); }
    if (!reduced) { td.classList.remove('flash'); void td.offsetWidth; td.classList.add('flash'); }
  });
});

/* ---------- faq: one answer at a time ---------- */
const pane = $('#faq-pane-text');
const qs = $$('.q');
const wide = matchMedia('(min-width: 900px)');
function openQ(q) {
  qs.forEach((x) => { const on = x === q; x.setAttribute('aria-expanded', String(on)); $('#' + x.getAttribute('aria-controls')).hidden = !on; });
  const text = $('#' + q.getAttribute('aria-controls')).textContent.trim();
  if (pane.textContent === text) return;
  pane.textContent = text;
  if (!reduced) { pane.classList.remove('is-swap'); void pane.offsetWidth; pane.classList.add('is-swap'); }
}
qs.forEach((q) => {
  q.addEventListener('click', () => openQ(q));
  q.addEventListener('focus', () => wide.matches && openQ(q));
  q.addEventListener('mouseenter', () => wide.matches && matchMedia('(hover: hover)').matches && openQ(q));
});

/* ---------- entrances ---------- */
const io = new IntersectionObserver((entries) => entries.forEach((en) => {
  if (!en.isIntersecting) return;
  en.target.classList.add('is-in'); io.unobserve(en.target);
}), { rootMargin: '0px 0px -8% 0px' });
$$('main section').forEach((sec) => $$('[data-reveal]', sec).forEach((el, i) => { el.style.setProperty('--d', i % 4); io.observe(el); }));

/* ---------- latest release, live from GitHub: footer tag + direct DMG download ---------- */
fetch('https://api.github.com/repos/wannabeepolymath/parla/releases/latest')
  .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
  .then((r) => {
    if (r.tag_name) $('#release').textContent = r.tag_name;
    // ponytail: links keep the release page as href until this resolves, so no-JS or API failure still works
    const dmg = (r.assets || []).find((a) => a.name.endsWith('.dmg'));
    if (dmg) $$('a[href$="/releases/latest"]').forEach((a) => { a.href = dmg.browser_download_url; });
  })
  .catch(() => {});
