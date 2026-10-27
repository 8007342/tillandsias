#!/usr/bin/env bash
# test-start-a-new-project-cloudflare.sh — a new web app gets its Cloudflare
# files without anyone asking (order 1907-xhpx).
#
# ARM 1 --stack web, no --deploy: wrangler.jsonc (static, ./public), a page in
#       public/, .dev.vars.example, and .dev.vars in .gitignore
# ARM 2 --stack flutter, no --deploy: wrangler.jsonc serves ./build/web as a
#       single-page app
# ARM 3 the config parses; name is the slug; compatibility_date is a date
# ARM 4 no account id, token or secret-shaped value in any created file
# ARM 5 --deploy none writes no Cloudflare file; --stack other and
#       flutter-flame get none by default
# ARM 6 an existing wrangler.jsonc and .gitignore line are kept, not rewritten
#
# Pre-fix: FAILS at ARM 1, scaffold.sh writes no wrangler.jsonc.
#
# @trace order:1907-xhpx
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCAFFOLD="$ROOT/skills/start-a-new-project/scaffold.sh"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0 failed=0
ok() { echo "ok: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; failed=$((failed + 1)); }

# jsonc_get <file> <jq filter> — drop whole-line // comments, then read with jq.
jsonc_get() { sed '/^[[:space:]]*\/\//d' "$1" | jq -r "$2" 2>/dev/null; }

run() { local d="$W/$1"; shift; mkdir -p "$d"; bash "$SCAFFOLD" --dir "$d" --no-specs "$@" >"$d.out" 2>&1; echo $?; }

# ARM 1
rc="$(run web --name "Webby Web" --summary "A small website." --stack web)"
P="$W/web"
if [ "$rc" -eq 0 ] && [ -f "$P/wrangler.jsonc" ] && [ -f "$P/public/index.html" ] \
    && [ -f "$P/.dev.vars.example" ] && grep -qx '.dev.vars' "$P/.gitignore" 2>/dev/null \
    && [ "$(jsonc_get "$P/wrangler.jsonc" '.assets.directory')" = "./public" ]; then
    ok "ARM 1: --stack web gains wrangler.jsonc (./public), a page, .dev.vars.example and an ignored .dev.vars"
else
    bad "ARM 1: rc=$rc files=$(cd "$P" 2>/dev/null && ls -A | tr '\n' ' ')"
fi

# ARM 2
rc="$(run flut --name "Pong Party" --summary "A pong game." --stack flutter)"
F="$W/flut"
if [ "$rc" -eq 0 ] && [ "$(jsonc_get "$F/wrangler.jsonc" '.assets.directory')" = "./build/web" ] \
    && [ "$(jsonc_get "$F/wrangler.jsonc" '.assets.not_found_handling')" = "single-page-application" ]; then
    ok "ARM 2: --stack flutter serves ./build/web as a single-page app"
else
    bad "ARM 2: rc=$rc assets=$(jsonc_get "$F/wrangler.jsonc" '.assets' | tr -d '\n ')"
fi

# ARM 3
n1="$(jsonc_get "$P/wrangler.jsonc" '.name')" n2="$(jsonc_get "$F/wrangler.jsonc" '.name')"
d1="$(jsonc_get "$P/wrangler.jsonc" '.compatibility_date')"
if [ "$n1" = "webby-web" ] && [ "$n2" = "pong-party" ] && [[ "$d1" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]$ ]]; then
    ok "ARM 3: the configs parse, name is the slug, compatibility_date is a date"
else
    bad "ARM 3: names='$n1' '$n2' date='$d1'"
fi

# ARM 4
leak="$(grep -rniE 'account_id|api_token|CLOUDFLARE_|secret[[:space:]]*[:=]|[A-Za-z0-9_-]{32,}' "$P" "$F" \
    --include='*.jsonc' --include='.dev.vars*' --include='*.html' 2>/dev/null)"
if [ -z "$leak" ] && [ -s "$P/wrangler.jsonc" ]; then
    ok "ARM 4: no account id, token or secret-shaped value in the created files"
else
    bad "ARM 4: $(head -2 <<<"$leak" | tr '\n' ' ')"
fi

# ARM 5
rc1="$(run none --name "Plain" --summary "x." --stack web --deploy none)"
rc2="$(run other --name "Other" --summary "x." --stack other)"
rc3="$(run flame --name "Flame" --summary "x." --stack flutter-flame)"
stray="$(ls "$W/none/wrangler.jsonc" "$W/other/wrangler.jsonc" "$W/flame/wrangler.jsonc" \
    "$W/none/.dev.vars.example" 2>/dev/null)"
if [ "$rc1$rc2$rc3" = "000" ] && [ -z "$stray" ]; then
    ok "ARM 5: --deploy none, --stack other and flutter-flame write no Cloudflare file"
else
    bad "ARM 5: rc=$rc1/$rc2/$rc3 stray=$stray"
fi

# ARM 6
K="$W/keep"; mkdir -p "$K"
printf '{ "name": "mine" }\n' >"$K/wrangler.jsonc"; printf 'node_modules\n.dev.vars\n' >"$K/.gitignore"
cp "$K/wrangler.jsonc" "$W/w.keep"; cp "$K/.gitignore" "$W/g.keep"
rc="$(run keep --name "Keep" --summary "x." --stack web)"
if [ "$rc" -eq 0 ] && cmp -s "$K/wrangler.jsonc" "$W/w.keep" && cmp -s "$K/.gitignore" "$W/g.keep"; then
    ok "ARM 6: an existing wrangler.jsonc and .gitignore line are kept"
else
    bad "ARM 6: rc=$rc wrangler or .gitignore was rewritten"
fi

if [ "$failed" -eq 0 ]; then
    echo "ok:start-a-new-project-cloudflare:$pass"
else
    echo "refused:start-a-new-project-cloudflare:$failed of $((pass + failed)) arms"
    exit 1
fi
