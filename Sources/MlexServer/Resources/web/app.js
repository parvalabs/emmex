/* mlex web UI: renders state from the local server and posts actions back. */
const $ = (s) => document.querySelector(s);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
let S = null;                    // last state snapshot
const items = new Map();         // timeline item id -> element

async function act(a) {
  const r = await fetch('/action', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(a) });
  return r.json().catch(() => ({}));
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
      e = el('div', 'tool'); e.append(el('span', 'ico', toolIcon(it.title)), el('span', 'name', it.title), el('span', 'args', it.text));
      e.onclick = () => e.classList.toggle('open'); break;
    case 'toolResult': {
      e = el('div', 'result'); const head = el('div', 'head'); const first = (it.text.split('\n')[0] || '(no output)'); const n = it.text.split('\n').length;
      head.append(el('span', 'chev', '▶'), el('span', 'first', first)); if (n > 1) head.append(el('span', '', `· ${n} lines`));
      const pre = el('pre', '', it.text); e.append(head, pre); head.onclick = () => e.classList.toggle('open'); break; }
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
  for (const it of S.timeline) { const e = renderItem(it); items.set(it.id, e); t.append(e); }
  if (S.busy) { const th = el('div', 'thinking'); th.append(el('span', 'dot'), el('span', '', 'Thinking…')); th.id = 'thinking'; t.append(th); }
  scrollBottom();
}
function scrollBottom() { const s = $('#scroll'); s.scrollTop = s.scrollHeight; }

/* ---------- sidebar ---------- */
function bucket(ms) { const d = new Date(ms), now = new Date(); const day = 864e5;
  if (d.toDateString() === now.toDateString()) return 'Today';
  if (d.toDateString() === new Date(now - day).toDateString()) return 'Yesterday';
  return now - d < 7 * day ? 'Previous 7 days' : 'Older'; }
function renderSessions() {
  const box = $('#sessions'); box.innerHTML = '';
  if (!S.sessions.length) { box.append(el('div', 'small', S.workspace ? 'No sessions yet.' : 'Choose a folder to start.')).style.padding = '12px'; return; }
  const groups = {}; for (const s of S.sessions) (groups[bucket(s.updatedAt)] ||= []).push(s);
  for (const b of ['Today', 'Yesterday', 'Previous 7 days', 'Older']) {
    if (!groups[b]) continue; box.append(el('div', 'sec', b));
    for (const s of groups[b]) {
      const r = el('div', 'sess' + (S.current && S.current.id === s.id ? ' active' : '')); r.append(el('span', 't', s.title));
      if (s.worktree) r.append(el('span', 'wt', '⑂'));
      r.title = `${s.model} · ${s.turns} turns`; r.onclick = () => act({ type: 'resume', id: s.id });
      r.oncontextmenu = (ev) => { ev.preventDefault(); menu(ev.clientX, ev.clientY, [
        { label: 'Rename…', run: () => { const t = prompt('Session title', s.title); if (t) act({ type: 'rename', id: s.id, title: t }); } },
        { label: 'Fork', run: () => act({ type: 'fork', id: s.id }) },
        ...(s.worktree ? [{ label: `Reveal worktree ${s.worktree}`, run: () => act({ type: 'reveal', id: s.id }) }] : []),
        { sep: true }, { label: 'Delete', danger: true, run: () => act({ type: 'delete_session', id: s.id }) }]); };
      box.append(r);
    }
  }
}

/* ---------- top bar & composer ---------- */
function renderChrome() {
  $('#ws-name').textContent = S.workspace ? S.workspace.name : 'Open a folder';
  $('#title').textContent = S.current ? S.current.title : 'mlex';
  const wt = $('#worktree'); if (S.current && S.current.worktree) { wt.textContent = '⑂ ' + S.current.worktree; wt.classList.remove('hidden'); } else wt.classList.add('hidden');
  const ctx = $('#context');
  if (S.current && S.current.contextSize > 0) { const f = Math.min(1, S.current.contextUsed / S.current.contextSize);
    ctx.classList.remove('hidden'); ctx.classList.toggle('warn', f > .75); $('#ctx-pct').textContent = Math.round(f * 100) + '%';
    $('#ring').style.strokeDashoffset = (37.7 * (1 - f)).toFixed(2); ctx.title = `Context: ${S.current.contextUsed.toLocaleString()} of ${S.current.contextSize.toLocaleString()} tokens. Click to compact.`;
  } else ctx.classList.add('hidden');
  $('#model-label').textContent = S.selected === 'auto' ? `Auto · ${S.current ? S.current.effectiveModel : '…'}` : S.selected;
  $('#effort-label').textContent = S.effort === 'off' ? 'Effort' : S.effort[0].toUpperCase() + S.effort.slice(1);
  $('#stop').classList.toggle('hidden', !S.busy);
  $('#mem').textContent = S.footprint;
  const inp = $('#input'); inp.placeholder = !S.current ? 'Choose a folder to start' : S.busy ? 'Type a follow-up; it is sent when this turn finishes' : 'How can I help?  Type / for skills and templates';
  const q = $('#queue'); q.innerHTML = ''; if (S.queue.length) { q.classList.remove('hidden'); q.append(el('span', '', '⇥'));
    S.queue.forEach(t => q.append(el('span', 'q', t))); const c = el('button', 'btn', 'Clear'); c.onclick = () => act({ type: 'clear_queue' }); q.append(c); } else q.classList.add('hidden');
  updateSend();
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
  const grp = (t, f) => { const l = specs.filter(f); if (l.length) { entries.push({ section: t }); l.forEach(s => entries.push(mi(s))); } };
  grp('Apple', s => s === 'system' || s === 'pcc'); grp('Cloud', s => s.startsWith('claude:')); grp('Local MLX', s => s.startsWith('mlx:'));
  entries.push({ sep: true }, { label: 'Manage models…', run: openModels });
  anchorMenu($('#model-btn'), entries);
  function mi(s) { return { label: s, on: S.selected === s, run: () => act({ type: 'select_model', spec: s }) }; } };
$('#effort-btn').onclick = (ev) => { ev.stopPropagation(); anchorMenu($('#effort-btn'), ['off', 'low', 'medium', 'high'].map(e => ({ label: e[0].toUpperCase() + e.slice(1), on: S.effort === e, run: () => act({ type: 'set_effort', effort: e }) }))); };
$('#workspace').onclick = (ev) => { ev.stopPropagation(); const r = $('#workspace').getBoundingClientRect();
  const entries = S.recents.map(w => ({ label: w.name, on: S.workspace && S.workspace.path === w.path, sub: w.path.replace(/^\/Users\/[^/]+/, '~'), run: () => act({ type: 'open_workspace', path: w.path }) }));
  entries.push({ sep: true }, { label: 'Open Folder…', run: () => S.nativePanels ? act({ type: 'choose_workspace' }) : (p => p && act({ type: 'open_workspace', path: p }))(prompt('Folder path')) });
  menu(r.left, r.bottom + 4, entries); };
$('#new-session').onclick = () => act({ type: 'new_session' });
$('#new-worktree').onclick = () => { const b = prompt('Branch name for the worktree'); if (b) act({ type: 'new_session', worktree: b }); };
$('#context').onclick = () => act({ type: 'compact' });
$('#stop').onclick = () => act({ type: 'stop' });
$('#title').ondblclick = () => { if (!S.current) return; const t = prompt('Session title', S.current.title); if (t) act({ type: 'rename', id: S.current.id, title: t }); };
$('#open-models').onclick = openModels; $('#open-tools').onclick = openTools;

/* ---------- composer ---------- */
const input = $('#input');
function autosize() { input.style.height = 'auto'; input.style.height = Math.min(260, input.scrollHeight) + 'px'; }
function send() { const t = input.value.trim(); if (!t) return; input.value = ''; autosize(); hideSuggest(); act({ type: 'send', text: t }); }
$('#send').onclick = send;
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
        else if (S.resident === id) { const u = el('button', 'btn', 'Unload'); u.onclick = () => act({ type: 'unload' }); r.append(u); }
        const d = el('button', 'btn danger', 'Remove'); d.onclick = () => { if (confirm(`Delete ${id} from disk?`)) act({ type: 'remove_model', id }); }; r.append(d); }
      c.append(r);
    }
    c.append(el('h3', '', 'Pull from Hugging Face'));
    const row = el('div', 'pull'); const f = el('input', 'text'); f.placeholder = 'mlx-community/…'; f.value = 'mlx-community/Qwen3-4B-4bit';
    const p = el('button', 'btn primary', 'Pull'); p.onclick = () => act({ type: 'pull', id: f.value }); f.onkeydown = (e) => { if (e.key === 'Enter') p.click(); }; row.append(f, p); c.append(row);
    const pulls = el('div'); pulls.id = 'pulls'; c.append(pulls); renderPulls();
    c.append(el('p', 'small', 'Only one MLX model stays loaded; selecting another unloads it. Weights live in ~/.cache/mlex/models.'));
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
    sec('MCP servers', '.mlex/mcp.json or ~/.mlex/mcp.json');
    if (!S.mcp.length && !Object.keys(S.mcpFailures).length) c.append(el('div', 'small', 'None configured.'));
    S.mcp.forEach(s => { const r = el('div', 'mrow'); r.append(el('span', 'dot2 on')); const g = el('div', 'grow'); g.append(el('div', 'spec', `${s.server}  ${s.info}`), el('div', 'det', s.tools.join(', '))); r.append(g); c.append(r); });
    Object.entries(S.mcpFailures).forEach(([k, v]) => { const r = el('div', 'mrow'); r.append(el('span', 'dot2'), el('span', 'spec', k), el('span', 'error', v)); c.append(r); });
    sec('Skills', '.mlex/skills, .agents/skills, .claude/skills'); if (!S.skills.length) c.append(el('div', 'small', 'None found.'));
    S.skills.forEach(k => { const r = el('div', 'fact'); r.append(el('span', 'k', 'skill'), el('span', '', `/skill:${k.name} — ${k.description}`)); c.append(r); });
    sec('Prompt templates', '.mlex/prompts, .claude/commands'); if (!S.templates.length) c.append(el('div', 'small', 'None found.'));
    S.templates.forEach(t => { const r = el('div', 'fact'); r.append(el('span', 'k', 'template'), el('span', '', `/${t.name} ${t.hint || ''} — ${t.description}`)); c.append(r); });
    sec('Memory', 'extracted on-device after each turn'); if (!S.memory.length) c.append(el('div', 'small', 'Nothing remembered yet.'));
    S.memory.forEach(f => { const r = el('div', 'fact'); r.append(el('span', 'k', f.kind), el('span', '', f.text)); const x = el('button', 'x', '✕'); x.onclick = () => act({ type: 'forget', id: f.id }); r.append(x); c.append(r); });
    if (S.memory.length) { const b = el('button', 'btn danger', 'Forget everything'); b.onclick = () => act({ type: 'clear_memory' }); c.append(b); }
    sec('Tools in this session'); c.append(el('div', 'small', S.tools.join(', ')));
  });
}

/* ---------- events ---------- */
function applyState(s) {
  const structural = !S || S.timeline.length !== s.timeline.length || !S.current || !s.current || S.current.id !== s.current.id || S.busy !== s.busy;
  S = s; renderSessions(); renderChrome(); renderPulls();
  if (structural) renderTimeline();
}
const es = new EventSource('/events');
es.addEventListener('state', (e) => applyState(JSON.parse(e.data)));
es.addEventListener('append', (e) => { const it = JSON.parse(e.data); if (!S) return; S.timeline.push(it); const t = $('#timeline'); t.querySelector('.empty')?.remove();
  const th = $('#thinking'); const node = renderItem(it); items.set(it.id, node); th ? t.insertBefore(node, th) : t.append(node); scrollBottom(); });
es.addEventListener('delta', (e) => { const d = JSON.parse(e.data); const it = S && S.timeline.find(x => x.id === d.id); if (!it) return; it.text += d.text; const node = items.get(d.id); if (node) node.innerHTML = md(it.text); scrollBottom(); });
es.addEventListener('pull', (e) => { const d = JSON.parse(e.data); if (S) { S.pulls[d.id] = d.fraction; renderPulls(); } });
fetch('/state').then(r => r.json()).then(applyState);
