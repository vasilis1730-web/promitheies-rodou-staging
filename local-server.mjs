import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOST = '127.0.0.1';
const PORT = Number.parseInt(process.env.PROMITHEIES_PORT || '8080', 10);
const ROOT = resolve(fileURLToPath(new URL('.', import.meta.url)));
const TYPES = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.png', 'image/png'],
  ['.svg', 'image/svg+xml']
]);

function safePath(requestUrl) {
  const url = new URL(requestUrl || '/', `http://${HOST}:${PORT}`);
  let pathname;
  try {
    pathname = decodeURIComponent(url.pathname);
  } catch {
    return null;
  }
  if (pathname === '/') pathname = '/index.html';
  const absolute = resolve(ROOT, `.${pathname}`);
  return absolute === ROOT || absolute.startsWith(ROOT + sep) ? absolute : null;
}

const server = createServer(async (request, response) => {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    response.writeHead(405, { Allow: 'GET, HEAD' });
    response.end('Method Not Allowed');
    return;
  }
  const path = safePath(request.url);
  if (!path) {
    response.writeHead(400);
    response.end('Bad Request');
    return;
  }
  try {
    const info = await stat(path);
    if (!info.isFile()) throw new Error('Not a file');
    response.writeHead(200, {
      'Content-Type': TYPES.get(extname(path).toLowerCase()) || 'application/octet-stream',
      'Content-Length': info.size,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff'
    });
    if (request.method === 'HEAD') response.end();
    else createReadStream(path).pipe(response);
  } catch {
    response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    response.end('Δεν βρέθηκε το αρχείο.');
  }
});

server.on('error', error => {
  if (error && error.code === 'EADDRINUSE') {
    console.error(`Η θύρα ${PORT} χρησιμοποιείται ήδη. Κλείστε τον άλλο τοπικό server και δοκιμάστε ξανά.`);
  } else {
    console.error('Αποτυχία τοπικού server:', error && error.message || error);
  }
  process.exitCode = 1;
});

server.listen(PORT, HOST, () => {
  console.log(`Η εφαρμογή εκτελείται στο http://${HOST}:${PORT}/index.html`);
  console.log('Για τερματισμό πατήστε Ctrl+C ή κλείστε αυτό το παράθυρο.');
});
