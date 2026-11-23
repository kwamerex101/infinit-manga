import { load } from 'cheerio';

const origin = 'https://roliascan.com';
const slugPattern = /^[a-z0-9][a-z0-9-]{0,180}$/;
const idPattern = /^\d{1,12}$/;

class SourceError extends Error {
  constructor(message, status = 502) {
    super(message);
    this.status = status;
  }
}

function validate(value, pattern) {
  if (!pattern.test(value ?? '')) throw new SourceError('Invalid RoliaScan link.', 400);
  return value;
}

function httpsUrl(value) {
  try {
    const url = new URL(value, origin);
    return value && url.protocol === 'https:' && !url.username && !url.password ? url.href : '';
  } catch {
    return '';
  }
}

function mangaSlug(value) {
  if (!value) return '';
  const url = new URL(value, origin);
  return url.origin === origin && /^\/manga\/([a-z0-9-]+)\/?$/.exec(url.pathname)?.[1] || '';
}

async function upstream(path, options = {}) {
  const response = await fetch(origin + path, {
    redirect: 'error',
    signal: AbortSignal.timeout(12000),
    ...options
  });
  if ([401, 403].includes(response.status)) {
    throw new SourceError('RoliaScan has restricted access to this content.', response.status);
  }
  if (response.status === 404) throw new SourceError('RoliaScan could not find this content.', 404);
  if (response.status === 429) throw new SourceError('RoliaScan is limiting requests. Try again in a moment.', 429);
  if (!response.ok) throw new SourceError('RoliaScan is temporarily unavailable.');
  return response;
}

async function json(path, options) {
  const data = await (await upstream(path, options)).json();
  if (!data.success) throw new SourceError('RoliaScan could not load this content.');
  return data;
}

function chapterLink(value) {
  if (!value) return null;
  const url = new URL(value, origin);
  const match = /^\/read\/([a-z0-9-]+)\/ch[a-z0-9-]+-(\d{1,12})\/?$/.exec(url.pathname);
  return url.origin === origin && match ? { slug: match[1], id: match[2], source: url.href } : null;
}

export const roliascan = {
  async discover() {
    const $ = load(await (await upstream('/home/')).text());
    const featured = $('.carousel-slide').map((_, slide) => {
      const link = $(slide).find('h2 a').first();
      const slug = mangaSlug(link.attr('href'));
      if (!slug) return null;
      const cover = $(slide).find('a img').first();
      return { slug, title: link.text().trim(), cover: httpsUrl(cover.attr('src')), description: $(slide).find('p').first().text().trim() };
    }).get();
    const latest = $('#manga-grid > div').map((_, card) => {
      const cover = $(card).find('img').first();
      const slug = mangaSlug(cover.closest('a').attr('href'));
      const link = $(card).find('a[href*="/read/"]').first();
      if (!slug || !cover.attr('alt')) return null;
      return { slug, title: cover.attr('alt'), cover: httpsUrl(cover.attr('src')), latest: link.text().trim() };
    }).get();
    if (!featured.length && !latest.length) throw new SourceError('RoliaScan’s catalog is unavailable.');
    return { featured, latest: latest.slice(0, 18) };
  },

  async search(query) {
    const response = await json('/auth/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, limit: 24 })
    });
    return (response.results ?? []).flatMap(item => {
      const slug = mangaSlug(item.permalink);
      return slug ? [{ slug, title: item.title, cover: httpsUrl(item.thumbnail), type: item.type }] : [];
    });
  },

  async series(slug) {
    validate(slug, slugPattern);
    const $ = load(await (await upstream('/manga/' + slug + '/')).text());
    const id = $('body').attr('data-manga-id');
    if (!idPattern.test(id ?? '')) throw new SourceError('RoliaScan did not return a series.', 404);
    return {
      slug, id,
      title: $('[data-manga-title]').first().attr('data-manga-title') || $('h1').first().text().trim(),
      cover: httpsUrl($('meta[property="og:image"]').attr('content')),
      description: $('#description-content-tab').text().replace(/\s+/g, ' ').trim(),
      first: chapterLink($('a[href*="/read/' + slug + '/"]').first().attr('href')),
      source: origin + '/manga/' + slug + '/'
    };
  },

  async chapters(id, offset, order) {
    validate(id, idPattern);
    const params = new URLSearchParams({ manga_id: id, offset, order, limit: 100 });
    const data = await json('/auth/manga-chapters?' + params);
    return {
      chapters: data.chapters.flatMap(chapter => {
        const link = chapterLink(chapter.url);
        return link ? [{ ...link, number: chapter.chapter, title: chapter.title === 'N/A' ? '' : chapter.title, date: chapter.date }] : [];
      }),
      total: Number(data.total),
      nextOffset: data.has_more && data.chapters.length ? offset + data.chapters.length : null
    };
  },

  async chapter(slug, id, sourcePath) {
    validate(slug, slugPattern);
    validate(id, idPattern);
    const chapter = chapterLink(sourcePath);
    if (!chapter || chapter.id !== id || chapter.slug !== slug) throw new SourceError('Invalid chapter link.', 400);
    const [data, html] = await Promise.all([
      json('/auth/chapter-content?chapter_id=' + id),
      upstream(new URL(chapter.source).pathname).then(response => response.text())
    ]);
    const $ = load(html);
    if ($('body').attr('data-chapter-id') !== id) throw new SourceError('RoliaScan did not return this chapter.', 404);
    const pages = (data.images ?? []).map(httpsUrl).filter(Boolean);
    if (!pages.length) throw new SourceError('RoliaScan did not provide readable images for this chapter.', 422);

    const selected = $('#chapter-select option[selected]');
    const option = (node) => chapterLink($(node).attr('value'));
    const number = $('body').attr('data-chapter-number');
    const chapterSuffix = ' Chapter ' + number;
    const readerTitle = $('#reader-media').attr('data-chapter-title') || $('h1').first().text().trim();
    return {
      ...chapter, pages, number,
      title: number && readerTitle.toLowerCase().endsWith(chapterSuffix.toLowerCase())
        ? readerTitle.slice(0, -chapterSuffix.length) : readerTitle,
      cover: httpsUrl($('[data-manga-cover]').first().attr('data-manga-cover')),
      previous: chapterLink($('a[title^="Prev:"]').first().attr('href')) || option(selected.prev()),
      next: chapterLink($('a[title^="Next:"]').first().attr('href')) || option(selected.next())
    };
  }
};
