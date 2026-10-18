// @trace order:1782-bek5, spec:observatorium-dashboard
import {existsSync, readFileSync, readdirSync, statSync} from 'node:fs';
import {join} from 'node:path';

export const INVENTORY_DEFINITION = 'Distinct existing script targets referenced by literal STEP_LUA or STEP_SCRIPT declarations in gate manifests; inventory only, not execution or earned obligations.';
export function gateInventory(root) {
  const source = 'scripts/gate-steps.d/*.step literal targets';
  const result = {lua: null, shell: null, total: null, source, definition: INVENTORY_DEFINITION, epoch: 'gate-target-inventory-v1', unavailable: [], reason: INVENTORY_DEFINITION};
  const directory = join(root, 'scripts/gate-steps.d');
  const rows = new Map();
  if (!existsSync(directory)) return {summary: {...result, unavailable: ['scripts/gate-steps.d is absent']}, details: []};
  for (const name of readdirSync(directory).filter(n => n.endsWith('.step')).sort()) {
    const manifest = `scripts/gate-steps.d/${name}`;
    const text = readFileSync(join(root, manifest), 'utf8');
    const declarations = text.split(/\r?\n/).filter(line => /^\s*STEP_(LUA|SCRIPT)=/.test(line));
    const match = declarations.length === 1 && declarations[0].match(/^\s*STEP_(LUA|SCRIPT)=(?:"([^"$`]+)"|'([^']+)'|([^\s$`#]+))\s*(?:#.*)?$/);
    const path = match && (match[2] || match[3] || match[4]);
    const language = match && (match[1] === 'LUA' ? 'lua' : 'shell');
    if (!path || !/^scripts\/[\w./-]+$/.test(path) || path.split('/').includes('..') || !path.endsWith(language === 'lua' ? '.lua' : '.sh')) {
      result.unavailable.push(`${manifest}: missing, ambiguous or nonliteral script target`);
      continue;
    }
    if (!existsSync(join(root, path)) || !statSync(join(root, path)).isFile()) {
      result.unavailable.push(`${manifest}: target ${path} is absent`);
      continue;
    }
    if (!rows.has(path)) rows.set(path, {path, language, manifests: []});
    rows.get(path).manifests.push(manifest);
  }
  const details = [...rows.values()].sort((a, b) => a.path.localeCompare(b.path));
  if (!result.unavailable.length) {
    result.lua = details.filter(row => row.language === 'lua').length;
    result.shell = details.filter(row => row.language === 'shell').length;
    result.total = details.length;
  }
  return {summary: result, details};
}
