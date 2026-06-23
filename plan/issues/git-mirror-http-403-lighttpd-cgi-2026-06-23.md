# finding: git-mirror HTTP port 8080 returns 403 for all requests

- class: bug
- filed: 2026-06-23T20:10Z
- host: forge (Linux)
- branch: linux-next
- severity: medium (workaround: git daemon on port 9418 works correctly)

## Problem

The git-mirror service's HTTP endpoint (`http://tillandsias-git:8080`) returns
403 Forbidden for every request — static paths, git-http-backend CGI paths, and
root alike. The HTTP protocol handler (lighttpd + git-http-backend) is
non-functional.

The git daemon on port 9418 (`git://tillandsias-git/<project>`) works correctly.

## Impact

The forge's `rewrite_origin_for_enclave_push` and `clone_project_from_mirror`
functions in `images/default/lib-common.sh` referenced the HTTP URL with
`.git` suffix. This caused `git fetch`/`git push` to fail with 403 until the
insteadOf was changed to use `git://` protocol.

## Root cause investigation

lighttpd config (`images/git/lighttpd.conf`):
```
server.modules = (
    "mod_cgi",
    "mod_alias",
    "mod_setenv",
)
alias.url = (
    "/" => "/usr/libexec/git-core/git-http-backend/"
)
cgi.assign = ( "" => "" )
```

Possible causes:
1. `git-http-backend` with trailing slash in alias target may cause lighttpd to
   look for a file path instead of running CGI
2. `cgi.assign = ( "" => "" )` may not apply after mod_alias resolves the path
3. `mod_cgi` may need `cgi.execute-x-only` or similar

The same bare repos at `/srv/git/<project>` work fine via `git daemon` on
port 9418, so the repos themselves are valid.

## Fix

`images/default/lib-common.sh` updated to use `git://tillandsias-git/<project>`
instead of `http://tillandsias-git:8080/<project>.git`. This matches the spec
(`openspec/specs/git-mirror-service/spec.md` line 51).

The lighttpd config itself may need a separate fix to enable HTTP smart
protocol, but it's lower priority since `git://` protocol serves all needs.

## Smallest Next Action

Diagnose lighttpd CGI: verify `git-http-backend` exists at
`/usr/libexec/git-core/git-http-backend` inside the git container and that
`cgi.assign` rules match the resolved path after mod_alias.
