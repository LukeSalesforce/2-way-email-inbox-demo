/* ---- Resilient API layer ----
 * Tries the authenticated endpoint first; if 401 (session expired),
 * falls back permanently to the public Sites endpoint so the demo
 * never breaks mid-presentation.
 */
const _RAW_BASE = (window.__SF_INSTANCE_URL || '').replace(/\/+$/, '');
const _SITES_BASE = (window.__SF_SITES_BASE || '').replace(/\/+$/, '');
const _SESSION = window.__SF_SESSION_ID;
const _HAS_SESSION = _SESSION && _SESSION !== 'NULL_SESSION_ID';

let _activeEndpoint = _RAW_BASE + '/services/apexrest/inbox/';
let _activeHeaders = _HAS_SESSION
  ? { 'Authorization': 'Bearer ' + _SESSION }
  : {};
let _sessionExpired = !_HAS_SESSION; // start in expired state when guest

// Derive the public Sites endpoint. If $Site.BaseUrl resolved (Sites context),
// use it directly. Otherwise, derive from the VF domain by converting
// "orgname--c.vf.force.com" → "orgname.my.salesforce-sites.com/inbox".
const _SITES_ENDPOINT = (() => {
  if (_SITES_BASE) return _SITES_BASE + '/services/apexrest/inbox/';
  try {
    const host = new URL(_RAW_BASE).hostname;                           // e.g. orgname--c.vf.force.com
    const orgSlug = host.replace(/--c\.vf\.force\.com$/i, '')           // strips VF suffix
                        .replace(/\.my\.salesforce\.com$/i, '');        // strips my.sf suffix
    if (orgSlug && orgSlug !== host) {
      return 'https://' + orgSlug + '.my.salesforce-sites.com/inbox/services/apexrest/inbox/';
    }
  } catch (_) {}
  return null;
})();

function _currentEndpoint() { return _activeEndpoint; }
function _currentHeaders()  { return Object.assign({}, _activeHeaders); }

function _switchToSites() {
  if (_sessionExpired) return;       // already switched
  if (!_SITES_ENDPOINT) return;      // no fallback available
  _sessionExpired = true;
  _activeEndpoint = _SITES_ENDPOINT;
  _activeHeaders = {};               // no auth for Sites guest user
}

/**
 * Drop-in replacement for fetch() that auto-retries on 401 via the
 * Sites endpoint so a stale VF session never kills the demo.
 */
async function apiFetch(path, opts) {
  const url = _currentEndpoint() + (path || '');
  const merged = Object.assign({}, opts, {
    headers: Object.assign({}, _currentHeaders(), opts && opts.headers || {})
  });
  const res = await fetch(url, merged);
  if (res.status === 401 && !_sessionExpired && _SITES_ENDPOINT) {
    _switchToSites();
    const retryUrl = _currentEndpoint() + (path || '');
    const retryOpts = Object.assign({}, opts, {
      headers: Object.assign({}, _currentHeaders(), opts && opts.headers || {})
    });
    return fetch(retryUrl, retryOpts);
  }
  return res;
}

// Legacy compat — kept so rest of file keeps working
const ENDPOINT = null; // unused now — all calls go through apiFetch

const THREAD_ID = '{{THREAD_ID}}';
const FROM_NAME = '{{PROSPECT_NAME}}';
const FROM_EMAIL = '{{PROSPECT_EMAIL}}';
const SUBJECT_BASE = "{{SUBJECT_LINE}}";

const sendBtn = document.getElementById('send-btn');
const refreshBtn = document.getElementById('refresh-btn');
const resetBtn = document.getElementById('reset-btn');
const replyBody = document.getElementById('reply-body');
const statusEl = document.getElementById('status');
const repReplies = document.getElementById('rep-replies');
const initialTime = document.getElementById('initial-time');

initialTime.textContent = formatTime(new Date());

sendBtn.addEventListener('click', sendReply);
refreshBtn.addEventListener('click', fetchReplies);
if (resetBtn) resetBtn.addEventListener('click', resetDemo);

const FALLBACK_TEXT_SNIPPETS = [
  "loop in one of our specialists",
  "don't have specific information",
  "don't have specific information",
  "they'll reach out shortly",
  "they'll reach out shortly"
];

new MutationObserver(mutations => {
  if (!schedulingMode) return;
  for (const mut of mutations) {
    mut.addedNodes.forEach(node => {
      if (!(node instanceof HTMLElement)) return;
      const txt = (node.textContent || '').toLowerCase();
      if (FALLBACK_TEXT_SNIPPETS.some(s => txt.includes(s.toLowerCase()))) {
        if (node.dataset && node.dataset.id) {
          suppressedMessageIds.add(node.dataset.id);
        }
        node.remove();
      }
    });
  }
}).observe(repReplies, { childList: true, subtree: false });

let pollTimer = null;
const POLL_INTERVAL_MS = 4000;

let hasSentFirstReply = false; // gate: no polling until user sends a reply
let pendingScheduleAttach = false;
let schedulingMode = false;
let escalated = false; // true once the prospect requests a live agent
const suppressedMessageIds = new Set();
// Only trigger scheduling when the prospect EXPLICITLY asks to set up a meeting/call/demo.
// Removed loose words like "learn more", "chat", "meet", "demo" that fire on normal questions.
const SCHEDULE_INTENT_REGEX = /\b(schedule\s*(a\s*)?(time|call|meeting|demo)|set\s*up\s*(a\s*)?(time|call|meeting|demo)|book\s*(a\s*)?(time|call|meeting|demo)|find\s*a\s*time|grab\s*(a\s*)?time|put\s*something\s*on\s*(the\s*)?calendar|let'?s\s*(get|hop)\s*on\s*a\s*call|can\s*(we|i)\s*(set\s*up|schedule|book)\b|i'?d\s*like\s*(a\s*)?(demo|call|meeting)|sign\s*me\s*up|get\s*(something|a\s*call)\s*on\s*(the\s*)?calendar)\b/i;
// Affirmative replies only trigger scheduling when the agent already offered one
// (i.e. schedulingMode is already true from a prior explicit request).
const AFFIRMATIVE_REGEX = /^\s*(sure|sure\s*thing|yes|yep|yeah|yup|ok|okay|sounds\s*good|let'?s\s*do\s*it|absolutely|of\s*course|why\s*not)[\s.!?]*$/i;
const AE_NAME = '{{AE_NAME}}';
const AE_TITLE = '{{AE_TITLE}}';
const AE_EMAIL = '{{AE_EMAIL}}';

function detectScheduleIntent(text) {
  if (!text) return false;
  if (SCHEDULE_INTENT_REGEX.test(text)) return true;
  // Only treat bare affirmatives ("yes", "sure") as scheduling intent
  // when the agent already offered to schedule (schedulingMode is true).
  if (schedulingMode && AFFIRMATIVE_REGEX.test(text.trim())) return true;
  return false;
}

function startPolling() {
  if (pollTimer) return;
  pollTimer = setInterval(checkForUnseenReplies, POLL_INTERVAL_MS);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

async function checkForUnseenReplies() {
  // Don't check for agent replies until the user has sent at least one message.
  if (!hasSentFirstReply) return;
  try {
    const res = await apiFetch('?threadId=' + encodeURIComponent(THREAD_ID));
    if (!res.ok) return;
    const data = await res.json();
    if (data.status !== 'ok') return;
    updateCaseFooter(Array.isArray(data.caseNumbers) ? data.caseNumbers : []);
    if (!Array.isArray(data.messages)) return;
    if (schedulingMode) {
      data.messages.forEach(m => {
        if (m && m.id) suppressedMessageIds.add(m.id);
      });
      sweepFallbackRepliesFromDom();
      refreshBtn.classList.remove('has-reply');
      return;
    }
    const renderedIds = new Set(
      Array.from(repReplies.querySelectorAll('[data-id]')).map(n => n.dataset.id)
    );
    const hasUnseen = data.messages.some(m => !renderedIds.has(m.id) && !suppressedMessageIds.has(m.id));
    refreshBtn.classList.toggle('has-reply', hasUnseen);
  } catch (_) {
    // silent failure - polling shouldn't disturb the UI
  }
}

function sweepFallbackRepliesFromDom() {
  const articles = repReplies.querySelectorAll('article.message');
  articles.forEach(a => {
    const body = a.querySelector('.msg-body');
    if (!body) return;
    if (looksLikeFallback(body.textContent)) {
      if (a.dataset.id) suppressedMessageIds.add(a.dataset.id);
      a.remove();
    }
  });
}

async function snapshotExistingAgentReplies() {
  try {
    const res = await apiFetch('?threadId=' + encodeURIComponent(THREAD_ID));
    if (!res.ok) return;
    const data = await res.json();
    if (data.status !== 'ok' || !Array.isArray(data.messages)) return;
    data.messages.forEach(m => {
      if (m && m.id) suppressedMessageIds.add(m.id);
    });
  } catch (_) {}
}

const caseFooter = document.getElementById('case-footer');
const caseFooterList = document.getElementById('case-footer-list');
const caseFooterPlural = document.getElementById('case-footer-plural');
let knownCaseNumbers = [];

function updateCaseFooter(numbers) {
  const ordered = Array.isArray(numbers) ? numbers.slice() : [];
  const same =
    ordered.length === knownCaseNumbers.length &&
    ordered.every((n, i) => n === knownCaseNumbers[i]);
  if (same) return;
  knownCaseNumbers = ordered;

  if (ordered.length === 0) {
    caseFooter.setAttribute('hidden', 'hidden');
    caseFooterList.innerHTML = '';
    return;
  }
  caseFooterPlural.textContent = ordered.length > 1 ? 's:' : ':';
  caseFooterList.innerHTML = ordered
    .map(n => `<span class="case-num">${escapeHtml(n)}</span>`)
    .join(', ');
  caseFooter.removeAttribute('hidden');
}

// On page load, only update the case footer (don't surface reply notifications).
// Polling for actual agent replies starts only after the user sends their first message.
(async function initFooter() {
  await updateCaseFooterOnly();
})();

/** Lightweight check that only updates the Case footer — no reply dots. */
async function updateCaseFooterOnly() {
  try {
    const res = await apiFetch('?threadId=' + encodeURIComponent(THREAD_ID));
    if (!res.ok) return;
    const data = await res.json();
    if (data.status !== 'ok') return;
    updateCaseFooter(Array.isArray(data.caseNumbers) ? data.caseNumbers : []);
  } catch (_) {}
}

async function resetDemo() {
  const confirmed = confirm(
    'This will delete all Cases and EmailMessages in Salesforce tied to this demo thread (' +
    THREAD_ID + '). Continue?'
  );
  if (!confirmed) return;
  resetBtn.disabled = true;
  setStatus('Resetting demo data...', '');
  try {
    const res = await apiFetch('?threadId=' + encodeURIComponent(THREAD_ID), { method: 'DELETE' });
    const data = await res.json();
    if (res.ok && data.status === 'ok') {
      repReplies.innerHTML = '';
      replyBody.value = '';
      refreshBtn.classList.remove('has-reply');
      stopPolling();
      schedulingMode = false;
      pendingScheduleAttach = false;
      escalated = false;
      suppressedMessageIds.clear();
      updateCaseFooter([]);
      // Remove escalation banner if present
      const escBanner = document.getElementById('escalation-banner');
      if (escBanner) escBanner.remove();
      hasSentFirstReply = false;
      setStatus('Demo data cleared. Salesforce records deleted.', 'success');
    } else {
      setStatus(data.detail || 'Reset failed.', 'error');
    }
  } catch (err) {
    setStatus('Network error: ' + err.message, 'error');
  } finally {
    resetBtn.disabled = false;
  }
}

async function sendReply() {
  const message = replyBody.value.trim();
  if (!message) {
    setStatus('Please type a message before sending.', 'error');
    return;
  }
  if (schedulingMode && !detectScheduleIntent(message)) {
    schedulingMode = false;
  }
  const isScheduling = detectScheduleIntent(message);
  sendBtn.disabled = true;
  setStatus('Sending...', '');
  // Snapshot all existing outbound messages BEFORE the POST.
  // The POST creates the AI reply synchronously, so snapshotting after
  // would suppress the very reply we want to show.
  await snapshotExistingAgentReplies();
  try {
    const res = await apiFetch('', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        fromEmail: FROM_EMAIL,
        fromName: FROM_NAME,
        subject: 'Re: ' + SUBJECT_BASE,
        message,
        threadId: THREAD_ID
      })
    });
    const data = await res.json();
    if (res.ok && data.status === 'ok') {
      // Activate reply-checking now that the user has sent a message.
      if (!hasSentFirstReply) {
        hasSentFirstReply = true;
        // Start the background interval that surfaces the notification dot.
        setInterval(checkForUnseenReplies, 8000);
      }
      addLocalSentMessage(message);
      replyBody.value = '';
      if (data.escalated) {
        // Prospect asked for a live agent — show the escalation flow
        escalated = true;
        setStatus('Reply sent. Connecting you with a live agent...', '');
        startPolling();
      } else if (isScheduling) {
        schedulingMode = true;
        await snapshotExistingAgentReplies();
        sweepFallbackRepliesFromDom();
        setStatus('Reply sent. Agent is checking calendars...', '');
        setTimeout(() => {
          sweepFallbackRepliesFromDom();
          renderSchedulingAgentReply();
        }, 1400);
      } else {
        setStatus('Reply sent. Watching for the agent\'s response...', 'success');
        startPolling();
      }
    } else {
      setStatus(data.detail || 'Send failed.', 'error');
    }
  } catch (err) {
    setStatus('Network error: ' + err.message, 'error');
  } finally {
    sendBtn.disabled = false;
  }
}

async function fetchReplies() {
  if (!hasSentFirstReply) {
    setStatus('Send a reply first, then check for the agent\u2019s response.', '');
    return;
  }
  setStatus('Checking for replies...', '');
  try {
    const res = await apiFetch('?threadId=' + encodeURIComponent(THREAD_ID));
    const data = await res.json();
    if (data.status !== 'ok') {
      setStatus(data.detail || 'Check failed.', 'error');
      return;
    }
    const seenIds = new Set(Array.from(repReplies.querySelectorAll('[data-id]')).map(n => n.dataset.id));
    if (schedulingMode) {
      (data.messages || []).forEach(m => {
        if (m && m.id) suppressedMessageIds.add(m.id);
      });
    }
    const newOnes = (data.messages || []).filter(m => !seenIds.has(m.id) && !suppressedMessageIds.has(m.id));
    if (newOnes.length === 0) {
      setStatus('No new replies yet.', '');
      return;
    }
    newOnes.forEach(renderRepMessage);
    refreshBtn.classList.remove('has-reply');
    stopPolling();
    setStatus('Got ' + newOnes.length + ' new repl' + (newOnes.length === 1 ? 'y' : 'ies') + '.', 'success');

    // If escalated, show the escalation banner after the reply renders
    if (escalated) {
      setTimeout(() => renderEscalationBanner(), 600);
    }
  } catch (err) {
    setStatus('Network error: ' + err.message, 'error');
  }
}

function addLocalSentMessage(text) {
  const article = document.createElement('article');
  article.className = 'message';
  article.innerHTML = `
    <header class="msg-header">
      <div class="avatar" style="background:#5f6368;">{{PROSPECT_INITIALS}}</div>
      <div class="msg-meta">
        <div class="msg-from"><strong>${escapeHtml(FROM_NAME)}</strong>
          <span class="from-email">&lt;${escapeHtml(FROM_EMAIL)}&gt;</span></div>
        <div class="msg-to">to {{AGENT_NAME}}</div>
      </div>
      <div class="msg-time">${formatTime(new Date())}</div>
    </header>
    <div class="msg-body">${escapeHtml(text).replace(/\n/g, '<br>')}</div>
  `;
  repReplies.appendChild(article);
}

const FALLBACK_PATTERNS = [
  /loop in one of our specialists/i,
  /don'?t have specific information/i,
  /they'?ll reach out shortly/i
];

function looksLikeFallback(text) {
  return FALLBACK_PATTERNS.some(re => re.test(text || ''));
}

function renderRepMessage(m) {
  if (schedulingMode) {
    if (m && m.id) suppressedMessageIds.add(m.id);
    return;
  }
  const article = document.createElement('article');
  article.className = 'message';
  article.dataset.id = m.id;
  const sentAt = m.sentAt ? new Date(m.sentAt) : new Date();
  const fromName = m.fromName || '{{COMPANY_NAME}} Service';
  const fromAddress = m.fromAddress || 'service@example.invalid';
  const cleanBody = stripQuotedHistory(m.body || '');
  article.innerHTML = `
    <header class="msg-header">
      <div class="avatar avatar-rep">N</div>
      <div class="msg-meta">
        <div class="msg-from"><strong>${escapeHtml(fromName)}</strong>
          <span class="from-email">&lt;${escapeHtml(fromAddress)}&gt;</span></div>
        <div class="msg-to">to me</div>
      </div>
      <div class="msg-time">${formatTime(sentAt)}</div>
    </header>
    <div class="msg-body">${cleanBody}</div>
  `;
  repReplies.appendChild(article);
}

function stripQuotedHistory(body) {
  if (!body) return '';
  const looksLikeHtml = /<[a-z][\s\S]*>/i.test(body);
  if (looksLikeHtml) return stripQuotedHtml(body);
  return stripQuotedText(body);
}

function stripQuotedHtml(html) {
  const wrapper = document.createElement('div');
  wrapper.innerHTML = html;

  const quoteSelectors = [
    'blockquote',
    '.gmail_quote',
    '.gmail_attr',
    '.OutlookMessageHeader',
    '[id^="divRplyFwdMsg"]',
    'hr#stopSpelling'
  ];
  for (const sel of quoteSelectors) {
    const node = wrapper.querySelector(sel);
    if (node) {
      let cur = node;
      while (cur) {
        const next = cur.nextSibling;
        cur.parentNode.removeChild(cur);
        cur = next;
      }
      break;
    }
  }

  const headerPatterns = [
    /^On\s.+wrote:?\s*$/i,
    /^From:\s/i,
    /^-+\s*Original Message\s*-+$/i,
    /^_{3,}$/
  ];
  const candidates = wrapper.querySelectorAll('p, div, span');
  for (const el of candidates) {
    const text = (el.textContent || '').trim();
    if (!text) continue;
    if (headerPatterns.some(re => re.test(text))) {
      let cur = el;
      while (cur) {
        const next = cur.nextSibling;
        cur.parentNode.removeChild(cur);
        cur = next;
      }
      break;
    }
  }

  return wrapper.innerHTML.trim();
}

function stripQuotedText(text) {
  const lines = text.split(/\r?\n/);
  const stopRegexes = [
    /^On\s.+wrote:?\s*$/i,
    /^From:\s/i,
    /^-+\s*Original Message\s*-+$/i,
    /^>+\s/
  ];
  const out = [];
  for (const line of lines) {
    if (stopRegexes.some(re => re.test(line.trim()))) break;
    out.push(line);
  }
  return out.join('\n').trim();
}

function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

function formatTime(d) {
  const h = d.getHours();
  const m = d.getMinutes().toString().padStart(2, '0');
  const ampm = h >= 12 ? 'PM' : 'AM';
  const h12 = ((h + 11) % 12) + 1;
  return `${h12}:${m} ${ampm}`;
}

function escapeHtml(s) {
  return (s || '').replace(/[&<>"']/g, c => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

function generateTimeSlots() {
  // Always offer today's slots so the Event lands on "Today's Events" tile
  // during a live demo, regardless of what time the demo is run.
  const now = new Date();
  const first = new Date(now);
  first.setHours(10, 0, 0, 0);    // 10:00 AM today
  const second = new Date(now);
  second.setHours(11, 30, 0, 0);  // 11:30 AM today
  const third = new Date(now);
  third.setHours(14, 0, 0, 0);    // 2:00 PM today

  // If it's already past 2 PM, shift slots to nearest future half-hour
  // but keep them on today's date so they appear on "Today's Events"
  if (now.getHours() >= 14) {
    const m = now.getMinutes();
    first.setHours(now.getHours(), m <= 30 ? 30 : 0, 0, 0);
    if (m > 30) first.setHours(first.getHours() + 1);
    second.setHours(first.getHours() + 1, first.getMinutes(), 0, 0);
    third.setHours(first.getHours() + 2, first.getMinutes(), 0, 0);
  }

  return [first, second, third];
}

function formatSlotLabel(d) {
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${days[d.getDay()]}, ${months[d.getMonth()]} ${d.getDate()} • ${formatTime(d)}`;
}

function renderSchedulingAgentReply() {
  const article = document.createElement('article');
  article.className = 'message';
  article.dataset.id = 'agent-scheduling-' + Date.now();
  article.innerHTML = `
    <header class="msg-header">
      <div class="avatar avatar-agent">N</div>
      <div class="msg-meta">
        <div class="msg-from"><strong>{{AGENT_NAME}}</strong>
          <span class="from-email">&lt;{{AGENT_EMAIL}}&gt;</span></div>
        <div class="msg-to">to me</div>
      </div>
      <div class="msg-time">${formatTime(new Date())}</div>
    </header>
    <div class="msg-body">
      <p>Happy to get something on the calendar. I pulled a few open slots
        from our AE's calendar — pick whichever works best and I'll send the
        invite over right away.</p>
    </div>
  `;
  repReplies.appendChild(article);
  attachTimePicker(article);
  setStatus('Pick a time to confirm.', 'success');
}

function attachTimePicker(messageEl) {
  if (!messageEl || messageEl.querySelector('.time-picker')) return;
  const body = messageEl.querySelector('.msg-body');
  if (!body) return;

  const slots = generateTimeSlots();
  const picker = document.createElement('div');
  picker.className = 'time-picker';
  picker.innerHTML = `
    <div class="time-picker-label">Suggested times — click one to confirm:</div>
    <div class="time-picker-slots">
      ${slots.map((s, i) => `<button class="time-slot" data-idx="${i}">${escapeHtml(formatSlotLabel(s))}</button>`).join('')}
    </div>
  `;
  body.appendChild(picker);

  picker.querySelectorAll('.time-slot').forEach(btn => {
    btn.addEventListener('click', () => {
      const idx = parseInt(btn.dataset.idx, 10);
      const chosen = slots[idx];
      picker.querySelectorAll('.time-slot').forEach(b => {
        b.disabled = true;
        if (b !== btn) b.classList.add('dimmed');
      });
      btn.classList.add('selected');

      setStatus('Time selected. Booking the meeting...', '');
      bookEventInSalesforce(chosen).finally(() => {
        setTimeout(() => {
          renderConfirmationEmail(chosen);
          schedulingMode = false;
        }, 1200);
      });
    });
  });
}

async function bookEventInSalesforce(slot) {
  const start = new Date(slot);
  const end = new Date(slot.getTime() + 30 * 60 * 1000);
  try {
    const res = await apiFetch('schedule', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        threadId: THREAD_ID,
        startIso: start.toISOString(),
        endIso: end.toISOString(),
        attendeeName: FROM_NAME,
        attendeeEmail: FROM_EMAIL,
        repName: AE_NAME
      })
    });
    const data = await res.json();
    if (!res.ok || data.status !== 'ok') {
      console.warn('Event booking failed:', data && data.detail);
    }
  } catch (err) {
    console.warn('Event booking error:', err);
  }
}

function renderEscalationBanner() {
  // Don't add twice
  if (document.getElementById('escalation-banner')) return;

  const banner = document.createElement('div');
  banner.id = 'escalation-banner';
  banner.className = 'escalation-banner';
  banner.innerHTML = `
    <div class="escalation-icon">
      <svg viewBox="0 0 24 24" width="22" height="22"><path fill="currentColor" d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>
    </div>
    <div class="escalation-body">
      <div class="escalation-title">Transferred to Live Agent</div>
      <div class="escalation-detail">A {{COMPANY_NAME}} specialist has been notified and will reply in this thread. You can continue the conversation here.</div>
    </div>
  `;
  repReplies.appendChild(banner);

  // Keep the reply box active — the prospect can still receive and send
  // messages with the live agent in this same thread.
}

function renderConfirmationEmail(slot) {
  const article = document.createElement('article');
  article.className = 'message';
  article.dataset.id = 'confirmation-' + slot.getTime();
  const slotLabel = formatSlotLabel(slot);
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || 'your local time';
  article.innerHTML = `
    <header class="msg-header">
      <div class="avatar avatar-ae">{{AE_INITIALS}}</div>
      <div class="msg-meta">
        <div class="msg-from"><strong>${escapeHtml(AE_NAME)}</strong>
          <span class="from-email">&lt;${escapeHtml(AE_EMAIL)}&gt;</span></div>
        <div class="msg-to">to me</div>
      </div>
      <div class="msg-time">${formatTime(new Date())}</div>
    </header>
    <div class="msg-body">
      <p>Hi {{PROSPECT_FIRST_NAME}},</p>
      <p>Thanks for picking a time — the {{AGENT_NAME}} passed your
        thread over to me. I'm an Account Executive on {{COMPANY_NAME}}'s enterprise team
        and I'll be running our call.</p>
      <p><strong>Confirmed:</strong> ${escapeHtml(slotLabel)} (${escapeHtml(tz)})</p>
      <p>You'll see a calendar invite from <em>${escapeHtml(AE_EMAIL)}</em> with
        a video link in the next minute or two. I'll come prepared with a
        few case studies from organizations your size that consolidated onto our
        unified platform so we can get straight into the relevant details.</p>
      <p>Talk soon,<br/>${escapeHtml(AE_NAME)}<br/>${escapeHtml(AE_TITLE)}</p>
      <div class="cal-invite">
        <div class="cal-invite-icon">📅</div>
        <div class="cal-invite-body">
          <div class="cal-invite-title">{{COMPANY_NAME}} ↔ {{PROSPECT_COMPANY}} — Discovery</div>
          <div class="cal-invite-when">${escapeHtml(slotLabel)} • 30 min</div>
          <div class="cal-invite-meta">${escapeHtml(AE_NAME)} • Video conference</div>
        </div>
      </div>
    </div>
  `;
  repReplies.appendChild(article);
  setStatus('Meeting confirmed.', 'success');
}