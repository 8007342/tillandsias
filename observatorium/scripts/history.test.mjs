import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';

test('durable branch restores consecutive observations and rejects remote outage', () => {
  const fixture = mkdtempSync(join(tmpdir(), 'observatorium-history-'));
  try {
    const remote = join(fixture, 'remote.git');
    const root = join(fixture, 'project');
    const app = join(root, 'observatorium');
    mkdirSync(join(app, 'scripts'), { recursive: true });
    const git = (...args) => execFileSync('git', args, { cwd: root, stdio: 'pipe' });
    execFileSync('git', ['init', '--bare', remote], { stdio: 'pipe' });
    git('init'); git('remote', 'add', 'origin', remote);
    copyFileSync(new URL('./history.mjs', import.meta.url), join(app, 'scripts/history.mjs'));
    const invoke = (operation) => execFileSync(process.execPath, ['scripts/history.mjs', operation], { cwd: app, stdio: 'pipe' });
    invoke('restore');
    const history = join(app, '.cache/snapshots.jsonl');
    // A long-running deployment ledger must restore beyond execFile's default
    // 1 MiB buffer without truncating or inventing an empty first deployment.
    const first = JSON.stringify({ observed_at: '2026-10-13T00:00:00Z', value: 1,
      provenance: 'x'.repeat(1024 * 1024 + 4096) }) + '\n';
    writeFileSync(history, first); invoke('save');
    writeFileSync(history, ''); invoke('restore');
    assert.equal(readFileSync(history, 'utf8'), first);
    const both = first + '{"observed_at":"2026-10-14T00:00:00Z","value":2}\n';
    writeFileSync(history, both); invoke('save');
    writeFileSync(history, ''); invoke('restore');
    assert.equal(readFileSync(history, 'utf8'), both);
    git('remote', 'set-url', 'origin', join(fixture, 'unreachable.git'));
    const failed = spawnSync(process.execPath, ['scripts/history.mjs', 'restore'], { cwd: app, stdio: 'pipe' });
    assert.notEqual(failed.status, 0);
    assert.equal(readFileSync(history, 'utf8'), both, 'outage must not replace known observations');
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});
