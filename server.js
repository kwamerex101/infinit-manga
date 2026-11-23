import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { roliascan } from './sources/roliascan.js';

const files = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/style.css': ['style.css', 'text/css; charset=utf-8'],
  '/favicon.svg': ['favicon.svg', 'image/svg+xml']
};

const routes = {
  '/api/discover': () => roliascan.discover(),
  '/api/search': (query) => roliascan.search((query.get('q') || '').trim().slice(0, 120)),
  '/api/series': (query) => roliascan.series(query.get('slug')),
  '/api/chapters': (query) => {
    const offset = Math.min(100000, Math.max(0, Math.trunc(Number(query.get('offset')) || 0)));
    const order = query.get('order') === 'asc' ? 'asc' : 'desc';
    return roliascan.chapters(query.get('id'), offset, order);
  },
  '/api/chapter': (query) => roliascan.chapter(query.get('slug'), query.get('id'), query.get('source'))
};

const port = Number(process.env.PORT || 43921);
createServer(async (request, response) => {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' https:; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; object-src 'none'; base-uri 'none'; frame-ancestors 'none'");
  const send = (status, data) => {
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify(data));
  };

  try {
    if (request.method !== 'GET') return send(405, { error: 'Use GET for this request.' });
    const { pathname, searchParams } = new URL(request.url, 'http://localhost');
    if (Object.hasOwn(files, pathname)) {
      const [file, type] = files[pathname];
      const content = await readFile(new URL('./public/' + file, import.meta.url));
      response.writeHead(200, { 'Content-Type': type });
      return response.end(content);
    }
    if (Object.hasOwn(routes, pathname)) return send(200, await routes[pathname](searchParams));
    return send(404, { error: 'Page not found.' });
  } catch (error) {
    if (!error.status) console.error(error.message);
    return send(error.status || 502, { error: error.status ? error.message : 'Could not reach RoliaScan. Try again.' });
  }
}).listen(port, '127.0.0.1', () => console.log('Papertrail is running at http://127.0.0.1:' + port));
