-- @env PATH HOME
-- @trace spec:browser-isolation
--
-- litmus-helper-browser-isolation.lua — PORTED from
-- litmus-helper-browser-isolation.sh (2111-y8ch, lenovinha shell slice).
-- Starts a mock opencode HTTP responder on :4096 inside the e2e test forge.
--
-- Grammar (stdout), unchanged for the litmus step:
--   MOCK_STARTED                        exit 0
--   Usage: ...                          exit 2
--
-- Usage: tillandsias-plan script run scripts/lua/litmus-helper-browser-isolation.lua -- start-mock-opencode

local MOCK = [[
cat > /tmp/opencode-mock.sh << "EOF"
#!/bin/sh
while true; do
  {
    printf "HTTP/1.1 200 OK\r\n"
    printf "Content-Type: application/json\r\n"
    printf "Connection: close\r\n\r\n"
    printf "{\"status\":\"opencode-ready\",\"path\":\"/\"}\n"
  } | nc -l -p 4096
done
EOF
chmod +x /tmp/opencode-mock.sh
/tmp/opencode-mock.sh >/tmp/opencode-mock.log 2>&1 &
sleep 1 && echo MOCK_STARTED]]

if arg[1] ~= "start-mock-opencode" then
    out.line("Usage: litmus-helper-browser-isolation.lua -- {start-mock-opencode}")
    verdict.emit("could-not-run:browser-isolation:usage", 2)
end

local r = proc.run{
    argv = { "podman", "exec", "tillandsias-test-forge-e2e", "sh", "-c", MOCK },
    env = { PATH = env.get("PATH") or "", HOME = env.get("HOME") or "" },
}
-- As before: stderr is discarded, the last stdout line is the answer.
local ls = text.lines(r.stdout or "")
if #ls > 0 then out.line(ls[#ls]) end
if r.status == "exited" and r.code == 0 then
    verdict.emit("ok:browser-isolation:mock-started", 0)
end
verdict.emit("violation:browser-isolation:mock-not-started", 1)
