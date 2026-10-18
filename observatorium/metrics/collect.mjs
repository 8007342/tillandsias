#!/usr/bin/env node
// @trace order:1661-vckd
// @trace spec:observatorium-dashboard
// freshness: auditor=forge-observatorium date=2026-10-13 verdict=updated scope=collector
// Cheap repository observation. No historical tree replay and no test execution.
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {count, GRADE_LIMITS, RECORD_SCOPE, releaseEvidence, validateResidual} from './evidence.mjs';
import {gateInventory, INVENTORY_DEFINITION} from './inventory.mjs';

export const EPOCH = 'repository-observation-v2';
export const DEFINITIONS = {
  specs: {definition: 'Specification files', source: 'openspec/specs/*/spec.md', unit: 'files'},
  requirements: {definition: 'Requirement headings outside fenced code (all spec statuses)', source: 'openspec/specs/*/spec.md', unit: 'headings'},
  scenarios: {definition: 'Scenario headings outside fenced code (all spec statuses)', source: 'openspec/specs/*/spec.md', unit: 'headings'},
  plan: {definition: 'Folded plan packets', source: 'tillandsias-plan query --json canonical fold', unit: 'packets'},
  fragments: {definition: 'Plan index fragments', source: 'plan/index.d/*.yaml', unit: 'files'},
  residual: {definition: 'Untested canonical scenario obligations, including requirements with no scenario', source: 'centicolon-grade-observed/1 fresh observation', unit: 'obligations'},
  earned: {definition: 'Canonical obligations at positively_tested', source: 'centicolon-grade-observed/1', unit: 'obligations'},
  denominator: {definition: 'Canonical scenario obligations plus requirements with no scenario, from registered active or draft specs', source: 'centicolon-extract/1', unit: 'obligations'},
  lua_gate_targets: {definition: INVENTORY_DEFINITION, source: 'scripts/gate-steps.d/*.step', unit: 'Lua targets'},
  shell_gate_targets: {definition: INVENTORY_DEFINITION, source: 'scripts/gate-steps.d/*.step', unit: 'shell targets'},
};
export function options(argv, allowed) {
  const result = {};
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i].replace(/^--/, '');
    if (!argv[i].startsWith('--') || !allowed.includes(key)) throw Error(`Unknown option: ${argv[i]}`);
    if (key === 'grade') result[key] = true;
    else {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw Error(`Missing value: --${key}`);
      result[key] = argv[++i];
    }
  }
  return result;
}
export function atomicJson(path, value) {
  mkdirSync(dirname(path), {recursive: true});
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`);
  renameSync(temporary, path);
}
function command(root, program, args, timeout = 30000, env = process.env) {
  return execFileSync(program, args, {cwd: root, encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024, env, stdio: ['ignore', 'pipe', 'pipe']}).trim();
}
function foldedPlan(root) {
  const result = spawnSync(process.env.TILLANDSIAS_PLAN_BIN || 'tillandsias-plan', ['--index', join(root, 'plan/index.yaml'), 'query', '--json', '--limit', '1000000'], {cwd: root, encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024});
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`Canonical plan query failed (${result.status}): ${(result.stderr || '').trim().split('\n')[0]}`);
  // The canonical reader deliberately returns success with a partial fold when
  // malformed fragments are skipped. Publishing that as complete would turn
  // lost evidence into apparently improved counts. Keep the source warning.
  const damage = (result.stderr || '').split('\n').find(line => /skipped|does not parse|malformed|incomplete/i.test(line));
  if (damage) throw Error(`Incomplete canonical ledger: ${damage.trim()}`);
  return summarizePlan(JSON.parse(result.stdout));
}
export function countSpec(text) {
  // Markdown code examples can contain headings; they are not requirements.
  let fence = null, requirements = 0, scenarios = 0;
  for (const line of text.split(/\r?\n/)) {
    const marker = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
      continue;
    }
    if (fence) continue;
    if (/^###\s+Requirement\s*:/i.test(line)) requirements++;
    if (/^####\s+Scenario\s*:/i.test(line)) scenarios++;
  }
  return {requirements, scenarios};
}
export function summarizePlan(rows) {
  if (!Array.isArray(rows)) throw Error('Plan query did not return an array');
  const states = {}, seen = new Set();
  const details = rows.map(row => {
    if (!row.packet_id || !row.status || seen.has(row.packet_id)) throw Error('Invalid or duplicate folded plan row');
    seen.add(row.packet_id);
    states[row.status] = (states[row.status] || 0) + 1;
    return {id: row.packet_id, order: row.order, title: row.title || row.packet_id, status: row.status};
  });
  return {total: rows.length, states, details};
}
export function collect(root, {grade = false, now = new Date().toISOString(), release = null} = {}) {
  const gaps = [], details = {specs: [], plan: [], obligations: [], luaMigration: []};
  const revision = command(root, 'git', ['rev-parse', 'HEAD']);
  const dirty = command(root, 'git', ['status', '--porcelain', '--untracked-files=normal']).length > 0;
  const shallow = command(root, 'git', ['rev-parse', '--is-shallow-repository']) === 'true';
  if (dirty) gaps.push('This observation includes uncommitted working-tree files; revision identifies the base commit.');
  if (shallow) gaps.push('Git history is shallow: commit totals cover only locally available ancestors.');
  const specRoot = join(root, 'openspec/specs');
  let specs = null;
  if (existsSync(specRoot)) {
    for (const entry of readdirSync(specRoot, {withFileTypes: true}).sort((a, b) => a.name.localeCompare(b.name))) {
      const path = `openspec/specs/${entry.name}/spec.md`;
      if (entry.isDirectory() && existsSync(join(root, path))) details.specs.push({path, ...countSpec(readFileSync(join(root, path), 'utf8'))});
    }
    specs = {files: details.specs.length, requirements: 0, scenarios: 0};
    for (const spec of details.specs) { specs.requirements += spec.requirements; specs.scenarios += spec.scenarios; }
  } else gaps.push('openspec/specs is absent; specification counts are unknown.');
  let plan = {total: null, states: {}, source: 'tillandsias-plan query --json (base plus fragments)'};
  if (existsSync(join(root, 'plan/index.yaml'))) {
    try {
      // Reuse the canonical CRDT fold. Parsing index.yaml alone silently misses overlays.
      const folded = foldedPlan(root);
      if (folded.total >= 1000000) throw Error('Query ceiling reached; count would be truncated');
      details.plan = folded.details;
      plan = {...plan, total: folded.total, states: folded.states};
    } catch (error) { gaps.push(`Folded plan unavailable: ${error.message.split('\n')[0]}`); }
  } else gaps.push('plan/index.yaml is absent; folded plan counts are unknown.');
  const fragments = existsSync(join(root, 'plan/index.d')) ? readdirSync(join(root, 'plan/index.d')).filter(name => /\.ya?ml$/.test(name)).length : 0;
  plan.fragments = fragments;
  const inventory = gateInventory(root);
  details.luaMigration = inventory.details;
  if (inventory.summary.unavailable.length) gaps.push(`Gate script inventory unavailable: ${inventory.summary.unavailable.join('; ')}`);
  let residual = {value: null, source: 'centicolon-grade-observed/1', reason: 'Fresh obligation grading was not requested; cached grades are not treated as current.'};
  if (grade) {
    try {
      command(root, 'bash', ['scripts/centicolon-grade.sh'], 120000, {...process.env, TILLANDSIAS_REPO_ROOT: root, TILLANDSIAS_CENTICOLON_DIR: 'target/observatorium-centicolon'});
      const artifact = 'target/observatorium-centicolon/grade.json';
      const bytes = readFileSync(join(root, artifact), 'utf8');
      const result = JSON.parse(bytes);
      if (result.schema !== 'centicolon-grade-observed/1') throw Error('Invalid grade schema');
      const digest = text => createHash('sha256').update(text).digest('hex');
      const provenance = {revision, measuredAt: now, dirty, gradeSchema: result.schema, gradeSha256: digest(bytes), artifact, recordScope: RECORD_SCOPE, limitations: [...GRADE_LIMITS]};
      // Order 1670-gcwu: a grade over zero resolved requirement keys measures
      // nothing (R = denominator by construction); it is a gap, never a value.
      if (result.measured === false) residual = {value: null, unmeasured: true, denominator: count(result.denominator, 'obligation denominator'), source: result.schema, provenance, reason: `CentiColon grade unmeasured (${result.unmeasured_reason || 'no reason given'}): no litmus step names a requirement it pins, so no obligation can be traced or tested.`};
      else {
        if (result.measured !== true) throw Error('Grade does not explicitly declare measured:true');
        residual = validateResidual({value: result.R, denominator: result.denominator, satisfied: result.satisfied, measured: true, source: result.schema,
          reason: 'Fresh canonical grader observation. Test bindings identify declared, traced and positively tested obligations; the global run-log count is not per-obligation evidence.',
          histogram: result.histogram, traced: result.histogram?.traced ?? null, positivelyTested: result.histogram?.positively_tested ?? result.satisfied,
          reasons: result.residue_reasons, records: result.records, provenance});
      }
      let extracted = null;
      for (const [name, key] of [['obligations.json', 'obligationsSha256'], ['static.json', 'staticSha256']]) {
        const path = join(root, 'target/observatorium-centicolon', name);
        if (existsSync(path)) {
          const content = readFileSync(path, 'utf8');
          provenance[key] = digest(content);
          if (name === 'obligations.json') extracted = JSON.parse(content);
        }
      }
      const titles = new Map((extracted?.obligations || []).map(row => [row.id, row]));
      if (Array.isArray(result.obligations)) {
        const seen = new Set(), histogram = {declared: 0, traced: 0, positively_tested: 0};
        details.obligations = result.obligations.map(row => {
          if (!row.id || !row.req_id || !row.spec || !row.reason || seen.has(row.id) || !Object.hasOwn(histogram, row.state)) throw Error('Invalid or duplicate obligation detail');
          seen.add(row.id); histogram[row.state]++;
          const title = titles.get(row.id);
          return {id: row.id, req_id: row.req_id, spec: row.spec, state: row.state, reason: row.reason,
            ...(row.host ? {host: row.host} : {}), ...(row.regime ? {regime: row.regime} : {}),
            ...(title ? {title: title.title, requirement: title.requirement} : {})};
        });
        if (details.obligations.length !== result.denominator || histogram.positively_tested !== result.satisfied) throw Error('Obligation details disagree with grade totals');
        if (result.histogram && Object.keys(histogram).some(state => histogram[state] !== result.histogram[state])) throw Error('Obligation details disagree with grade histogram');
        provenance.scopeSha256 = digest([...seen].sort().join('\n'));
      } else provenance.limitations.push('Per-obligation rows were not supplied by this grader artifact.');
      if (extracted) {
        provenance.population = extracted.population;
        provenance.excluded = extracted.excluded;
        provenance.invariantsExcluded = extracted.invariant_count;
        provenance.populationGaps = {unregistered: extracted.unregistered || [], missing: extracted.missing || [], unkeyed: extracted.unkeyed || []};
        if (Object.values(provenance.populationGaps).some(rows => rows.length)) gaps.push('CentiColon population has unregistered, missing or unkeyed entries; see grade provenance.');
      }
      if (result.static_refused?.length) provenance.limitations.push(`Static grader reported: ${result.static_refused.join('; ')}`);
    } catch (error) { details.obligations = []; residual = {value: null, source: 'centicolon-grade-observed/1', reason: `Fresh obligation grading unavailable: ${error.message.split('\n')[0]}`}; }
  }
  residual = {...residual, measuredAt: now, revision, dirty};
  if (residual.value === null) gaps.push(residual.reason);
  // Order 1661-vckd: the release cut stamps the release its snapshot describes.
  if (release !== null && !/^v\d+\.\d+\.\d+\.\d+$/.test(release)) throw Error(`Invalid release tag: ${release}`);
  return {schemaVersion: 1, epoch: EPOCH, definitions: DEFINITIONS, measuredAt: now, revision, ...(release ? {release} : {}), dirty, shallow, current: {specs, plan, residual, luaMigration: inventory.summary, commits: {total: Number(command(root, 'git', ['rev-list', '--count', 'HEAD']))}}, details, gaps};
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = options(process.argv.slice(2), ['root', 'output', 'history', 'grade', 'release']);
    if (!args.output) throw Error('Usage: collect.mjs --root REPO --output SNAPSHOT [--history JSONL] [--grade]');
    const snapshot = collect(resolve(args.root || '.'), args);
    // A release cut is the dashboard's HEADLINE grade (Workers Builds runs no
    // litmus), so it must be a measured grade over recorded litmus results.
    if (args.release) {
      try { releaseEvidence(snapshot); }
      catch (error) { throw Error(`Refusing the ${args.release} release snapshot: not a measurement over recorded litmus results (${error.message}; ${snapshot.current.residual.reason}).`); }
      if (args.history && existsSync(resolve(args.history))) {
        const previous = readFileSync(resolve(args.history), 'utf8').split('\n').filter(line => line.trim()).map(line => JSON.parse(line));
        if (previous.some(row => row.release === args.release)) throw Error(`Refusing duplicate release snapshot: ${args.release}`);
      }
    }
    atomicJson(resolve(args.output), snapshot);
    if (args.history) {
      mkdirSync(dirname(resolve(args.history)), {recursive: true});
      // Durable history keeps counts/provenance, not a repeated full packet catalog.
      const {details, ...historical} = snapshot;
      appendFileSync(resolve(args.history), `${JSON.stringify(historical)}\n`);
    }
    console.log(`Collected ${snapshot.measuredAt} at ${snapshot.revision.slice(0, 12)}; ${snapshot.gaps.length} explicit gaps`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
