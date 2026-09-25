/* emlex web UI: renders state from the local server and posts actions back. */
const $ = (s) => document.querySelector(s);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
let S = null;                    // last state snapshot
const items = new Map();         // timeline item id -> element

async function act(a) {
  const r = await fetch('/action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(a) });
  return r.json().catch(() => ({}));
}

function dialog(title, defaultValue = '') {
  return new Promise((resolve) => {
    const modal = el('div', 'modal');
    const card = el('div', 'modal-card');
    const h2 = el('h2');
    h2.textContent = title;
    const input = el('input', 'dialog-input');
    input.type = 'text';
    input.value = defaultValue;
    const buttons = el('div', 'dialog-buttons');
    const cancelBtn = el('button', 'dialog-btn', 'Cancel');
    const okBtn = el('button', 'dialog-btn dialog-ok', 'OK');
    buttons.append(cancelBtn, okBtn);
    card.append(h2, input, buttons);
    modal.append(card);
    
    const close = (value) => {
      modal.remove();
      resolve(value);
    };
    
    input.onkeydown = (e) => {
      if (e.key === 'Enter') close(input.value);
      else if (e.key === 'Escape') close(null);
    };
    cancelBtn.onclick = () => close(null);
    okBtn.onclick = () => close(input.value);
    
    document.body.append(modal);
    input.focus();
    input.select();
  });
}

/* ---------- markdown (small, safe) ---------- */
function esc(s) { return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
function inline(s) {
  s = esc(s);
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
  s = s.replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return s;
}
function md(src) {
  const lines = src.split('\n'); let out = '', i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (l.startsWith('```')) {
      const lang = l.slice(3).trim(); let code = []; i++;
      while (i < lines.length && !lines[i].startsWith('```')) code.push(lines[i++]);
      i++;
      out += (lang ? `<div class="lang">${esc(lang)}</div>` : '') + `<pre><code>${esc(code.join('\n'))}</code></pre>`; continue;
    }
    const h = l.match(/^(#{1,3})\s+(.*)/);
    if (h) { out += `<h${h[1].length}>${inline(h[2])}</h${h[1].length}>`; i++; continue; }
    if (/^\s*([-*]|\d+\.)\s+/.test(l)) {
      const ordered = /^\s*\d+\./.test(l); let li = [];
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) li.push(`<li>${inline(lines[i].replace(/^\s*([-*]|\d+\.)\s+/, ''))}</li>`), i++;
      out += `<${ordered ? 'ol' : 'ul'}>${li.join('')}</${ordered ? 'ol' : 'ul'}>`; continue;
    }
    if (l.trim() === '') { i++; continue; }
    let p = [];
    while (i < lines.length && lines[i].trim() !== '' && !lines[i].startsWith('```') && !/^(#{1,3})\s/.test(lines[i]) && !/^\s*([-*]|\d+\.)\s+/.test(lines[i])) p.push(lines[i++]);
    out += `<p>${inline(p.join('\n')).replace(/\n/g, '<br>')}</p>`;
  }
  return out;
}

/* ---------- timeline ---------- */
const toolIcon = (n) => n === 'bash' ? '›_' : n === 'read_file' ? '▤' : (n === 'write_file' || n === 'edit_file') ? '✎' : n.includes('__') ? '⁂' : '⚙';

/* Line diff (LCS) for edit_file: returns [[' '|'-'|'+', line], ...] */
function lineDiff(a, b) {
  const A = a.split('\n'), B = b.split('\n'), n = A.length, m = B.length;
  const L = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = []; let i = 0, j = 0;
  while (i < n && j < m) { if (A[i] === B[j]) { out.push([' ', A[i]]); i++; j++; } else if (L[i + 1][j] >= L[i][j + 1]) out.push(['-', A[i++]]); else out.push(['+', B[j++]]); }
  while (i < n) out.push(['-', A[i++]]); while (j < m) out.push(['+', B[j++]]);
  return out;
}
function parseArgs(it) { try { return JSON.parse(it.text); } catch { return null; } }
function renderEdit(it) {
  const a = parseArgs(it); if (!a || !a.path) return null;
  const e = el('div', 'edit');
  const head = el('div', 'head'); head.append(el('span', 'ico', '✎'), el('span', 'name', it.title === 'write_file' ? 'write' : 'edit'), el('span', 'path', a.path));
  const rows = it.title === 'write_file' ? (a.content || '').split('\n').map(l => ['+', l]) : lineDiff(a.old || '', a.new || '');
  const adds = rows.filter(r => r[0] === '+').length, dels = rows.filter(r => r[0] === '-').length;
  head.append(el('span', 'stat', `+${adds} −${dels}`)); e.append(head);
  const pre = el('pre', 'diff');
  const shown = rows.length > 60 ? rows.slice(0, 60) : rows;
  for (const [k, l] of shown) { const ln = el('div', 'l ' + (k === '+' ? 'add' : k === '-' ? 'del' : 'ctx'), (k === ' ' ? '  ' : k + ' ') + l); pre.append(ln); }
  if (rows.length > 60) pre.append(el('div', 'l ctx', `… ${rows.length - 60} more lines`));
  e.append(pre); head.onclick = () => e.classList.toggle('open'); e.classList.toggle('open', rows.length <= 12);
  return e;
}
function renderItem(it) {
  let e;
  switch (it.kind) {
    case 'user':
      e = el('div', 'user', it.text);
      e.oncontextmenu = (ev) => { ev.preventDefault(); menu(ev.clientX, ev.clientY, [
        { label: 'Fork before this message', run: () => act({ type: 'fork', id: S.current.id, before: it.userTurn }) },
        { label: 'Copy', run: () => navigator.clipboard.writeText(it.text) }]); };
      break;
    case 'assistant': e = el('div', 'assistant'); e.innerHTML = md(it.text); break;
    case 'toolCall':
      if (it.title === 'edit_file' || it.title === 'write_file') { const d = renderEdit(it); if (d) { e = d; break; } }
      e = el('div', 'tool'); e.append(el('span', 'ico', toolIcon(it.title)), el('span', 'name', it.title), el('span', 'args', it.text));
      e.onclick = () => e.classList.toggle('open'); break;
    case 'toolResult': {
      e = el('div', 'result'); const head = el('div', 'head'); const first = (it.text.split('\n')[0] || '(no output)'); const n = it.text.split('\n').length;
      head.append(el('span', 'chev', '▶'), el('span', 'first', first)); if (n > 1) head.append(el('span', '', `· ${n} lines`));
      const pre = el('pre', '', it.text); e.append(head, pre); head.onclick = () => e.classList.toggle('open'); break; }
    case 'audit': { e = el('div', 'audit'); e.append(el('span', it.title === 'allowed' ? 'ok' : 'no', it.title === 'allowed' ? '✓' : '✗'), el('span', '', it.text)); break; }
    default: e = el('div', it.kind, it.text);
  }
  e.dataset.id = it.id; return e;
}
function renderTimeline() {
  const t = $('#timeline'); t.innerHTML = ''; items.clear();
  if (!S.timeline.length) {
    const h = new Date().getHours(); const g = h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
    const em = el('div', 'empty'); em.append(el('h1', '', g), el('p', '', `What are we building in ${S.workspace ? S.workspace.name : 'this project'} today?`));
    const st = el('div', 'stats');
    [[S.tools.length, 'tools'], [S.skills.length, 'skills'], [S.mcp.length, 'MCP servers'], [S.memory.length, 'memories']].forEach(([n, l]) => st.append(el('span', 'stat', `${n} ${l}`)));
    em.append(st); t.append(em);
  }
  panelReset();
  let run = null; let turn = 0;
  for (const it of S.timeline) {
    if (it.kind === 'user' && it.userTurn) { runs.forEach(finishTurn); turn = it.userTurn; }
    if (isToolKind(it.kind)) { if (!run) { run = newRun(turn, S.timeline); t.append(run.chip); } addToRun(run, it); continue; }
    if (run) { finishRun(run, false); run = null; }
    const e = renderItem(it); items.set(it.id, e); t.append(e);
    if (it.kind === 'user' && it.userTurn) { const b = routeBadge(it.userTurn); if (b) t.append(b); }
  }
  if (run) finishRun(run, S.busy);
  if (!S.busy) runs.forEach(finishTurn);
  panelUpdate();
  if (!$('#tab-changes').classList.contains('hidden')) refreshGitDiff();
  if (S.busy) { const th = el('div', 'thinking'); th.append(el('span', 'dot'), el('span', '', 'Thinking…')); th.id = 'thinking'; t.append(th); }
  scrollBottom();
}
/* Tool activity lives in the right panel; the conversation keeps a chip per run. */
const isToolKind = (k) => k === 'toolCall' || k === 'toolResult' || k === 'audit';
let runs = []; let liveRun = null;   // one run per user turn in the panel; one chip per contiguous burst in the conversation
function panelReset() { runs = []; liveRun = null; $('#act-running').innerHTML = ''; $('#act-finished').innerHTML = ''; }
function turnPrompt(turn, timeline) { const u = (timeline || S.timeline).find(x => x.kind === 'user' && x.userTurn === turn); return u ? u.text : ''; }
function newRun(turn, timeline) {
  let r = runs.find(x => x.turn === turn && !x.done);
  if (!r) {
    r = { turn, calls: 0, names: [], items: [], block: el('div', 'turnblock'), done: false, seg: null };
    r.block.append(el('div', 'th'), el('div', 'tb')); r.block.querySelector('.th').onclick = () => r.block.classList.toggle('open');
    runs.push(r);
  }
  r.seg = { calls: 0, names: [], chip: el('div', 'toolchip') };
  r.chip = r.seg.chip;
  r.seg.chip.onclick = () => { openPanel('activity'); if (r.done) { $('#act-finished').classList.remove('folded'); $('#act-fin-toggle').classList.add('open'); } r.block.classList.add('open'); r.block.scrollIntoView({ block: 'nearest' }); };
  return r;
}
function summarize(names) { const c = {}; names.forEach(x => c[x] = (c[x] || 0) + 1); return Object.entries(c).sort((a, b) => b[1] - a[1]).map(([k, v]) => v > 1 ? `${k} ×${v}` : k).join(', '); }
function addToRun(r, it) {
  const e = renderItem(it); items.set(it.id, e); r.items.push(it); r.block.querySelector('.tb').append(e);
  if (it.kind === 'toolCall') { r.calls++; r.names.push(it.title); r.seg.calls++; r.seg.names.push(it.title); }
  updateRun(r, true);
}
function updateRun(r, live) {
  if (r.seg) r.seg.chip.textContent = `⚙ ${r.seg.calls} tool call${r.seg.calls === 1 ? '' : 's'}${live ? '…' : ''} · ${summarize(r.seg.names)}`;
  const th = r.block.querySelector('.th'); th.innerHTML = '';
  th.append(el('span', 'q', turnPrompt(r.turn) || `turn ${r.turn}`), el('span', 'small', summarize(r.names)), el('span', 'cnt', String(r.calls)));
  if (live) { if (r.block.parentElement !== $('#act-running')) $('#act-running').append(r.block); r.block.classList.add('open'); liveRun = r; }
}
/* A burst ended (assistant text follows). The turn's block stays in Running until the turn ends. */
function finishRun(r, stillRunning) { updateRun(r, stillRunning); liveRun = stillRunning ? r : null; }
function finishTurn(r) { if (!r || r.done) return; r.done = true; updateRun(r, false); r.block.classList.remove('open'); $('#act-finished').prepend(r.block); if (liveRun === r) liveRun = null; }
function panelUpdate() {
  const fin = runs.filter(r => r.done).length; $('#act-fin-count').textContent = fin || '';
  const total = runs.reduce((n, r) => n + r.calls, 0); const c = $('#panel-count'); c.textContent = total; c.classList.toggle('hidden', !total);
  renderChanges();
}
function openPanel(tab) { $('#panel').classList.remove('hidden'); $('#app').classList.add('with-panel'); if (tab) selectTab(tab); try { localStorage.setItem('emlex.panel', '1'); } catch {} }
function closePanel() { $('#panel').classList.add('hidden'); $('#app').classList.remove('with-panel'); try { localStorage.setItem('emlex.panel', '0'); } catch {} }
try { if (localStorage.getItem('emlex.panel') === '1') openPanel(); } catch {}
function selectTab(tab) { document.querySelectorAll('.ptab').forEach(b => b.classList.toggle('on', b.dataset.tab === tab)); $('#tab-activity').classList.toggle('hidden', tab !== 'activity'); $('#tab-changes').classList.toggle('hidden', tab !== 'changes'); if (tab === 'changes') { renderChanges(); refreshGitDiff(); } }
document.querySelectorAll('.ptab').forEach(b => b.onclick = () => selectTab(b.dataset.tab));
$('#panel-close').onclick = closePanel;
$('#panel-btn').onclick = () => $('#panel').classList.contains('hidden') ? openPanel() : closePanel();
$('#act-fin-toggle').onclick = (e) => { e.stopPropagation(); $('#act-finished').classList.toggle('folded'); $('#act-fin-toggle').classList.toggle('open'); };
document.addEventListener('keydown', (e) => { if (e.metaKey && e.key === 'j') { e.preventDefault(); $('#panel-btn').click(); } });

/* Changes: per-file summary of this session's edits, plus the workspace's real git diff on demand. */
function renderChanges() {
  const list = $('#chg-list'); list.innerHTML = '';
  const byFile = new Map();
  for (const r of runs) for (const it of r.items) {
    if (it.kind !== 'toolCall' || (it.title !== 'edit_file' && it.title !== 'write_file')) continue;
    const a = parseArgs(it); if (!a || !a.path) continue;
    const rows = it.title === 'write_file' ? (a.content || '').split('\n').map(l => ['+', l]) : lineDiff(a.old || '', a.new || '');
    const f = byFile.get(a.path) || { adds: 0, dels: 0, edits: [] };
    f.adds += rows.filter(x => x[0] === '+').length; f.dels += rows.filter(x => x[0] === '-').length; f.edits.push(it); byFile.set(a.path, f);
  }
  if (!byFile.size) list.append(el('div', 'small', 'No edits in this session yet.'));
  for (const [path, f] of byFile) {
    const c = el('div', 'filechange'); const h = el('div', 'fh');
    h.append(el('span', 'p', path), el('span', 'plus', `+${f.adds}`), el('span', 'minus', `−${f.dels}`), el('span', 'cnt', `${f.edits.length}`)); c.append(h);
    const body = el('div', 'fb'); f.edits.forEach(it => { const d = renderEdit(it); if (d) { d.classList.add('open'); body.append(d); } }); c.append(body);
    h.onclick = () => c.classList.toggle('open'); list.append(c);
  }
}
/* Workspace diff: fetched quietly when the Changes tab is visible and after every turn; shown only when non-empty. */
let gitDiffInFlight = false;
function parseUnifiedDiff(text) {
  const files = [];
  for (const chunk of text.split(/^diff --git /m).slice(1)) {
    const lines = chunk.split('\n'); const m = lines[0].match(/^a\/(.*?) b\/(.*)$/); const path = m ? m[2] : lines[0];
    let i = 1; while (i < lines.length && !lines[i].startsWith('@@')) i++;
    const body = lines.slice(i).filter((l, k, arr) => !(k === arr.length - 1 && l === ''));
    files.push({ path, adds: body.filter(l => l[0] === '+').length, dels: body.filter(l => l[0] === '-').length, body, tag: /^new file/m.test(chunk) ? 'new' : /^deleted file/m.test(chunk) ? 'deleted' : '' });
  }
  return files;
}
async function refreshGitDiff() {
  if (gitDiffInFlight || !S || !S.workspace) return; gitDiffInFlight = true;
  try {
    const r = await act({ type: 'workspace_diff' }); const sec = $('#chg-git'); const list = $('#chg-git-list'); list.innerHTML = '';
    const files = r.isRepo ? parseUnifiedDiff(r.diff || '') : []; const untracked = r.isRepo ? (r.untracked || '').split('\n').filter(Boolean) : [];
    const n = files.length + untracked.length; sec.classList.toggle('hidden', n === 0); $('#chg-git-count').textContent = n || '';
    for (const f of files) {
      const c = el('div', 'filechange'); const h = el('div', 'fh');
      h.append(el('span', 'p', f.path)); if (f.tag) h.append(el('span', 'tag', f.tag)); h.append(el('span', 'plus', `+${f.adds}`), el('span', 'minus', `−${f.dels}`)); c.append(h);
      const body = el('div', 'fb'); const pre = el('pre', 'gitdiff');
      for (const line of f.body) pre.append(el('div', line[0] === '+' ? 'add' : line[0] === '-' ? 'del' : line.startsWith('@@') ? 'hunk' : '', line));
      body.append(pre); c.append(body); h.onclick = () => c.classList.toggle('open'); list.append(c);
    }
    for (const u of untracked) { const c = el('div', 'filechange'); const h = el('div', 'fh'); h.append(el('span', 'p', u), el('span', 'tag', 'untracked')); c.append(h); list.append(c); }
  } catch {} finally { gitDiffInFlight = false; }
}

/* Overlay scrollbars: mark whichever box is scrolling so its thumb shows, then fade it out. */
(() => {
  const timers = new WeakMap();
  document.addEventListener('scroll', (e) => {
    const t = e.target === document ? document.documentElement : e.target; if (!(t instanceof Element)) return;
    t.classList.add('scrolling'); clearTimeout(timers.get(t)); timers.set(t, setTimeout(() => t.classList.remove('scrolling'), 800));
  }, true);
})();

/* Panel resize: drag the left edge; the width is remembered. */
(() => {
  const panel = $('#panel'); const grip = $('#panel-grip');
  // The conversation keeps at least 440px; the panel gives way first on narrow windows.
  const maxW = () => Math.max(240, window.innerWidth - $('#sidebar').getBoundingClientRect().width - 440);
  const clamp = (w) => Math.max(240, Math.min(maxW(), w));
  let wanted = 400;
  try { const w = parseInt(localStorage.getItem('emlex.panelW') || '', 10); if (w) wanted = w; } catch {}
  const apply = () => { panel.style.width = clamp(wanted) + 'px'; };
  apply(); window.addEventListener('resize', apply);
  grip.onmousedown = (e) => {
    e.preventDefault(); const startX = e.clientX; const startW = panel.getBoundingClientRect().width; document.body.classList.add('resizing'); grip.classList.add('on');
    const move = (ev) => { wanted = clamp(startW + (startX - ev.clientX)); panel.style.width = wanted + 'px'; };
    const up = () => { document.removeEventListener('mousemove', move); document.removeEventListener('mouseup', up); document.body.classList.remove('resizing'); grip.classList.remove('on'); try { localStorage.setItem('emlex.panelW', String(Math.round(panel.getBoundingClientRect().width))); } catch {} };
    document.addEventListener('mousemove', move); document.addEventListener('mouseup', up);
  };
})();

function scrollBottom() { const s = $('#scroll'); s.scrollTop = s.scrollHeight; }

function routeBadge(turn) {
  const r = (S.routes || []).find(x => x.turn === turn); if (!r) return null;
  const b = el('div', 'routebadge');
  b.append(el('span', 'm', r.model));
  if (r.tier) b.append(el('span', '', ` · ${r.tier}${r.confidence != null ? ' ' + Math.round(r.confidence * 100) + '%' : ''}`));
  b.append(el('span', '', ` · ${r.toolCalls} tools · ${(r.durationMs / 1000).toFixed(0)}s`));
  if (r.firstTokenMs != null && r.tokensOut > 0 && r.durationMs > r.firstTokenMs) b.append(el('span', '', ` · first token ${(r.firstTokenMs / 1000).toFixed(1)}s · ${(r.tokensOut / ((r.durationMs - r.firstTokenMs) / 1000)).toFixed(0)} tok/s`));
  if (r.review) b.append(el('span', 'rv ' + r.review, ` · ${r.review}`));
  b.title = (r.reason || '') + (r.errors ? ` · ${r.errors} errors` : '');
  return b;
}

/* ---------- sidebar ---------- */
function bucket(ms) { const d = new Date(ms), now = new Date(); const day = 864e5;
  if (d.toDateString() === now.toDateString()) return 'Today';
  if (d.toDateString() === new Date(now - day).toDateString()) return 'Yesterday';
  return now - d < 7 * day ? 'Previous 7 days' : 'Older'; }
function renderSessions() {
  const box = $('#sessions'); box.innerHTML = '';
  const mine = S.sessions.filter(s => (s.mode || 'code') === S.mode);
  if (!mine.length) { const e = el('div', 'small', S.workspace ? `No ${S.mode} sessions yet.` : 'Choose a folder to start.'); e.style.padding = '12px'; box.append(e); return; }
  const groups = {}; for (const s of mine) (groups[bucket(s.updatedAt)] ||= []).push(s);
  for (const b of ['Today', 'Yesterday', 'Previous 7 days', 'Older']) {
    if (!groups[b]) continue; box.append(el('div', 'sec', b));
    for (const s of groups[b]) {
      const r = el('div', 'sess' + (S.current && S.current.id === s.id ? ' active' : '')); r.append(el('span', 't', s.title));
      if (s.worktree) r.append(el('span', 'wt', '⑂'));
      r.title = `${s.model} · ${s.turns} turns`; r.onclick = () => act({ type: 'resume', id: s.id });
      r.oncontextmenu = (ev) => { ev.preventDefault(); menu(ev.clientX, ev.clientY, [
        { label: 'Rename…', run: () => { dialog('Session title', s.title).then(t => { if (t) act({ type: 'rename', id: s.id, title: t }); }); } },
        { label: 'Fork', run: () => act({ type: 'fork', id: s.id }) },
        ...(s.worktree ? [{ label: `Reveal worktree ${s.worktree}`, run: () => act({ type: 'reveal', id: s.id }) }] : []),
        { sep: true }, { label: 'Delete', danger: true, run: () => act({ type: 'delete_session', id: s.id }) }]); };
      box.append(r);
    }
  }
}

/* Loaded MLX models: reusable across sessions without another load; ⏏ frees the weights. */
function shortModel(id) { return id.replace(/^mlx:/, '').replace(/^mlx-community\//, ''); }
function renderLoaded() {
  const box = $('#loaded-list'); box.innerHTML = '';
  const rows = (S.residents || []).map(r => ({ id: r.id, size: r.size, loading: false }));
  if (S.loading && !rows.some(r => r.id === S.loading)) rows.unshift({ id: S.loading, size: '', loading: true });
  $('#loaded').classList.toggle('hidden', !rows.length);
  for (const r of rows) {
    const spec = 'mlx:' + r.id; const row = el('div', 'lrow' + (S.selected === spec ? ' on' : ''));
    row.append(el('span', 'dot2' + (r.loading ? ' loading' : '')), el('span', 'n', shortModel(r.id)), el('span', 'sz', r.loading ? 'loading…' : r.size));
    row.title = r.loading ? `${r.id} is loading` : `${r.id} · loaded · click to use in this session`;
    if (!r.loading) { const e = el('button', 'eject', '⏏'); e.title = 'Unload'; e.onclick = (ev) => { ev.stopPropagation(); act({ type: 'unload', id: r.id }); }; row.append(e); }
    row.onclick = () => { if (!r.loading && S.selected !== spec) act({ type: 'select_model', spec }); };
    box.append(row);
  }
}

/* ---------- top bar & composer ---------- */
function renderChrome() {
  renderLoaded();
  $('#ws-name').textContent = S.workspace ? S.workspace.name : 'Open a folder';
  $('#title').textContent = S.current ? S.current.title : 'emlex';
  const wt = $('#worktree'); if (S.current && S.current.worktree) { wt.textContent = '⑂ ' + S.current.worktree; wt.classList.remove('hidden'); } else wt.classList.add('hidden');
  const ctx = $('#context');
  if (S.current && S.current.contextSize > 0) { const f = Math.min(1, S.current.contextUsed / S.current.contextSize);
    ctx.classList.remove('hidden'); ctx.classList.toggle('warn', f > .75); $('#ctx-pct').textContent = Math.round(f * 100) + '%';
    $('#ring').style.strokeDashoffset = (37.7 * (1 - f)).toFixed(2); ctx.title = `Context: ${S.current.contextUsed.toLocaleString()} of ${S.current.contextSize.toLocaleString()} tokens. Click to compact.`;
  } else ctx.classList.add('hidden');
  $('#model-label').textContent = S.loading ? `Loading ${shortModel(S.loading)}…` : S.selected === 'auto' ? `Auto · ${S.current ? S.current.effectiveModel : '…'}` : S.selected;
  $('#effort-label').textContent = S.effort === 'off' ? 'Effort' : S.effort[0].toUpperCase() + S.effort.slice(1);
  $('#stop').classList.toggle('hidden', !S.busy);
  document.querySelectorAll('#modes .seg').forEach(b => b.classList.toggle('on', b.dataset.mode === S.mode));
  $('#perm-label').textContent = { ask: 'Ask', smart: 'Smart', full: 'Full auto' }[S.permission] || S.permission;
  $('#perm-btn').classList.toggle('hidden', S.mode === 'chat');
  renderApprovals();
  $('#mem').textContent = S.footprint;
  const inp = $('#input'); inp.placeholder = !S.current ? 'Choose a folder to start' : S.busy ? 'Type a follow-up; it is sent when this turn finishes' : 'How can I help?  Type / for skills and templates';
  const q = $('#queue'); q.innerHTML = ''; if (S.queue.length) { q.classList.remove('hidden'); q.append(el('span', '', '⇥'));
    S.queue.forEach(t => q.append(el('span', 'q', t))); const c = el('button', 'btn', 'Clear'); c.onclick = () => act({ type: 'clear_queue' }); q.append(c); } else q.classList.add('hidden');
  updateSend();
}
function renderApprovals() {
  const box = $('#approvals'); box.innerHTML = '';
  for (const r of (S.pending || [])) {
    const c = el('div', 'approval');
    const h = el('div', 'head'); h.append(el('span', 'tool', '⚠ ' + r.tool), el('span', '', 'wants to run')); c.append(h);
    c.append(el('pre', '', r.command || r.summary));
    if (r.reason) c.append(el('div', 'why', r.reason));
    const acts = el('div', 'acts');
    const deny = el('button', 'btn', 'Deny'); deny.onclick = () => act({ type: 'approve', id: r.id, allow: false });
    const always = el('button', 'btn', 'Always allow'); always.title = 'Allow this command prefix in this workspace from now on'; always.onclick = () => act({ type: 'approve', id: r.id, allow: true, always: true, command: r.command || '' });
    const allow = el('button', 'btn primary', 'Allow'); allow.onclick = () => act({ type: 'approve', id: r.id, allow: true });
    acts.append(deny); if (r.command) acts.append(always); acts.append(allow); c.append(acts); box.append(c);
  }
}
function updateSend() { $('#send').disabled = !$('#input').value.trim() || !S || !S.current; }

/* ---------- menus ---------- */
function menu(x, y, entries) {
  const m = $('#menu'); m.innerHTML = ''; m.classList.remove('hidden');
  for (const e of entries) {
    if (e.sep) { m.append(el('hr')); continue; }
    if (e.section) { m.append(el('div', 'sec', e.section)); continue; }
    const it = el('div', 'item' + (e.on ? ' on' : '') + (e.danger ? ' danger' : ''), e.label);
    if (e.sub) it.append(el('span', 'sub', e.sub));
    if (e.tag) it.append(el('span', 'tag' + (e.tag.startsWith('loading') ? ' loading' : ''), e.tag));
    it.onclick = () => { m.classList.add('hidden'); e.run(); }; m.append(it);
  }
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(x, innerWidth - r.width - 8) + 'px'; m.style.top = Math.min(y, innerHeight - r.height - 8) + 'px';
}
document.addEventListener('mousedown', (e) => { if (!$('#menu').contains(e.target)) $('#menu').classList.add('hidden'); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { $('#menu').classList.add('hidden'); closeModal(); } });
function anchorMenu(btn, entries) { const r = btn.getBoundingClientRect(); menu(r.left, r.top - 8 - Math.min(400, entries.length * 30), entries); const m = $('#menu'); const mr = m.getBoundingClientRect(); m.style.top = (r.top - mr.height - 6) + 'px'; }

$('#model-btn').onclick = (ev) => { ev.stopPropagation();
  const entries = [{ section: 'Routing' }, mi('auto')];
  const specs = S.backends.filter(b => b.available && b.spec !== 'auto').map(b => b.spec);
  const isLoaded = (s) => s.startsWith('mlx:') && (S.residents || []).some(r => 'mlx:' + r.id === s);
  const grp = (t, f) => { const l = specs.filter(f).sort((a, b) => isLoaded(b) - isLoaded(a)); if (l.length) { entries.push({ section: t }); l.forEach(s => entries.push(mi(s))); } };
  grp('Apple', s => s === 'system' || s === 'pcc'); grp('Claude', s => s.startsWith('claude:')); grp('Local MLX', s => s.startsWith('mlx:'));
  grp('Providers', s => !['system', 'pcc'].includes(s) && !s.startsWith('claude:') && !s.startsWith('mlx:') && !s.endsWith(':<model>'));
  entries.push({ sep: true }, { label: 'Manage models…', run: openModels });
  anchorMenu($('#model-btn'), entries);
  function mi(s) { const id = s.startsWith('mlx:') ? s.slice(4) : null;
    const tag = id && S.loading === id ? 'loading…' : id && (S.residents || []).some(r => r.id === id) ? 'loaded' : null;
    return { label: s, on: S.selected === s, tag, run: () => act({ type: 'select_model', spec: s }) }; } };
$('#effort-btn').onclick = (ev) => { ev.stopPropagation(); anchorMenu($('#effort-btn'), ['off', 'low', 'medium', 'high'].map(e => ({ label: e[0].toUpperCase() + e.slice(1), on: S.effort === e, run: () => act({ type: 'set_effort', effort: e }) }))); };
$('#workspace').onclick = (ev) => { ev.stopPropagation(); const r = $('#workspace').getBoundingClientRect();
  const entries = S.recents.map(w => ({ label: w.name, on: S.workspace && S.workspace.path === w.path, sub: w.path.replace(/^\/Users\/[^/]+/, '~'), run: () => act({ type: 'open_workspace', path: w.path }) }));
  entries.push({ sep: true }, { label: 'Open Folder…', run: () => S.nativePanels ? act({ type: 'choose_workspace' }) : (p => p && act({ type: 'open_workspace', path: p }))(prompt('Folder path')) });
  menu(r.left, r.bottom + 4, entries); };
$('#new-session').onclick = () => act({ type: 'new_session' });
document.querySelectorAll('#modes .seg').forEach(b => b.onclick = () => act({ type: 'set_mode', mode: b.dataset.mode }));
$('#perm-btn').onclick = (ev) => { ev.stopPropagation(); const r = $('#perm-btn').getBoundingClientRect();
  const items = [['ask', 'Ask', 'Every write and command asks'], ['smart', 'Smart', 'Rules, then the on-device model; asks for the rest'], ['full', 'Full auto', 'Nothing asks. For throwaway worktrees.']]
    .map(([k, l, d]) => ({ label: l, sub: d, on: S.permission === k, run: () => act({ type: 'set_permission', permission: k }) }));
  items.push({ sep: true }, { label: S.trusted ? 'Untrust this workspace' : 'Trust this workspace (its scripts may run)', run: () => act({ type: 'set_trust', trusted: !S.trusted }) });
  menu(r.left, r.bottom + 4, items); };
$('#new-worktree').onclick = () => { dialog('Branch name for the worktree').then(b => { if (b) act({ type: 'new_session', worktree: b }); }); };
$('#context').onclick = () => act({ type: 'compact' });
$('#stop').onclick = () => act({ type: 'stop' });
$('#title').ondblclick = () => { if (!S.current) return; dialog('Session title', S.current.title).then(t => { if (t) act({ type: 'rename', id: S.current.id, title: t }); }); };
$('#open-models').onclick = openModels; $('#open-tools').onclick = openTools;

/* ---------- composer ---------- */
const input = $('#input');
function autosize() { input.style.height = 'auto'; input.style.height = Math.min(260, input.scrollHeight) + 'px'; }
async function send(text) {
  const t = (text ?? input.value).trim(); if (!t) return;
  input.value = ''; autosize(); hideSuggest(); $('#blocked').innerHTML = '';
  const r = await act({ type: 'send', text: t });
  if (r && r.blocked) showBlocked(t, r);
}
/* The server refused the message because it contains a secret: nothing was sent or saved.
   Put the text back so it can be edited, and offer the redacted version. */
function showBlocked(original, r) {
  if (!input.value.trim()) { input.value = original; autosize(); updateSend(); }
  const box = $('#blocked'); box.innerHTML = '';
  const c = el('div', 'approval blocked');
  const h = el('div', 'head'); h.append(el('span', 'tool', '⛔ Not sent')); c.append(h);
  const ul = el('ul');
  for (const f of r.findings || []) { const li = el('li', '', 'Contains ' + f.label); li.append(el('span', 'pv', f.preview)); if (f.source === 'model') li.title = 'Found by the on-device model'; ul.append(li); }
  c.append(ul);
  c.append(el('div', 'why', 'Nothing reached a model, memory or the session. Use an environment variable such as $API_TOKEN instead, or send it with the secret replaced by [REDACTED].'));
  const acts = el('div', 'acts');
  const edit = el('button', 'btn', 'Edit'); edit.onclick = () => { box.innerHTML = ''; input.focus(); };
  const red = el('button', 'btn primary', 'Send redacted'); red.onclick = () => { input.value = ''; autosize(); send(r.redacted); };
  acts.append(edit, red); c.append(acts); box.append(c);
}
$('#send').onclick = () => send();
input.addEventListener('input', () => { autosize(); updateSend(); suggest(); });
input.addEventListener('keydown', (e) => {
  const sg = $('#suggest'); if (!sg.classList.contains('hidden')) {
    const sel = sg.querySelector('.sel'); const all = [...sg.children];
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); let i = all.indexOf(sel); i = (i + (e.key === 'ArrowDown' ? 1 : -1) + all.length) % all.length; all.forEach(x => x.classList.remove('sel')); all[i].classList.add('sel'); return; }
    if (e.key === 'Tab' || (e.key === 'Enter' && sel)) { e.preventDefault(); sel.click(); return; }
  }
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); }
  if (e.key === '.' && e.metaKey) act({ type: 'stop' });
});
document.addEventListener('keydown', (e) => { if (e.metaKey && e.key === 'n') { e.preventDefault(); act({ type: 'new_session' }); } if (e.metaKey && e.key === 'k' && e.shiftKey) act({ type: 'compact' }); });
function suggest() {
  const v = input.value; const sg = $('#suggest');
  if (!v.startsWith('/') || v.includes(' ')) return hideSuggest();
  const q = v.slice(1).toLowerCase();
  const all = [...S.skills.map(k => ['/skill:' + k.name, k.description]), ...S.templates.map(t => ['/' + t.name, (t.hint ? t.hint + ' · ' : '') + t.description]),
    ['/compact', 'Fold older turns into a summary'], ['/new', 'New session']].filter(([c]) => !q || c.toLowerCase().includes(q)).slice(0, 8);
  if (!all.length) return hideSuggest();
  sg.innerHTML = ''; all.forEach(([c, h], i) => { const r = el('div', 'sug' + (i === 0 ? ' sel' : '')); r.append(el('span', 'c', c), el('span', 'h', h)); r.onclick = () => { input.value = c + ' '; hideSuggest(); input.focus(); updateSend(); }; sg.append(r); });
  sg.classList.remove('hidden');
}
function hideSuggest() { $('#suggest').classList.add('hidden'); }

/* ---------- modals ---------- */
function openModal(build) { const c = $('#modal-card'); c.innerHTML = ''; build(c); $('#modal').classList.remove('hidden'); }
function closeModal() { $('#modal').classList.add('hidden'); }
$('#modal').addEventListener('mousedown', (e) => { if (e.target === $('#modal')) closeModal(); });
function header(c, text) { const h = el('h2', '', text); const x = el('button', 'x', '✕'); x.onclick = closeModal; h.append(x); c.append(h); }
function openModels() {
  openModal((c) => {
    header(c, 'Models');
    for (const b of S.backends) {
      const r = el('div', 'mrow'); r.append(el('span', 'dot2' + (b.available ? ' on' : '')));
      const g = el('div', 'grow'); g.append(el('div', 'spec', b.spec), el('div', 'det', b.detail)); r.append(g);
      if (b.spec.startsWith('mlx:')) { const id = b.spec.slice(4);
        if (S.loading === id) r.append(el('span', 'small', 'loading…'));
        else if ((S.residents || []).some(x => x.id === id)) { const u = el('button', 'btn', 'Unload'); u.onclick = () => act({ type: 'unload', id }); r.append(u); }
        const d = el('button', 'btn danger', 'Remove'); d.onclick = () => { if (confirm(`Delete ${id} from disk?`)) act({ type: 'remove_model', id }); }; r.append(d); }
      c.append(r);
    }
    c.append(el('h3', '', 'Pull from Hugging Face'));
    const row = el('div', 'pull'); const f = el('input', 'text'); f.placeholder = 'mlx-community/…'; f.value = 'mlx-community/Qwen3-4B-4bit';
    const p = el('button', 'btn primary', 'Pull'); p.onclick = () => act({ type: 'pull', id: f.value }); f.onkeydown = (e) => { if (e.key === 'Enter') p.click(); }; row.append(f, p); c.append(row);
    const pulls = el('div'); pulls.id = 'pulls'; c.append(pulls); renderPulls();
    c.append(el('p', 'small', `Loaded models stay in memory and are shared across sessions; when memory runs short the least recently used one is unloaded first. Free now: ${S.free}. Weights live in ~/.cache/emlex/models.`));
  });
}
function renderPulls() {
  const box = $('#pulls'); if (!box) return; box.innerHTML = '';
  for (const [id, frac] of Object.entries(S.pulls)) { const r = el('div', 'pull'); r.append(el('span', '', id)); const pr = el('progress'); pr.max = 1; pr.value = frac; r.append(pr, el('span', '', Math.round(frac * 100) + '%'));
    const x = el('button', 'btn', '✕'); x.onclick = () => act({ type: 'cancel_pull', id }); r.append(x); box.append(r); }
  for (const [id, err] of Object.entries(S.pullErrors)) box.append(el('div', 'error', `${id}: ${err}`));
}
function openTools() {
  openModal((c) => {
    header(c, S.workspace ? S.workspace.name : 'Workspace');
    const sec = (t, hint) => { const h = el('h3', '', t); if (hint) h.append(el('span', 'hint', hint)); c.append(h); };
    sec('MCP servers', '.emlex/mcp.json or ~/.emlex/mcp.json');
    if (!S.mcp.length && !Object.keys(S.mcpFailures).length) c.append(el('div', 'small', 'None configured.'));
    S.mcp.forEach(s => { const r = el('div', 'mrow'); r.append(el('span', 'dot2 on')); const g = el('div', 'grow'); g.append(el('div', 'spec', `${s.server}  ${s.info}`), el('div', 'det', s.tools.join(', '))); r.append(g); c.append(r); });
    Object.entries(S.mcpFailures).forEach(([k, v]) => { const r = el('div', 'mrow'); r.append(el('span', 'dot2'), el('span', 'spec', k), el('span', 'error', v)); c.append(r); });
    sec('Skills', '.emlex/skills, .agents/skills, .claude/skills'); if (!S.skills.length) c.append(el('div', 'small', 'None found.'));
    S.skills.forEach(k => { const r = el('div', 'fact'); r.append(el('span', 'k', 'skill'), el('span', '', `/skill:${k.name} — ${k.description}`)); c.append(r); });
    sec('Prompt templates', '.emlex/prompts, .claude/commands'); if (!S.templates.length) c.append(el('div', 'small', 'None found.'));
    S.templates.forEach(t => { const r = el('div', 'fact'); r.append(el('span', 'k', 'template'), el('span', '', `/${t.name} ${t.hint || ''} — ${t.description}`)); c.append(r); });
    sec('Memory', 'extracted on-device after each turn'); if (!S.memory.length) c.append(el('div', 'small', 'Nothing remembered yet.'));
    S.memory.forEach(f => { const r = el('div', 'fact'); r.append(el('span', 'k', (f.scope === 'user' ? 'you · ' : '') + f.kind), el('span', '', f.text)); r.title = `used ${f.uses}×`; const x = el('button', 'x', '✕'); x.onclick = () => act({ type: 'forget', id: f.id }); r.append(x); c.append(r); });
    if (S.memory.length) { const row = el('div', 'pull');
      const m = el('button', 'btn', 'Consolidate'); m.title = 'Merge overlapping facts; the newest wins on conflicts'; m.onclick = () => { closeModal(); act({ type: 'consolidate_memory' }); };
      const b = el('button', 'btn danger', 'Forget everything'); b.onclick = () => act({ type: 'clear_memory' }); row.append(m, b); c.append(row); }
    if (S.archived && S.archived.length) {
      sec('Archived', 'expired or superseded; restore if still true');
      S.archived.slice(0, 20).forEach(f => { const r = el('div', 'fact'); r.append(el('span', 'k', f.superseded ? 'replaced' : 'expired'), el('span', 'small', f.text));
        const x = el('button', 'x', '↩'); x.title = 'Restore'; x.onclick = () => act({ type: 'restore_fact', id: f.id }); r.append(x); c.append(r); });
    }
    sec('Tools in this session'); c.append(el('div', 'small', S.tools.join(', ')));
  });
}

/* ---------- events ---------- */
function applyState(s) {
  const structural = !S || S.timeline.length !== s.timeline.length || !S.current || !s.current || S.current.id !== s.current.id || S.busy !== s.busy || S.mode !== s.mode || (S.routes || []).length !== (s.routes || []).length;
  const wasBusy = S && S.busy;
  S = s; renderSessions(); renderChrome(); renderPulls();
  if (structural) renderTimeline();
  else if (wasBusy && !s.busy) { runs.forEach(finishTurn); panelUpdate(); refreshGitDiff(); }
}
const es = new EventSource('/events');
es.addEventListener('state', (e) => applyState(JSON.parse(e.data)));
es.addEventListener('append', (e) => { const it = JSON.parse(e.data); if (!S) return; S.timeline.push(it); const t = $('#timeline'); t.querySelector('.empty')?.remove();
  const th = $('#thinking');
  if (isToolKind(it.kind)) {
    if (!liveRun) { const turn = Math.max(0, ...S.timeline.filter(x => x.kind === 'user').map(x => x.userTurn || 0)); liveRun = newRun(turn); th ? t.insertBefore(liveRun.chip, th) : t.append(liveRun.chip); if ($('#panel').classList.contains('hidden')) openPanel('activity'); }
    addToRun(liveRun, it); panelUpdate();
  } else {
    if (liveRun) { finishRun(liveRun, false); panelUpdate(); }
    if (it.kind === 'user') runs.forEach(finishTurn);
    const node = renderItem(it); items.set(it.id, node); th ? t.insertBefore(node, th) : t.append(node);
  }
  scrollBottom(); });
es.addEventListener('delta', (e) => { const d = JSON.parse(e.data); const it = S && S.timeline.find(x => x.id === d.id); if (!it) return; it.text += d.text; const node = items.get(d.id); if (node) node.innerHTML = md(it.text); scrollBottom(); });
es.addEventListener('pull', (e) => { const d = JSON.parse(e.data); if (S) { S.pulls[d.id] = d.fraction; renderPulls(); } });
fetch('/state').then(r => r.json()).then(applyState);
