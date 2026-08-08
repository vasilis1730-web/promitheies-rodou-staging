import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomInt } from 'node:crypto';
import { once } from 'node:events';

const serverFile = new URL('../local-server.mjs', import.meta.url);

test('ο τοπικός server σερβίρει την εφαρμογή και τις καρφιτσωμένες βιβλιοθήκες', async t => {
  const port = randomInt(30000, 60000);
  const child = spawn(process.execPath, [serverFile.pathname], {
    env: { ...process.env, PROMITHEIES_PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  t.after(() => {
    if (child.exitCode === null) child.kill();
  });

  let startupError = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', chunk => { startupError += chunk; });

  let response;
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      response = await fetch(`http://127.0.0.1:${port}/index.html`);
      break;
    } catch {
      await new Promise(resolve => setTimeout(resolve, 25));
    }
  }

  assert.ok(response, `ο server δεν ξεκίνησε: ${startupError}`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type') || '', /^text\/html/);
  const html = await response.text();
  assert.match(html, /v36\.6\.3 PRODUCTION READINESS/);
  assert.match(html, /omncqldgtkdcjpqfwwlr\.supabase\.co/);

  const vendorResponse = await fetch(`http://127.0.0.1:${port}/vendor/supabase.js`, { method: 'HEAD' });
  assert.equal(vendorResponse.status, 200);
  assert.match(vendorResponse.headers.get('content-type') || '', /^text\/javascript/);

  child.kill();
  await once(child, 'exit');
});
