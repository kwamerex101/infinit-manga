const main = document.querySelector('main');
const notice = document.querySelector('#notice');
const searchForm = document.querySelector('#search-form');
const searchInput = document.querySelector('#search-input');
document.querySelector('.skip').addEventListener('click', event => {
  event.preventDefault();
  main.focus();
});
const wide = matchMedia('(min-width: 740px) and (orientation: landscape)');
const storageKey = 'papertrail:v1';
const markIcon = '<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.65"><path d="M6 4h12v16l-6-4-6 4z" stroke-linejoin="round"/></svg>';

let noticeTimer;
let store = { bookmarks: {}, progress: {}, recent: {}, mode: 'auto' };
try {
  store = { ...store, ...JSON.parse(localStorage.getItem(storageKey)) };
} catch {
  notify('Local reading data could not be loaded.');
}

let controller;
let cleanup = () => {};

function notify(message) {
  notice.textContent = message;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { notice.textContent = ''; }, 3000);
}

function save() {
  try {
    localStorage.setItem(storageKey, JSON.stringify(store));
  } catch {
    notify('This browser could not save your changes.');
  }
}

function escape(value) {
  return String(value ?? '').replace(/[&<>"']/g, character => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[character]);
}

function seriesURL(item) {
  return '#series/' + encodeURIComponent(item.slug);
}

function readerURL(item) {
  return '#read/' + encodeURIComponent(item.slug) + '/' + encodeURIComponent(item.id) + '/' + encodeURIComponent(new URL(item.source).pathname);
}

async function api(path, params = {}, signal = controller.signal) {
  const response = await fetch('/api/' + path + '?' + new URLSearchParams(params), { signal });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Could not load this page.');
  signal.throwIfAborted();
  return data;
}

function message(title, copy, action = '') {
  return '<section class="message"><h2>' + escape(title) + '</h2><p>' + escape(copy) + '</p>' + action + '</section>';
}

function cover(item, extra = '') {
  return '<div class="cover ' + extra + '">' + (item.cover
    ? '<img src="' + escape(item.cover) + '" alt="" loading="lazy">'
    : '<span>' + escape(item.title?.slice(0, 1)) + '</span>') + '</div>';
}

function bookmark(item, iconOnly = false) {
  const button = document.createElement('button');
  button.className = iconOnly ? 'icon bookmark' : 'button secondary bookmark';
  function paint() {
    const active = Object.hasOwn(store.bookmarks, item.slug);
    const label = active ? 'Remove bookmark' : 'Bookmark';
    button.setAttribute('aria-pressed', active);
    button.setAttribute('aria-label', label + ': ' + item.title);
    button.title = label;
    button.innerHTML = markIcon + (iconOnly ? '' : ' <span>' + (active ? 'Bookmarked' : label) + '</span>');
  }
  button.addEventListener('click', () => {
    const active = Object.hasOwn(store.bookmarks, item.slug);
    if (active) delete store.bookmarks[item.slug];
    else store.bookmarks[item.slug] = { slug: item.slug, cover: item.cover, title: item.title };
    save();
    paint();
    notify(active ? 'Bookmark removed' : 'Saved to your library');
    if (active && location.hash === '#library') render();
  });
  paint();
  return button;
}

function cardGrid(items, container) {
  container.classList.add('grid');
  for (const item of items) {
    const article = document.createElement('article');
    article.className = 'title-card';
    article.innerHTML = '<a href="' + seriesURL(item) + '">' + cover(item) + '<h3>' +
      escape(item.title) + '</h3></a>' + ((item.latest || item.type) ? '<p>' + escape(item.latest || item.type) + '</p>' : '');
    article.append(bookmark(item, true));
    container.append(article);
  }
}

function renderRecent(container) {
  const items = Object.values(store.recent).sort((a, b) => b.time - a.time).slice(0, 6);
  if (!items.length) return;
  container.innerHTML = '<div class="section-heading"><h2>Continue reading</h2></div><div class="recent-row"></div>';
  const row = container.querySelector('.recent-row');
  for (const item of items) {
    const progress = store.progress[item.id];
    const link = document.createElement('a');
    link.className = 'recent';
    link.href = readerURL(item);
    link.innerHTML = cover(item) + '<span><strong>' + escape(item.title) + '</strong><small>Chapter ' +
      escape(item.number) + (progress?.read ? ' · Read' : ' · Page ' + ((progress?.page ?? 0) + 1)) + '</small></span>';
    row.append(link);
  }
}

async function discover() {
  const data = await api('discover');
  const featured = data.featured.length ? data.featured : data.latest.slice(0, 4);
  main.innerHTML = '<div class="shell"><div class="page-heading"><h1>Discover</h1>' +
    '<a class="source-label" href="https://roliascan.com/home/" target="_blank" rel="noopener">RoliaScan ↗</a></div>' +
    '<section class="feature" aria-label="Featured manga"><div class="feature-content"></div><div class="feature-nav"></div></section>' +
    '<section id="recent"></section><section><div class="section-heading"><h2>Latest updates</h2></div><div id="grid"></div></section></div>';
  const feature = main.querySelector('.feature');
  const content = feature.querySelector('.feature-content');
  const controls = feature.querySelector('.feature-nav');
  const tabs = featured.map((item, index) => {
    const button = document.createElement('button');
    button.className = 'feature-dot';
    button.setAttribute('aria-label', 'Feature ' + item.title);
    button.addEventListener('click', () => select(index));
    controls.append(button);
    return button;
  });

  function select(index) {
    const item = featured[index];
    content.innerHTML = (item.cover ? '<img class="feature-art" alt="" src="' + escape(item.cover) + '">' : '') +
      '<div class="feature-copy"><span class="feature-label">Featured series</span><h2>' + escape(item.title) + '</h2>' +
      (item.description ? '<p>' + escape(item.description) + '</p>' : '') +
      '<div class="actions"><a class="button primary" href="' + seriesURL(item) + '">View chapters</a></div></div>' +
      '<div class="feature-cover">' + cover(item) + '</div>';
    content.querySelector('.actions').append(bookmark(item));
    tabs.forEach((button, position) => button.setAttribute('aria-pressed', position === index));
  }

  select(Math.max(0, featured.findIndex(item => item.slug === 'dandadan')));
  renderRecent(main.querySelector('#recent'));
  cardGrid(data.latest, main.querySelector('#grid'));
}

function library() {
  main.innerHTML = '<div class="shell"><div class="page-heading"><h1>Your library</h1></div>' +
    '<section id="recent"></section><section><div class="section-heading"><h2>Bookmarks</h2></div><div id="grid"></div></section></div>';
  renderRecent(main.querySelector('#recent'));
  const items = Object.values(store.bookmarks).reverse();
  const grid = main.querySelector('#grid');
  if (items.length) cardGrid(items, grid);
  else grid.innerHTML = message('No bookmarks yet', 'Bookmark a series to keep it here.', '<a class="button primary" href="#discover">Discover manga</a>');
}

async function search(query) {
  searchInput.value = query;
  const items = await api('search', { q: query });
  main.innerHTML = '<div class="shell"><div class="page-heading"><h1>Search results</h1><span class="muted">' +
    escape(query) + '</span></div><div id="grid"></div></div>';
  const grid = main.querySelector('#grid');
  if (items.length) cardGrid(items, grid);
  else grid.innerHTML = message('No matches', 'Try a different title or paste a RoliaScan series link.');
}

async function series(slug) {
  const signal = controller.signal;
  const item = await api('series', { slug }, signal);
  const recent = store.recent[slug];
  main.innerHTML = '<div class="shell"><a class="back" href="#discover">‹ Discover</a><section class="series-hero">' +
    cover(item) + '<div><h1>' + escape(item.title) + '</h1><p class="synopsis">' + escape(item.description) +
    '</p><div class="actions">' + (recent || item.first
      ? '<a class="button primary" href="' + readerURL(recent || item.first) + '">' + (recent ? 'Resume chapter ' + escape(recent.number) : 'Start reading') + '</a>' : '') +
    '<a class="button secondary" href="' + escape(item.source) + '" target="_blank" rel="noopener">RoliaScan ↗</a></div></div></section>' +
    '<section><div class="section-heading"><h2>Chapters <small id="total"></small></h2><label class="sr-only" for="order">Chapter order</label>' +
    '<select id="order"><option value="desc">Newest first</option><option value="asc">Oldest first</option></select></div>' +
    '<div id="chapters"></div><button id="more" class="button secondary more" type="button" hidden>Load more chapters</button></section></div>';
  main.querySelector('.actions').insertBefore(bookmark(item), main.querySelector('.actions a:last-child'));
  const list = main.querySelector('#chapters');
  const more = main.querySelector('#more');
  const order = main.querySelector('#order');
  let nextOffset = 0;
  let request = 0;

  async function loadChapters(reset = false) {
    const current = ++request;
    if (reset) {
      nextOffset = 0;
      list.innerHTML = '<p class="muted" role="status">Loading chapters…</p>';
    }
    more.disabled = true;
    try {
      const data = await api('chapters', { id: item.id, offset: nextOffset, order: order.value }, signal);
      if (request !== current) return;
      if (reset) list.replaceChildren();
      main.querySelector('#total').textContent = Number.isFinite(data.total) ? data.total : '';
      for (const chapter of data.chapters.filter(chapter => chapter.slug === slug)) {
        const row = document.createElement('div');
        row.className = 'chapter-row';
        row.innerHTML = '<a href="' + readerURL(chapter) + '"><strong>Chapter ' + escape(chapter.number) + '</strong>' +
          (chapter.title ? '<span>' + escape(chapter.title) + '</span>' : '') + '<small>' + escape(chapter.date) + '</small></a>';
        const toggle = document.createElement('button');
        toggle.className = 'button secondary read-toggle';
        function paint() {
          const read = Boolean(store.progress[chapter.id]?.read);
          toggle.textContent = read ? '✓ Read' : 'Mark read';
          toggle.setAttribute('aria-pressed', read);
          toggle.setAttribute('aria-label', (read ? 'Mark unread' : 'Mark read') + ': chapter ' + chapter.number);
        }
        toggle.addEventListener('click', () => {
          const previous = store.progress[chapter.id];
          store.progress[chapter.id] = { ...previous, read: !previous?.read };
          save();
          paint();
        });
        paint();
        row.append(toggle);
        list.append(row);
      }
      if (!list.children.length) list.innerHTML = message('No chapters found', 'Check the series on RoliaScan for updates.');
      nextOffset = data.nextOffset;
      more.hidden = nextOffset === null;
      more.textContent = 'Load more chapters';
    } catch (error) {
      if (signal.aborted || request !== current) return;
      if (reset) list.innerHTML = message('Could not load chapters', error.message);
      else notify(error.message);
      more.hidden = false;
      more.textContent = 'Retry chapters';
    } finally {
      if (request === current) more.disabled = false;
    }
  }

  order.addEventListener('change', () => loadChapters(true));
  more.addEventListener('click', () => loadChapters(nextOffset === 0));
  await loadChapters(true);
}

async function render() {
  cleanup();
  cleanup = () => {};
  controller?.abort();
  controller = new AbortController();
  const signal = controller.signal;
  const [route, ...params] = (location.hash.slice(1) || 'discover').split('/');
  document.body.classList.toggle('reading', route === 'read');
  document.querySelectorAll('[data-nav]').forEach(link => {
    if (link.dataset.nav === route) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
  window.scrollTo(0, 0);
  main.innerHTML = '<div class="shell"><p class="loading" role="status">Loading…</p></div>';

  try {
    const [first, second, third] = params.map(decodeURIComponent);
    if (route === 'discover') await discover();
    else if (route === 'library') library();
    else if (route === 'search' && first) await search(first);
    else if (route === 'series' && first) await series(first);
    else if (route === 'read' && first && second && third) await reader(first, second, third);
    else main.innerHTML = message('Page unavailable', 'Open Discover to find a manga.', '<a class="button primary" href="#discover">Discover</a>');
  } catch (error) {
    if (signal.aborted) return;
    const back = route === 'read' && /^[a-z0-9-]+$/.test(params[0]) ? '#series/' + params[0] : '#discover';
    const source = route === 'read' && /^\/read\/[a-z0-9-]+\/ch[a-z0-9-]+\/?$/.test(decodeSource(params[2]))
      ? '<a class="button secondary" target="_blank" rel="noopener" href="https://roliascan.com' + escape(decodeSource(params[2])) + '">Open on RoliaScan ↗</a>' : '';
    main.innerHTML = '<div class="shell">' + message('Could not open this page', error.message,
      '<div class="actions"><button class="button primary" id="retry">Try again</button><a class="button secondary" href="' + back + '">Go back</a>' + source + '</div>') + '</div>';
    main.querySelector('#retry').addEventListener('click', render);
  }
}

function decodeSource(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return '';
  }
}

searchForm.addEventListener('submit', event => {
  event.preventDefault();
  const query = searchInput.value.trim();
  if (!query) return;
  let target = '#search/' + encodeURIComponent(query.slice(0, 120));
  try {
    const url = new URL(query);
    const [, route, slug, chapter] = url.pathname.split('/');
    if (url.origin === 'https://roliascan.com' && /^[a-z0-9-]+$/.test(slug)) {
      if (route === 'manga') target = seriesURL({ slug });
      const id = /^ch[a-z0-9-]+-(\d+)$/.exec(chapter ?? '')?.[1];
      if (route === 'read' && id) target = readerURL({ slug, id, source: url.href });
    }
  } catch {
    // Plain titles use search.
  }
  if (location.hash === target) render();
  else location.hash = target;
  searchInput.blur();
});

window.addEventListener('hashchange', render);

async function reader(slug, id, source) {
  const chapter = await api('chapter', { slug, id, source });
  const total = chapter.pages.length;
  let index = Math.min(total - 1, Math.max(0, Number(store.progress[id]?.page) || 0));
  let mode = store.mode;
  let view;
  let completionTimer;
  let scrollFrame;
  let touch;
  const failed = new Set();
  const book = { slug, id, source: chapter.source, title: chapter.title, number: chapter.number, cover: chapter.cover };

  main.innerHTML = '<div class="reader-bar"><a class="back" href="' + seriesURL(chapter) + '">‹ <span>' + escape(chapter.title) +
    '</span></a><strong>Chapter ' + escape(chapter.number) + '</strong><label class="sr-only" for="mode">Reading layout</label>' +
    '<select id="mode"><option value="auto">Auto spread</option><option value="single">Single page</option><option value="scroll">Vertical scroll</option></select></div>' +
    '<div id="pages" class="pages" aria-label="Chapter pages"></div>' +
    '<footer class="reader-footer"><div class="page-controls"><button id="back-page" class="button secondary" aria-label="Previous page">›</button>' +
    '<output id="position" aria-live="polite"></output><button id="next-page" class="button secondary" aria-label="Next page">‹</button></div>' +
    '<div class="actions chapter-controls">' + (chapter.previous ? '<a class="button secondary" href="' + readerURL(chapter.previous) + '">Previous chapter</a>' : '') +
    '<button id="read-state" class="button secondary"></button>' +
    (chapter.next ? '<a class="button primary" href="' + readerURL(chapter.next) + '">Next chapter</a>' : '') +
    '<a class="source-label" href="' + escape(chapter.source) + '" target="_blank" rel="noopener">RoliaScan ↗</a></div></footer>';

  const stage = main.querySelector('#pages');
  const select = main.querySelector('#mode');
  const previous = main.querySelector('#back-page');
  const next = main.querySelector('#next-page');
  const position = main.querySelector('#position');
  const readButton = main.querySelector('#read-state');
  select.value = mode;

  function remember() {
    const previous = store.progress[id];
    store.progress[id] = { ...previous, page: index };
    store.recent[slug] = { ...book, time: Date.now() };
    save();
  }

  function showReadState() {
    const read = Boolean(store.progress[id]?.read);
    readButton.textContent = read ? '✓ Read' : 'Mark read';
    readButton.setAttribute('aria-label', read ? 'Mark chapter unread' : 'Mark chapter read');
    readButton.setAttribute('aria-pressed', read);
  }

  function setRead(read) {
    store.progress[id] = { ...store.progress[id], read };
    remember();
    showReadState();
  }

  function figures() {
    return [...stage.querySelectorAll('.sheet')];
  }

  function displayPosition() {
    const last = view === 'spread' && index > 0 ? Math.min(index + 2, total) : index + 1;
    position.textContent = last === index + 1 ? (index + 1) + ' / ' + total : (index + 1) + '–' + last + ' / ' + total;
    previous.disabled = index === 0;
    next.disabled = last === total;
  }

  function maybeComplete() {
    clearTimeout(completionTimer);
    const finalPage = stage.querySelector('[data-page="' + (total - 1) + '"] img');
    if (!finalPage?.naturalWidth || failed.size || store.progress[id]?.read) return;
    function reachedEnd() {
      const rect = finalPage.getBoundingClientRect();
      return rect.bottom <= window.innerHeight + 4 && rect.bottom > 0 && rect.top < window.innerHeight;
    }
    if (reachedEnd()) completionTimer = setTimeout(() => {
      if (reachedEnd() && !failed.size) setRead(true);
    }, 500);
  }

  function sheet(page, lazy) {
    const figure = document.createElement('figure');
    figure.className = 'sheet';
    figure.dataset.page = page;
    const img = document.createElement('img');
    img.alt = 'Page ' + (page + 1);
    img.loading = lazy ? 'lazy' : 'eager';
    img.draggable = false;
    img.addEventListener('load', () => {
      failed.delete(page);
      figure.classList.add('loaded');
      figure.classList.remove('failed');
      figure.querySelector('button')?.remove();
      maybeComplete();
    });
    img.addEventListener('error', () => {
      failed.add(page);
      figure.classList.add('failed');
      if (figure.querySelector('button')) return;
      const retry = document.createElement('button');
      retry.className = 'button secondary retry-page';
      retry.textContent = 'Retry page ' + (page + 1);
      retry.addEventListener('click', event => {
        event.stopPropagation();
        figure.classList.remove('failed');
        retry.remove();
        img.src = chapter.pages[page];
      });
      figure.append(retry);
    });
    img.src = chapter.pages[page];
    figure.append(img);
    return figure;
  }

  function scrollToPage(page) {
    const figure = figures()[page];
    if (figure) figure.scrollIntoView({ block: 'start' });
  }

  function paint(turn = '') {
    clearTimeout(completionTimer);
    view = mode === 'scroll' ? 'scroll' : mode === 'auto' && wide.matches ? 'spread' : 'single';
    stage.className = 'pages ' + view;
    if (view === 'scroll') {
      stage.replaceChildren(...chapter.pages.map((_, page) => sheet(page, page !== index)));
      if (index) scrollToPage(index);
    } else {
      if (view === 'spread' && index && index % 2 === 0) index--;
      const sheets = [sheet(index, false)];
      if (view === 'spread' && index > 0 && index + 1 < total) sheets.push(sheet(index + 1, false));
      stage.replaceChildren(...sheets);
      if (turn) stage.classList.add(turn);
      window.scrollTo(0, 0);
    }
    displayPosition();
    maybeComplete();
  }

  function move(direction) {
    const step = view === 'spread' && index > 0 ? 2 : 1;
    const target = direction > 0 ? index + step : Math.max(0, index - step);
    if (target >= total || target === index) return;
    index = target;
    if (view === 'scroll') {
      scrollToPage(index);
      displayPosition();
    } else paint(direction > 0 ? 'turn-next' : 'turn-previous');
    remember();
  }

  function handleScroll() {
    cancelAnimationFrame(scrollFrame);
    scrollFrame = requestAnimationFrame(() => {
      if (view === 'scroll') {
        const cursor = Math.min(150, window.innerHeight * 0.3);
        const current = figures().find(figure => figure.getBoundingClientRect().bottom > cursor);
        if (current?.querySelector('img').naturalWidth) {
          const page = Number(current.dataset.page);
          if (page !== index) {
            index = page;
            displayPosition();
            remember();
          }
        }
      }
      maybeComplete();
    });
  }

  function keyboard(event) {
    if (event.target.matches('a, button, input, select') || event.altKey || event.ctrlKey || event.metaKey) return;
    if (view === 'scroll') return;
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      event.preventDefault();
      move(event.key === 'ArrowLeft' ? 1 : -1);
    }
  }

  select.addEventListener('change', () => {
    mode = select.value;
    store.mode = mode;
    paint();
    remember();
  });
  previous.addEventListener('click', () => move(-1));
  next.addEventListener('click', () => move(1));
  readButton.addEventListener('click', () => {
    clearTimeout(completionTimer);
    setRead(!store.progress[id]?.read);
  });
  stage.addEventListener('pointerdown', event => {
    touch = { x: event.clientX, y: event.clientY, id: event.pointerId };
  });
  stage.addEventListener('pointerup', event => {
    if (!touch || touch.id !== event.pointerId || view === 'scroll' || event.target.closest('button')) return;
    const x = event.clientX - touch.x;
    const y = event.clientY - touch.y;
    touch = null;
    if (Math.abs(x) > 36 && Math.abs(y) < Math.abs(x) * 0.6) move(x > 0 ? 1 : -1);
    else if (Math.hypot(x, y) < 10) {
      const bounds = stage.getBoundingClientRect();
      const fraction = (event.clientX - bounds.left) / bounds.width;
      if (fraction < 0.38) move(1);
      else if (fraction > 0.62) move(-1);
    }
  });

  function resize() {
    if (mode === 'auto') paint();
    else maybeComplete();
  }
  wide.addEventListener('change', resize);
  window.addEventListener('resize', maybeComplete);
  window.addEventListener('scroll', handleScroll, { passive: true });
  window.addEventListener('keydown', keyboard);
  cleanup = () => {
    clearTimeout(completionTimer);
    cancelAnimationFrame(scrollFrame);
    wide.removeEventListener('change', resize);
    window.removeEventListener('resize', maybeComplete);
    window.removeEventListener('scroll', handleScroll);
    window.removeEventListener('keydown', keyboard);
  };

  paint();
  remember();
  showReadState();
}

render();
