import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const launcherUrl = new URL('../start-local.bat', import.meta.url);
const powershellServerUrl = new URL('../local-server.ps1', import.meta.url);

test('ο Windows launcher είναι ASCII με αποκλειστικά CRLF και χωρίς εξωτερική απαίτηση Node/Python', async () => {
  const bytes = await readFile(launcherUrl);
  const text = bytes.toString('ascii');

  assert.ok([...bytes].every(byte => byte < 128), 'το batch πρέπει να περιέχει μόνο ASCII');
  assert.equal(text.replaceAll('\r\n', '').includes('\n'), false, 'βρέθηκε bare LF');
  assert.equal(text.replaceAll('\r\n', '').includes('\r'), false, 'βρέθηκε bare CR');
  assert.match(text, /^@echo off\r\n/);
  assert.match(text, /powershell\.exe .*local-server\.ps1/);
  assert.match(text, /if not errorlevel 1 goto use_windows_powershell/);
  assert.doesNotMatch(text, /%errorlevel%/i);
  assert.doesNotMatch(text, /chcp/i);
});

test('ο ενσωματωμένος PowerShell server περιορίζεται στο loopback και αποκλείει διαφυγή διαδρομής', async () => {
  const script = await readFile(powershellServerUrl, 'utf8');

  assert.match(script, /IPAddress\]::Parse\('127\.0\.0\.1'\)/);
  assert.match(script, /StartsWith\(\$RootPrefix, \[System\.StringComparison\]::OrdinalIgnoreCase\)/);
  assert.match(script, /X-Content-Type-Options: nosniff/);
  assert.match(script, /Cache-Control: no-store/);
  assert.match(script, /Start-Process \$Url/);
});
