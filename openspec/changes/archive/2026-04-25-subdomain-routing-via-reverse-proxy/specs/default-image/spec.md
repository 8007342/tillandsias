## ADDED Requirements

### Requirement: Agent instructions document subdomain routing convention

The forge image SHALL ship an opencode instruction file at
`/home/forge/.config-overlay/opencode/instructions/web-services.md`
that tells the agent the canonical URL form for any web server it
spawns inside the forge: `http://<project>.<service>.localhost/`,
port `80` always implicit. The instruction file SHALL also list the
service-port conventions (opencode=4096, flutter=8080, vite=5173,
next=3000, storybook=6006, jupyter=8888, streamlit=8501) and
explicitly forbid:

- Binding servers to `localhost` / `127.0.0.1` inside the container.
- Including a port number in the URL given to the human.
- Publishing container ports to the host (`-p`/`--publish`).

The agent SHALL be told to bind `0.0.0.0` on the conventional port
for each service.

#### Scenario: Agent prints a Tillandsias-shaped URL
- **WHEN** the user asks the agent to run a Flutter web app and the
  agent has the `web-services.md` instruction loaded
- **THEN** the agent SHALL launch with
  `flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080`
- **AND** the agent SHALL tell the user to open
  `http://<project>.flutter.localhost/`
- **AND** the agent SHALL NOT print `http://localhost:8080/`

#### Scenario: Agent self-tests through the proxy
- **WHEN** the agent wants to verify its server is up before reporting
  to the user
- **THEN** it SHALL `curl http://<project>.<service>.localhost/`
- **AND** the request SHALL succeed via the existing
  `HTTP_PROXY=http://proxy:3128` env var (no extra setup required by
  the agent)
