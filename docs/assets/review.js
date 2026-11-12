// Review mode for a nimib page: open it with the Review button, select text, comment on it, keep
// the comments in this browser, export them as Markdown with a YAML block for a coding agent.
// No dependencies. The page gives its settings on
// <div id="review" data-page data-title data-source data-version data-commit data-updated>
// (the version, its commit and its date come from git, when the page is built).
// Each part is between `// part:` lines, which the devlog post "Review mode" shows one by one.
(function () {
  var cfg = document.getElementById('review');
  var root = document.querySelector('main');
  if (!cfg || !root) return;
  var page = cfg.dataset;

  // part: anchor
  // A comment points at the text it quotes, with a few words around it (as a W3C text quote
  // selector does), and the heading it is under. Not at an element: the page is rebuilt from its
  // source, and the text is what stays. The text of the page is its text nodes, in order.
  var CONTEXT = 32;
  var BLOCKS = 'p, li, h1, h2, h3, h4, pre, td, th, caption, blockquote, summary, dt, dd, div, nav';
  function textIndex() {
    // a line break between blocks, so the words around a quote read "page Select", not "pageSelect"
    var nodes = [], text = '', last = null;
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var p = n.parentNode.closest('script, style, #review');
        return p ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });
    for (var n = walker.nextNode(); n; n = walker.nextNode()) {
      var block = n.parentNode.closest(BLOCKS);
      if (nodes.length && block !== last) text += '\n';
      last = block;
      nodes.push({ node: n, start: text.length });
      text += n.data;
    }
    return { nodes: nodes, text: text };
  }
  function pointToIndex(idx, container, offset) {
    if (container.nodeType === 3) {
      for (var i = 0; i < idx.nodes.length; i++)
        if (idx.nodes[i].node === container) return idx.nodes[i].start + offset;
    }
    var at = document.createRange();
    at.setStart(container, offset);
    for (var j = 0; j < idx.nodes.length; j++)   // the first text node after the point
      if (at.comparePoint(idx.nodes[j].node, 0) >= 0) return idx.nodes[j].start;
    return idx.text.length;
  }
  function sectionOf(node) {
    var found = { title: '', id: '' };
    root.querySelectorAll('h1, h2, h3').forEach(function (h) {
      if (h.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING)
        found = { title: h.textContent.trim(), id: h.id || '' };
    });
    return found;
  }
  function describe(range) {
    var idx = textIndex();
    var s = pointToIndex(idx, range.startContainer, range.startOffset);
    var e = pointToIndex(idx, range.endContainer, range.endOffset);
    var quote = idx.text.slice(s, e);
    if (!quote.trim()) return null;
    return { quote: quote, prefix: idx.text.slice(Math.max(0, s - CONTEXT), s),
             suffix: idx.text.slice(e, e + CONTEXT), section: sectionOf(range.startContainer) };
  }
  function locate(note, idx) {
    // every place the quote is, scored by how much of its context matches; the best wins
    var best = null, bestScore = -1;
    for (var at = idx.text.indexOf(note.quote); at >= 0; at = idx.text.indexOf(note.quote, at + 1)) {
      var before = idx.text.slice(Math.max(0, at - note.prefix.length), at);
      var after = idx.text.slice(at + note.quote.length, at + note.quote.length + note.suffix.length);
      var score = common(before, note.prefix, true) + common(after, note.suffix, false);
      if (score > bestScore) { best = at; bestScore = score; }
    }
    return best === null ? null : { start: best, end: best + note.quote.length };
  }
  function common(a, b, fromEnd) {
    var n = 0;
    while (n < a.length && n < b.length &&
           (fromEnd ? a[a.length - 1 - n] === b[b.length - 1 - n] : a[n] === b[n])) n++;
    return n;
  }

  // part: mark
  // A located comment is drawn with <mark> around each piece of text it covers (a quote can
  // cross a link or a paragraph). Marks only wrap text, so the text of the page stays the same.
  function mark(note) {
    if (!note.quote) return;   // a comment on the whole page has nothing to mark
    var idx = textIndex(), at = locate(note, idx);
    note.found = !!at;
    if (!at) return;
    idx.nodes.forEach(function (n) {
      var a = Math.max(at.start, n.start) - n.start;
      var b = Math.min(at.end, n.start + n.node.data.length) - n.start;
      if (b <= a || !n.node.data.slice(a, b).trim()) return;
      if (n.node.parentNode.closest('table') && !n.node.parentNode.closest('td, th, caption')) return;
      var t = n.node;
      if (b < t.data.length) t.splitText(b);
      if (a > 0) t = t.splitText(a);
      var m = document.createElement('mark');
      m.className = 'rv-mark';
      m.dataset.id = note.id;
      t.parentNode.replaceChild(m, t);
      m.appendChild(t);
    });
  }
  function unmarkAll() {
    root.querySelectorAll('mark.rv-mark').forEach(function (m) {
      var p = m.parentNode;
      while (m.firstChild) p.insertBefore(m.firstChild, m);
      p.removeChild(m);
      p.normalize();
    });
  }
  function drawAll() {
    unmarkAll();
    notes.forEach(mark);
    var idx = textIndex();
    function place(note) {   // the page's order: a comment on the whole page first, one not found last
      if (!note.quote) return -1;
      var m = root.querySelector('mark.rv-mark[data-id="' + note.id + '"]');
      return m ? pointToIndex(idx, m.firstChild, 0) : Infinity;
    }
    notes.sort(function (a, b) { return place(a) - place(b); });
  }

  // part: store
  // The comments of a page live in this browser's localStorage, one key per page and version,
  // so a new version starts with no comments and the old ones stay with the version they are on.
  // Whether the review mode is open is kept too, so a page opens the way it was left.
  var PREFIX = 'nimib-review:', KEY = PREFIX + page.page + '@v' + page.version;
  var MODE = 'nimib-review-mode:' + page.page;
  function read(key) {
    try { return JSON.parse(localStorage.getItem(key)) || []; } catch (e) { return []; }
  }
  function save() {
    try {
      localStorage.setItem(KEY, JSON.stringify(notes.map(function (n) {
        return { id: n.id, kind: n.kind, quote: n.quote, prefix: n.prefix, suffix: n.suffix,
                 section: n.section, text: n.text, replacement: n.replacement, at: n.at, images: n.images,
                 commit: n.commit || page.commit || '' };
      })));
      full = false;
    } catch (e) { full = true; }   // the browser's storage is full: screenshots take the most
  }
  function remember(on) {
    try { if (on) localStorage.setItem(MODE, '1'); else localStorage.removeItem(MODE); } catch (e) {}
  }
  var notes = read(KEY);
  var current = -1, full = false, on = false;

  // part: mode
  // Reading is the default: no bar, no marks, nothing of the review mode but its version line,
  // *Version 12 · updated 10 Nov 2026*, and one button beside it, Review, under the lede or the
  // title (or where the page put `.rv-enter`). It opens the review mode, and closes it. Blocks
  // that only matter while reviewing (`.rv-only`) show only then.
  var slot = document.querySelector('.rv-enter');
  if (!slot) {
    slot = document.createElement('p');
    slot.className = 'rv-enter';
    var after = root.querySelector('.lede') || root.querySelector('h1');
    if (after) after.insertAdjacentElement('afterend', slot); else root.prepend(slot);
  }
  if (!slot.querySelector('.rv-version')) {
    var line = document.createElement('span');
    line.className = 'rv-version';
    line.textContent = 'Version ' + page.version + (page.updated ? ' · updated ' + page.updated : '');
    slot.prepend(line);
  }
  var toggle = document.createElement('button');
  toggle.type = 'button';
  toggle.className = 'rv-toggle';
  slot.appendChild(toggle);
  toggle.addEventListener('click', function () { setMode(!on); });
  function setMode(open) {
    on = open;
    remember(on);
    document.body.classList.toggle('rv-on', on);
    toggle.textContent = on ? 'Close review' : '✎ Review';
    toggle.setAttribute('aria-pressed', on ? 'true' : 'false');
    bar.hidden = !on;
    if (on) drawAll(); else { leave(); unmarkAll(); pending = null; }
    show();
  }

  // part: bar
  // While reviewing, a bar stays at the bottom of the screen, where a thumb reaches on a phone:
  // the previous and next comment and which one this is, delete it, a new one (*Page note* when
  // nothing is selected, a note on the whole page; *Comment ✓* on the words selected), and
  // export. A selection is kept as soon as it is made, because tapping a button can clear it.
  var bar = document.createElement('div');
  bar.className = 'rv-bar';
  bar.hidden = true;
  bar.setAttribute('role', 'toolbar');
  bar.setAttribute('aria-label', 'Review mode');
  bar.innerHTML =
    '<button type="button" data-do="prev" aria-label="Previous comment">‹</button>' +
    '<span class="rv-count" aria-live="polite"></span>' +
    '<button type="button" data-do="next" aria-label="Next comment">›</button>' +
    '<button type="button" data-do="delete" aria-label="Delete this comment">Delete</button>' +
    '<button type="button" data-do="add" class="rv-add">Page note</button>' +
    '<button type="button" data-do="export">Export</button>';
  document.body.appendChild(bar);
  var pending = null;
  document.addEventListener('selectionchange', function () {
    if (!on) return;
    var sel = document.getSelection();
    if (sel.rangeCount && !sel.isCollapsed && root.contains(sel.getRangeAt(0).commonAncestorContainer)) {
      pending = describe(sel.getRangeAt(0));
    } else {
      setTimeout(function () { if (document.getSelection().isCollapsed) { pending = null; show(); } }, 400);
    }
    show();
  });
  bar.addEventListener('pointerdown', function (e) { e.preventDefault(); });   // keep the selection
  bar.addEventListener('click', function (e) {
    var b = e.target.closest('button');
    if (!b) return;
    var act = b.dataset.do;
    if (act === 'prev' || act === 'next') step(act === 'next' ? 1 : -1);
    if (act === 'delete' && notes[current]) remove(notes[current]);
    if (act === 'add') add();
    if (act === 'export') openExport();
  });
  root.addEventListener('click', function (e) {   // a tap on marked words opens them, anywhere else closes
    if (!on || !document.getSelection().isCollapsed) return;
    var m = e.target.closest('mark.rv-mark');
    if (m) {
      var n = notes.find(function (x) { return x.id === m.dataset.id; });
      if (n) select(n);
    } else if (current >= 0 && !e.target.closest('a, button')) leave();
  });
  function show() {
    var c = bar.querySelector('.rv-count');
    c.textContent = full ? 'storage full: export'
                  : notes.length ? (current >= 0 ? (current + 1) + '/' : '') + notes.length : 'none';
    bar.querySelector('[data-do="prev"]').disabled = !notes.length;
    bar.querySelector('[data-do="next"]').disabled = !notes.length;
    bar.querySelector('[data-do="delete"]').disabled = current < 0;
    var add = bar.querySelector('.rv-add');
    add.textContent = pending ? 'Comment ✓' : 'Page note';   // says what it will do: on the words, or on the page
    add.classList.toggle('rv-selected', !!pending);
    add.setAttribute('aria-label', pending ? 'Comment on the selected text' : 'Comment on the whole page');
  }

  // part: sheet
  // The comment that ‹ and › stop on is open in a sheet at the top of the screen: there is no
  // Edit, no Save and no Cancel. What is typed is kept as it is typed; ‹ and › keep working and
  // take the sheet to the next comment; a tap on the page closes it. A comment left empty is
  // dropped. The sheet is small, so the words it is about stay in view under it, marked. There
  // are no kinds: to replace the words, the note says so ("Replace with: ..."), or "Remove". A
  // screenshot is pasted in the note, like text: the note is an editable box, so a phone offers
  // to paste an image there. While the sheet is open the page may not zoom.
  var viewport = document.querySelector('meta[name="viewport"]');
  var looseViewport = viewport ? viewport.content : '';
  function noZoom(yes) {
    if (viewport) viewport.content = yes ? looseViewport + ', maximum-scale=1' : looseViewport;
  }
  var sheet = document.createElement('div');
  sheet.className = 'rv-panel';
  sheet.hidden = true;
  sheet.innerHTML =
    '<p class="rv-whole">On the whole page</p>' +
    '<div class="rv-note" contenteditable="true" role="textbox" aria-multiline="true" aria-label="Comment"' +
    ' data-placeholder="What should change, and why. To replace the words: Replace with: and the new text; ' +
    'to drop them: Remove. Paste a screenshot here too."></div>' +
    '<div class="rv-thumbs"></div>';
  document.body.appendChild(sheet);
  var noteBox = sheet.querySelector('.rv-note');
  function add() {
    var n = Object.assign({ text: '', quote: '', prefix: '', suffix: '', section: { title: '', id: '' } }, pending || {});
    n.id = 'c' + Date.now().toString(36);
    n.at = new Date().toISOString();
    notes.push(n);
    document.getSelection().removeAllRanges();
    pending = null;
    select(n);
    noteBox.focus();
  }
  function select(n) {
    var was = notes[current];
    if (was && was !== n) drop(was);
    drawAll();
    current = notes.indexOf(n);
    root.querySelectorAll('mark.rv-current').forEach(function (m) { m.classList.remove('rv-current'); });
    var ms = root.querySelectorAll('mark.rv-mark[data-id="' + n.id + '"]');
    ms.forEach(function (m) { m.classList.add('rv-current'); });
    sheet.querySelector('.rv-whole').hidden = !!n.quote;
    noteBox.textContent = n.text || '';
    thumbs();
    sheet.hidden = false;
    noZoom(true);
    keepInView();
    show();
  }
  function step(d) {
    if (!notes.length) return;
    var target = notes[((current < 0 ? (d > 0 ? -1 : 0) : current) + d + notes.length) % notes.length];
    if (target !== notes[current]) select(target);
  }
  function leave() {   // close the sheet; an empty comment goes
    var n = notes[current];
    current = -1;
    sheet.hidden = true;
    noZoom(false);
    if (n) drop(n);
    root.querySelectorAll('mark.rv-current').forEach(function (m) { m.classList.remove('rv-current'); });
    show();
  }
  function empty(n) { return !(n.text || '').trim() && !(n.images || []).length && n.replacement == null; }
  function drop(n) { if (empty(n)) { notes = notes.filter(function (x) { return x !== n; }); save(); drawAll(); } }
  function remove(n) {
    notes = notes.filter(function (x) { return x !== n; });
    save();
    current = -1;
    sheet.hidden = true;
    noZoom(false);
    drawAll();
    show();
  }
  function keepInView() {   // the marked words, just under the sheet
    var m = root.querySelector('mark.rv-current');
    if (!m) return;
    var under = sheet.offsetHeight + 24;
    window.scrollBy({ top: m.getBoundingClientRect().top - under, behavior: 'smooth' });
  }
  noteBox.addEventListener('input', function () {
    var n = notes[current];
    if (!n) return;
    n.text = noteBox.innerText.trim();
    save();
    show();
  });
  function thumbs() {
    var n = notes[current], shots = (n && n.images) || [];
    var box = sheet.querySelector('.rv-thumbs');
    box.innerHTML = '';
    box.hidden = !shots.length;
    shots.forEach(function (src, i) {
      var t = document.createElement('div');
      t.className = 'rv-thumb';
      t.innerHTML = '<img alt="screenshot ' + (i + 1) + '"><button type="button" aria-label="Remove screenshot ' + (i + 1) + '">×</button>';
      t.querySelector('img').src = src;
      t.querySelector('img').addEventListener('click', function () { zoom(src); });
      t.querySelector('button').addEventListener('click', function () {
        shots.splice(i, 1);
        n.images = shots.length ? shots : undefined;
        save(); thumbs();
      });
      box.appendChild(t);
    });
  }
  function shrink(blob, width, quality) {   // an image as a JPEG at most `width` pixels wide
    return new Promise(function (ok, ko) {
      var img = new Image(), url = URL.createObjectURL(blob);
      img.onload = function () {
        var k = Math.min(1, width / img.naturalWidth), c = document.createElement('canvas');
        c.width = Math.round(img.naturalWidth * k); c.height = Math.round(img.naturalHeight * k);
        c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
        URL.revokeObjectURL(url);
        ok(c.toDataURL('image/jpeg', quality));
      };
      img.onerror = ko;
      img.src = url;
    });
  }
  noteBox.addEventListener('paste', function (e) {   // an image goes to the screenshots, text stays plain text
    e.preventDefault();
    var n = notes[current];
    var files = [].filter.call(e.clipboardData.files || [], function (f) { return /^image\//.test(f.type); });
    Promise.all(files.map(function (b) { return shrink(b, 900, 0.72); })).then(function (srcs) {
      if (!srcs.length || !n) return;
      n.images = (n.images || []).concat(srcs);
      save(); thumbs(); keepInView(); show();
    });
    var text = e.clipboardData.getData('text/plain');
    if (text) document.execCommand('insertText', false, text);
  });
  noteBox.addEventListener('drop', function (e) { e.preventDefault(); });   // no images inside the text

  // part: zoom
  // A tap on a screenshot, in the sheet or in the export, shows it as large as the screen allows.
  var lens = document.createElement('dialog');
  lens.className = 'rv-zoom';
  lens.innerHTML = '<button type="button" aria-label="Close">×</button><img alt="screenshot">';
  document.body.appendChild(lens);
  lens.addEventListener('click', function () { lens.close(); });
  function zoom(src) { lens.querySelector('img').src = src; lens.showModal(); }

  // part: export
  // The comments as one text, for a person and for an agent: a title, a YAML block that says which
  // page, version and source they are on, then one Markdown section per comment, in page order.
  // The text can be edited before it is copied. Copy copies the text only, short enough for a
  // chat message; each screenshot has a Copy of its own, to paste after it. Close review ends the
  // review here too, so a long page need not be scrolled back to its top.
  function yaml(s) { return JSON.stringify(String(s)); }   // a JSON string is a YAML string
  function flat(s) { return s.replace(/\s+/g, ' '); }
  function quoted(s) { return flat(s).trim(); }
  function fence(s) {
    var f = '~~~';
    while (s.indexOf(f) >= 0) f += '~';
    return f + 'text\n' + s.trim() + '\n' + f;
  }
  var exportVersion = '';   // the version being exported, when it is not this one
  function shotName(i, k) { return 'review-v' + (exportVersion || page.version) + '-' + (i + 1) + '-' + (k + 1) + '.jpg'; }
  function exportText(list, version, commit) {
    // a chat shows a pasted text as Markdown: a yaml fence is a tidy box under the title.
    // By default the comments of this version; History exports those of an older one, with the
    // commit they were written on, and says which of them this version no longer has.
    list = list || notes; version = version || page.version;
    commit = commit === undefined ? page.commit || '' : commit;
    var out = ['# Review of “' + page.title + '”, version ' + version, '',
      '```yaml',
      'format: nimib-review/5',
      'title: ' + yaml(page.title),
      'page: ' + yaml(location.origin + location.pathname),
      'source: ' + yaml(page.source),
      'version: ' + yaml(version),
      'commit: ' + yaml(commit),
      'exported: ' + yaml(new Date().toISOString()),
      'comments: ' + list.length,
      '```', ''];
    list.forEach(function (n, i) {
      var where = !n.quote ? 'On the whole page'
                : n.section && n.section.title ? 'In “' + n.section.title + '”' + (n.section.id ? ' (#' + n.section.id + ')' : '')
                : 'At the top';
      out.push('## ' + (i + 1) + '. ' + where, '');
      if (n.from && n.from !== version) out.push('From version ' + n.from + (n.commit ? ' (commit ' + n.commit + ')' : '') + '.', '');
      if (n.quote) {
        out.push('> ' + quoted(n.quote), '');
        out.push('Around it: “…' + flat(n.prefix) + '⟦' + flat(n.quote) + '⟧' + flat(n.suffix) + '…”', '');
        if (n.found === false) out.push('(Not found on the page any more.)', '');
      }
      // a comment kept from version 6 or before may still have a kind of its own
      if (n.kind === 'cut' || (n.kind === 'replace' && !(n.replacement || '').trim())) out.push('Remove these words.', '');
      else if (n.kind === 'replace') out.push('Replace with:', '', fence(n.replacement), '');
      if (n.text) out.push(n.text, '');
      if (n.images) out.push('Screenshots: ' + n.images.map(function (src, k) { return shotName(i, k); }).join(', '), '');
    });
    return out.join('\n');
  }
  var box = document.createElement('dialog');
  box.className = 'rv-sheet rv-export';
  box.innerHTML =
    '<form method="dialog"><p class="rv-where">Export: edit it if you like, then copy it</p>' +
    '<textarea rows="12" spellcheck="false"></textarea><div class="rv-shotlist"></div>' +
    '<div class="rv-actions"><button value="history" class="rv-left">History</button>' +
    '<button value="leave">Close review</button><button value="close">Close</button>' +
    '<button value="copy" class="rv-save" autofocus>Copy</button></div></form>';
  document.body.appendChild(box);
  var area = box.querySelector('textarea');
  var exportList = null;
  function openExport(list, version, commit) {
    if (current >= 0) leave();
    exportList = list || null; exportVersion = list ? version : '';
    area.value = exportText(list, version, commit);
    shotList();
    noZoom(true);
    box.showModal();
  }
  box.addEventListener('close', function () { noZoom(false); });
  function allShots() {
    var all = [];
    (exportList || notes).forEach(function (n, i) { (n.images || []).forEach(function (src, k) { all.push({ name: shotName(i, k), src: src }); }); });
    return all;
  }
  function shotList() {   // each screenshot, with its own Copy: paste it in the chat after the text
    var list = box.querySelector('.rv-shotlist');
    var canCopy = !!(navigator.clipboard && window.ClipboardItem);
    list.innerHTML = '';
    var all = allShots();
    list.hidden = !all.length;
    all.forEach(function (shot) {
      var row = document.createElement('div');
      row.className = 'rv-shot';
      row.innerHTML = '<img alt=""><span></span><button type="button">Copy image</button>';
      row.querySelector('img').src = shot.src;
      row.querySelector('img').addEventListener('click', function () { zoom(shot.src); });
      row.querySelector('span').textContent = shot.name;
      var b = row.querySelector('button');
      b.hidden = !canCopy;
      b.addEventListener('click', function () {
        copied(b, navigator.clipboard.write([new ClipboardItem({ 'image/png': png(shot.src) })]));
      });
      list.appendChild(row);
    });
  }
  function png(src) {   // the clipboard takes PNG images everywhere, JPEG not always
    return new Promise(function (ok, ko) {
      var img = new Image();
      img.onload = function () {
        var c = document.createElement('canvas');
        c.width = img.naturalWidth; c.height = img.naturalHeight;
        c.getContext('2d').drawImage(img, 0, 0);
        c.toBlob(ok, 'image/png');
      };
      img.onerror = ko;
      img.src = src;
    });
  }
  function copied(button, promise) {
    var label = button.textContent;
    return promise.then(function () {
      button.textContent = 'Copied ✓';
      setTimeout(function () { button.textContent = label; }, 1500);
    }, function () { button.textContent = 'Blocked'; });
  }
  box.querySelector('form').addEventListener('submit', function (e) {
    var act = e.submitter && e.submitter.value;
    if (act === 'copy') {
      e.preventDefault();
      var button = e.submitter;
      var fallback = function () { area.select(); document.execCommand('copy'); };
      copied(button, navigator.clipboard ? navigator.clipboard.writeText(area.value).catch(fallback)
                                         : Promise.resolve().then(fallback));
    } else if (act === 'history') {
      e.preventDefault();
      box.close();
      openHistory();
    } else if (act === 'leave') {   // the end of a review: back to reading, from the bottom of the page too
      setMode(false);
    }
  });

  // part: history
  // The versions of the page that have comments in this browser, this one first. The comments
  // of an older version can be brought here (those whose words this version still has) or
  // exported, with the commit they were written on; Export everything exports the comments of
  // every version. Old versions are not pages: git keeps them. Clearing the comments of a
  // version asks twice, with a second tap (confirm() is blocked inside an artifact).
  var hist = document.createElement('dialog');
  hist.className = 'rv-sheet rv-history';
  hist.innerHTML =
    '<form method="dialog"><p class="rv-where">History: the versions of this page</p>' +
    '<ol class="rv-versions"></ol>' +
    '<div class="rv-actions"><button value="all" class="rv-left">Export everything</button>' +
    '<button value="export">Export</button><button value="close" class="rv-save" autofocus>Close</button></div></form>';
  document.body.appendChild(hist);
  function stored() {   // the versions of this page that have comments in this browser
    var found = {};
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i), m = k.match(/@v([^@]+)$/);
        if (m && k.indexOf(PREFIX + page.page + '@v') === 0) found[m[1]] = read(k).length;
      }
    } catch (e) {}
    return found;
  }
  function twice(button, label, act) {   // the first tap asks, the second does
    if (button.dataset.sure === 'yes') { act(); return; }
    button.dataset.sure = 'yes';
    button.textContent = label;
  }
  function bringHere(version) {
    // the comments of an old version that this version still has (their words, found with their
    // context, or a comment on the whole page) move here; the others stay where they were
    var key = PREFIX + page.page + '@v' + version, old = read(key), stay = [], moved = 0;
    unmarkAll();
    var idx = textIndex(), ids = notes.map(function (n) { return n.id; });
    old.forEach(function (n) {
      if (n.quote && !locate(n, idx)) { stay.push(n); return; }
      while (ids.indexOf(n.id) >= 0) n.id = n.id + 'x';   // two ids made in the same millisecond
      ids.push(n.id);
      notes.push(n); moved++;
    });
    save();
    try {
      if (stay.length) localStorage.setItem(key, JSON.stringify(stay)); else localStorage.removeItem(key);
    } catch (e) {}
    drawAll(); show();
    return { moved: moved, left: stay.length };
  }
  function exportAll() {
    // every comment of this page in this browser, this version's first, then the older ones,
    // newest first, each saying the version it was written on and whether it is still found
    var counts = stored(), idx = textIndex(), list = [];
    var versions = Object.keys(counts).filter(function (v) { return v !== page.version; })
      .sort(function (a, b) { return (parseInt(b, 10) || 0) - (parseInt(a, 10) || 0); });
    notes.forEach(function (n) { list.push(n); });
    versions.forEach(function (v) {
      read(PREFIX + page.page + '@v' + v).forEach(function (n) {
        n.from = v;
        if (n.quote) n.found = !!locate(n, idx);
        list.push(n);
      });
    });
    hist.close();
    openExport(list, page.version, page.commit || '');
  }
  function exportOld(version) {
    var list = read(PREFIX + page.page + '@v' + version);
    var idx = textIndex();
    list.forEach(function (n) { n.from = version; if (n.quote) n.found = !!locate(n, idx); });
    var commits = list.map(function (n) { return n.commit || ''; }).filter(function (c) { return c; });
    hist.close();
    openExport(list, version, commits.length ? commits[commits.length - 1] : '');
  }
  function openHistory() {
    var list = hist.querySelector('.rv-versions'), counts = stored();
    var all = [{ n: page.version }];
    Object.keys(counts).forEach(function (n) { if (n !== page.version) all.push({ n: n }); });
    // this one first, then the others, newest first (a number from git, `12+` for a local build)
    all.sort(function (a, b) {
      if (a.n === page.version) return -1;
      if (b.n === page.version) return 1;
      return (parseInt(b.n, 10) || 0) - (parseInt(a.n, 10) || 0);
    });
    list.innerHTML = '';
    all.forEach(function (v) {
      var li = document.createElement('li'), n = counts[v.n] || 0, here = v.n === page.version;
      li.innerHTML = '<b></b> <span class="rv-date"></span> <span class="rv-n"></span>' +
        '<span class="rv-old"><button type="button" value="bring">Bring here</button>' +
        '<button type="button" value="export">Export</button></span>' +
        '<button type="button" class="rv-danger">Clear</button>';
      var old = li.querySelector('.rv-old');
      old.hidden = here || !n;
      old.querySelector('[value="bring"]').addEventListener('click', function (e) {
        var r = bringHere(v.n);
        openHistory();
        var said = r.moved + ' brought here' + (r.left ? ', ' + r.left + ' not found: they stay on v' + v.n : '');
        hist.querySelector('.rv-where').textContent = 'History: ' + said;
      });
      old.querySelector('[value="export"]').addEventListener('click', function () { exportOld(v.n); });
      li.querySelector('b').textContent = 'v' + v.n;
      li.querySelector('.rv-date').textContent = here ? (page.updated || '') + ' · this one' : '';
      li.querySelector('.rv-n').textContent = n ? n + (n === 1 ? ' comment' : ' comments') : '';
      var b = li.querySelector('.rv-danger');
      b.hidden = !n;
      b.addEventListener('click', function () {
        twice(b, 'Delete ' + n + '?', function () {
          try { localStorage.removeItem(PREFIX + page.page + '@v' + v.n); } catch (e) {}
          if (here) { notes = []; leave(); drawAll(); show(); }
          openHistory();
        });
      });
      list.appendChild(li);
    });
    hist.querySelector('.rv-where').textContent = 'History: the versions of this page';
    if (!hist.open) hist.showModal();
  }
  hist.querySelector('form').addEventListener('submit', function (e) {
    var act = e.submitter && e.submitter.value;
    if (act === 'all') {
      e.preventDefault();
      exportAll();
    } else if (act === 'export') {
      e.preventDefault();
      hist.close();
      openExport();
    }
  });

  var wasOn = false;
  try { wasOn = localStorage.getItem(MODE) === '1'; } catch (e) {}
  setMode(wasOn);
})();
