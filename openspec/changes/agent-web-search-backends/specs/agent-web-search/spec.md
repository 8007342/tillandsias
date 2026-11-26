## ADDED Requirements

### Requirement: A forge agent reaches no web search or fetch directly

Every agent configuration shipped in a forge image SHALL disable the harness's
own web search tool and deny its own web fetch tool. Web access for agents
SHALL go only through the `enclave-fetch` service.

#### Scenario: OpenCode's built-in search is off

- **WHEN** the forge's OpenCode config is read
- **THEN** `websearch` is `false` and `webfetch` is denied, even though `permission` is `allow`

#### Scenario: A config that re-enables a web tool is refused

- **WHEN** a forge agent config enables a built-in web search or fetch tool
- **THEN** the forge-web-tools litmus test refuses the change, naming the file and the tool

### Requirement: The search backend holds its key outside every forge

The `enclave-fetch` search backend SHALL read its provider key from Vault, on
a path that only the `enclave-fetch` container's policy grants. A backend
SHALL refuse to start without a key, and SHALL never call a provider keyless.

#### Scenario: A forge token cannot read the search key

- **WHEN** a forge's Vault token asks for the search backend's key path
- **THEN** Vault refuses it

#### Scenario: No key, no backend

- **WHEN** enclave-fetch starts with no provider key in Vault
- **THEN** the search tool answers `could-not-run:search:no-key` and makes no network request

### Requirement: Only the backend's search endpoint is reachable

The proxy SHALL admit, from the `enclave-fetch` container only, the chosen
backend's search endpoint, and SHALL deny that provider's fetch, extract,
crawl and scrape endpoints.

#### Scenario: A vendor fetch path is denied

- **WHEN** enclave-fetch requests the backend provider's extract or scrape path
- **THEN** the proxy denies it, and the denial is logged with the path
