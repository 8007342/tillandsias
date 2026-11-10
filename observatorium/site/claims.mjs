// @trace order:2066-obsv, spec:observatorium-dashboard
// The claims register (design.md V4). data/claims.yaml is a strict YAML subset
// read without a dependency: one list of flat maps whose values are a double-
// quoted string, a bare word (spaces allowed) or null. Anything else fails
// the build rather than being guessed at.

export const STRENGTHS = ['proved', 'property-tested', 'tested by name', 'external analogy',
  'assumed', 'open', 'withdrawn', 'on paper only'];
export const REVIEWS = ['operator-pending', 'operator-reviewed'];
const KEYS = ['id', 'statement', 'strength', 'scope', 'since', 'discharge', 'review'];
const REQUIRED = ['id', 'statement', 'strength', 'scope', 'discharge', 'review'];

function scalar(raw, at) {
  const v = raw.trim();
  if (v === 'null') return null;
  if (v.startsWith('"')) {
    if (!/^"(?:[^"\\]|\\.)*"$/.test(v)) throw Error(`claims.yaml line ${at}: unterminated string`);
    return JSON.parse(v);
  }
  if (!v || /[:#{}\[\]&*!|>'"%@`]/.test(v)) throw Error(`claims.yaml line ${at}: value must be quoted`);
  return v;
}

export function parseClaims(text) {
  const claims = [];
  let cur = null;
  text.split('\n').forEach((line, i) => {
    const at = i + 1;
    if (!line.trim() || /^\s*#/.test(line)) return;
    const m = line.match(/^(- |  )([a-z_]+):(?: (.*))?$/);
    if (!m || m[3] === undefined) throw Error(`claims.yaml line ${at}: not a flat "key: value" entry`);
    const [, lead, key, raw] = m;
    if (lead === '- ') { cur = {}; claims.push(cur); }
    else if (!cur) throw Error(`claims.yaml line ${at}: entry before the first "- "`);
    if (!KEYS.includes(key)) throw Error(`claims.yaml line ${at}: unknown key ${key}`);
    if (key in cur) throw Error(`claims.yaml line ${at}: repeated key ${key}`);
    cur[key] = scalar(raw, at);
  });
  const seen = new Set();
  for (const c of claims) {
    for (const k of REQUIRED) if (c[k] == null) throw Error(`claims.yaml: claim ${c.id ?? '?'} lacks ${k}`);
    if (!/^[a-z0-9-]+$/.test(c.id)) throw Error(`claims.yaml: bad id ${c.id}`);
    if (seen.has(c.id)) throw Error(`claims.yaml: duplicate id ${c.id}`);
    seen.add(c.id);
    if (!STRENGTHS.includes(c.strength)) throw Error(`claims.yaml: claim ${c.id} has unknown strength "${c.strength}"`);
    if (!REVIEWS.includes(c.review)) throw Error(`claims.yaml: claim ${c.id} has unknown review "${c.review}"`);
    c.since ??= null;
  }
  return claims;
}
