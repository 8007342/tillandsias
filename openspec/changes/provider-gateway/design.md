## Context

See proposal.md. Each provider's spike (order 2081) answers whether the CLI
works in subscription sign-in mode with its API base URL pointed at a local
gateway that holds the real token. This design covers only providers whose
spike answered yes.

## Goals

The gateway is simple and transparent enough that a reader can check every
property below by reading its source in one sitting.

## Decisions

### D1. One binary, one process per host or per forge network

A single static binary with no plugins. A small configuration file names, per
enabled provider, the upstream URL, the Vault path and the listen address on the
forge network. Nothing is configurable at runtime.

### D2. Language: Rust or Go

Rust is preferred, because the workspace is Rust and its HTTP and TLS stack is
already vetted. Go is acceptable if a spike shows that a provider needs
behaviour the Rust stack lacks. No bash, python or jq.

### D3. Reachability

The gateway binds only on the forge network's address, or on a unix socket
mounted into exactly one forge. It never binds on 0.0.0.0, on host loopback or
on a published port. The network or socket a request arrives on is the only
identity. A forge on network A cannot reach the listener for network B.

### D4. Credential handling

- The forge holds a placeholder. The gateway drops whatever credential header
  arrives and sets the real one.
- The token is read from Vault on first use and cached in memory with a TTL. It
  is never written to disk.
- On expiry, or on a 401 from upstream, one refresh runs per provider at a time.
  Requests that arrive meanwhile wait for it. The refreshed token is written
  back to Vault.
- When Vault holds no token, the gateway returns a fixed error telling the user
  to sign in from the tray. It never starts a sign-in flow.

### D5. What it does not do

There is no admin, metrics or debug endpoint. Headers and bodies are not
logged. The log holds one line per request (time, provider, status, duration)
and one line per refresh (outcome). Responses are neither modified nor cached.

## Threat model

| Actor | Can | Cannot |
|---|---|---|
| Agent in a served forge | send requests through the gateway as the operator's subscription | read the token, the refresh token or the Vault path; reach another forge's listener |
| Agent in another forge | nothing on this listener | connect at all (network isolation) |
| Host process as the same user | what it could already do (audit decision D1) | nothing new: the gateway adds no file, port or API |
| Upstream provider | see the real token, as it does today | |

What remains: a served forge can still spend the subscription while it runs.
That is intended, and it ends when the forge stops. What is removed: the forge
can no longer copy the sign-in out and keep using it later.

## Risks

- A CLI may pin its upstream, validate the token locally, or refuse a non-HTTPS
  base URL. The spikes exist to find this out before any build work.
- Streaming (SSE) must pass through unbuffered.
