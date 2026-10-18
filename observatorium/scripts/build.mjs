// @trace order:1661-vckd, spec:observatorium-dashboard
// The ONE build the observatorium has, run the same way everywhere:
//
//   Cloudflare Workers Builds  Build command `npm run build` (root dir
//                              observatorium). Workers Builds does NOT run
//                              wrangler.jsonc's build.command ("Workers Builds
//                              does not honor the configurations set in Custom
//                              Builds within your Wrangler configuration file").
//   A local `wrangler deploy`  wrangler.jsonc's build.command (the same script).
//   A forge / toolbox          `npm run build`, then publish_local serves build/web
//                              (the preview strips build.command; 1663-6mns).
//
// Modes:
//   (default)                  pinned toolchains, live metrics (display-only),
//                              Flutter release web build into build/web
//   --metrics-only             the same without the Flutter build
//   --release-snapshot <tag>   the release cut: append ONE snapshot naming <tag>
//                              to history/snapshots.jsonl (committed; the durable
//                              history is the repository, updated by the release
//                              cut, never by a deploy)
//
// Every download is pinned by URL and SHA-256. Nothing here needs a secret.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, createReadStream, existsSync, mkdirSync, renameSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(app, '..');
const cache = resolve(process.env.OBSERVATORIUM_CACHE || resolve(app, '.cache'));
const tools = resolve(process.env.OBSERVATORIUM_TOOLS || resolve(app, '.tools'));
const committedHistory = resolve(app, 'history/snapshots.jsonl');

export const PINS = {
  // Flutter 3.47.7 stable (Dart 3.13.5), from Flutter's own release manifest
  // (storage.googleapis.com/flutter_infra_release/releases/releases_linux.json).
  flutter: {
    version: '3.47.7',
    url: 'https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.7-stable.tar.xz',
    sha256: 'af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230',
  },
  // rustup-init 1.28.2 (its published .sha256). The Rust toolchain itself is
  // the repository's pinned one: rustup reads ../rust-toolchain.toml.
  rustup: {
    version: '1.28.2',
    url: 'https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init',
    sha256: '20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c',
  },
};

const timings = [];
async function phase(name, fn) {
  const start = Date.now();
  const result = await fn();
  const seconds = Math.round((Date.now() - start) / 100) / 10;
  timings.push([name, seconds]);
  console.log(`observatorium-build: ${name} ${seconds}s`);
  return result;
}

function run(command, args, { cwd = app, env = process.env, allowFail = false } = {}) {
  const result = spawnSync(command, args, { cwd, stdio: 'inherit', env });
  if (result.error) throw result.error;
  if (result.status !== 0 && !allowFail) {
    console.error(`observatorium-build: ${command} ${args.join(' ')} exited ${result.status}`);
    process.exit(result.status || 1);
  }
  return result.status === 0;
}

function capture(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' });
  return result.status === 0 ? result.stdout.trim() : null;
}

async function sha256(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

/** Download `pin.url` to `path` and refuse anything whose SHA-256 differs. */
async function fetchPinned(pin, path) {
  const partial = `${path}.partial`;
  run('curl', ['-fsSL', '--retry', '3', '-o', partial, pin.url], { cwd: tools });
  const got = await sha256(partial);
  if (got !== pin.sha256) {
    rmSync(partial, { force: true });
    throw Error(`checksum mismatch for ${pin.url}: want ${pin.sha256}, got ${got}`);
  }
  renameSync(partial, path);
}

async function ensureFlutter() {
  const managed = flutterCommand(process.env);
  if (managed) return managed;
  const dir = resolve(tools, `flutter-${PINS.flutter.version}`);
  const bin = resolve(dir, 'flutter/bin/flutter');
  if (existsSync(bin)) return bin;
  mkdirSync(dir, { recursive: true });
  const archive = resolve(tools, `flutter-${PINS.flutter.version}.tar.xz`);
  await fetchPinned(PINS.flutter, archive);
  run('tar', ['-xJf', archive, '-C', dir]);
  rmSync(archive, { force: true });
  return bin;
}

// A forge already supplies a trusted sibling toolchain through its Flutter
// command. Downloading another SDK into the ephemeral checkout bypasses that
// path and can exhaust the checkout before the app even compiles.
export function flutterCommand(env) {
  if (env.FLUTTER) return env.FLUTTER;
  if (env.TILLANDSIAS_PROJECT) return 'flutter';
  return null; // Standalone Workers Builds uses the pinned download above.
}

/** tillandsias-plan: given, or built from this checkout with the pinned toolchain. */
async function ensurePlan() {
  if (process.env.TILLANDSIAS_PLAN_BIN && existsSync(process.env.TILLANDSIAS_PLAN_BIN)) {
    return process.env.TILLANDSIAS_PLAN_BIN;
  }
  const env = { ...process.env };
  if (!capture('cargo', ['--version'])) {
    const rustupHome = resolve(tools, 'rustup');
    const cargoHome = resolve(tools, 'cargo');
    env.RUSTUP_HOME = rustupHome;
    env.CARGO_HOME = cargoHome;
    env.PATH = `${resolve(cargoHome, 'bin')}:${env.PATH}`;
    if (!existsSync(resolve(cargoHome, 'bin/cargo'))) {
      mkdirSync(tools, { recursive: true });
      const init = resolve(tools, `rustup-init-${PINS.rustup.version}`);
      if (!existsSync(init)) await fetchPinned(PINS.rustup, init);
      run('chmod', ['0755', init]);
      run(init, ['-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', 'none'], { env });
    }
  }
  const target = resolve(env.CARGO_TARGET_DIR || resolve(root, 'target'));
  // rustup installs the toolchain ../rust-toolchain.toml names, then builds.
  run('cargo', ['build', '--release', '--locked', '-p', 'tillandsias-plan'], { cwd: root, env });
  return resolve(target, 'release/tillandsias-plan');
}

/** Workers Builds may clone shallowly (undocumented): deepen when possible. */
function unshallow() {
  if (capture('git', ['rev-parse', '--is-shallow-repository']) !== 'true') return 'full';
  return run('git', ['fetch', '--unshallow', '--quiet'], { cwd: root, allowFail: true }) ? 'unshallowed' : 'shallow';
}

async function main() {
  const argv = process.argv.slice(2);
  const tagAt = argv.indexOf('--release-snapshot');
  const releaseTag = tagAt >= 0 ? argv[tagAt + 1] : null;
  if (tagAt >= 0 && !/^v\d+\.\d+\.\d+\.\d+$/.test(releaseTag || '')) {
    throw Error('--release-snapshot needs a release tag like v56.10.13.1');
  }
  mkdirSync(cache, { recursive: true });
  mkdirSync(tools, { recursive: true });

  const plan = await phase('tillandsias-plan', () => ensurePlan());
  const env = { ...process.env, TILLANDSIAS_PLAN_BIN: plan };
  const history = await phase('git-history', unshallow);
  console.log(`observatorium-build: git history ${history}`);

  if (releaseTag) {
    // The release cut: ONE committed line, naming the release it describes.
    await phase('collect-release', () => run(process.execPath, ['metrics/collect.mjs', '--root', root,
      '--output', resolve(cache, 'release-snapshot.json'), '--history', committedHistory,
      '--release', releaseTag, '--grade'], { env }));
    return;
  }

  // A deploy or local build: the live observation is DISPLAY-ONLY. It is
  // projected next to the committed history and never written back to it.
  const snapshot = resolve(cache, 'snapshot.json');
  await phase('collect', () => run(process.execPath, ['metrics/collect.mjs', '--root', root,
    '--output', snapshot, '--grade'], { env }));
  mkdirSync(resolve(app, 'web/data'), { recursive: true });
  const historyArgs = existsSync(committedHistory) ? ['--history', committedHistory] : [];
  await phase('precompute', () => run(process.execPath, ['metrics/precompute.mjs', '--root', root,
    '--snapshot', snapshot, ...historyArgs, '--output', resolve(app, 'web/data/metrics.json')], { env }));
  if (argv.includes('--metrics-only')) return;

  const flutter = await ensureFlutter();
  await phase('flutter-pub-get', () => run(flutter, ['pub', 'get']));
  await phase('flutter-build-web', () => run(flutter, ['build', 'web', '--release', '--no-web-resources-cdn']));
  copyFileSync(resolve(app, 'web/_headers'), resolve(app, 'build/web/_headers'));
}

const started = Date.now();
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main()
  .then(() => {
    const total = Math.round((Date.now() - started) / 1000);
    console.log(`observatorium-build: total ${total}s (${timings.map(([n, s]) => `${n}=${s}s`).join(' ')})`);
  })
  .catch((error) => {
    console.error(`observatorium-build: ${error.message}`);
    process.exit(1);
  });
