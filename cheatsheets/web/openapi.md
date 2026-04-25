# OpenAPI

@trace spec:agent-cheatsheets

> ⚠️ **DRAFT — provenance pending.** This cheatsheet was generated before the provenance-mandatory methodology landed. Treat its content as untrusted until the `## Provenance` section below is populated and verified against authoritative sources. See `cheatsheets/runtime/runtime-limitations.md` to report errors. (Tracked under change `cheatsheet-methodology-evolution`.)

**Version baseline**: OpenAPI 3.1 (aligned with JSON Schema 2020-12). OpenAPI 3.0 still common in legacy specs and many codegen tools — call out version in every spec.
**Use when**: defining HTTP APIs declaratively, generating clients/servers, producing browsable API docs, contract-testing across services.

## Quick reference

| Top-level key | Purpose |
|---|---|
| `openapi` | Spec version string (`3.1.0`, `3.0.3`) — required, first line |
| `info` | Title, version, description, contact, license |
| `servers` | Base URLs (with variables for env/region) |
| `paths` | Endpoints keyed by URL template (`/users/{id}`) |
| `components` | Reusable `schemas`, `parameters`, `responses`, `requestBodies`, `securitySchemes`, `headers`, `examples` |
| `security` | Default security requirements applied to all operations |
| `tags` | Logical grouping for docs UIs (Swagger, Redoc) |

| Schema keyword | Meaning |
|---|---|
| `$ref` | JSON Pointer to a reusable definition (`#/components/schemas/User`) |
| `oneOf` | Exactly one of N schemas matches (XOR) — use with `discriminator` |
| `anyOf` | At least one matches (OR) |
| `allOf` | All schemas match (AND / intersection — **not** inheritance) |
| `discriminator` | Property name + mapping that tells codegen which `oneOf` variant applies |
| `nullable` (3.0) / `type: [..., "null"]` (3.1) | Allow null — syntax differs between versions |

| Parameter `in` | Where it lives |
|---|---|
| `path` | URL template segment, always `required: true` |
| `query` | After `?`, repeatable with `style` + `explode` |
| `header` | HTTP header (case-insensitive, no `Accept`/`Content-Type`/`Authorization` here — use `requestBody`/`security`) |
| `cookie` | `Cookie` header value |

## Common patterns

### `$ref` for shared schemas
```yaml
components:
  schemas:
    User:
      type: object
      required: [id, email]
      properties:
        id:    { type: string, format: uuid }
        email: { type: string, format: email }
paths:
  /users/{id}:
    get:
      responses:
        "200":
          content:
            application/json:
              schema: { $ref: "#/components/schemas/User" }
```
Define every shape once under `components.schemas` and `$ref` it everywhere. Keeps codegen output DRY and diffs reviewable.

### Polymorphism with `discriminator`
```yaml
components:
  schemas:
    Event:
      oneOf:
        - $ref: "#/components/schemas/CreatedEvent"
        - $ref: "#/components/schemas/DeletedEvent"
      discriminator:
        propertyName: kind
        mapping:
          created: "#/components/schemas/CreatedEvent"
          deleted: "#/components/schemas/DeletedEvent"
```
Without a `discriminator`, generated clients fall back to "try each variant until one parses" — slow and ambiguous. The discriminator property must exist on every variant.

### Security schemes (bearer + OAuth2)
```yaml
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
    oauth2:
      type: oauth2
      flows:
        authorizationCode:
          authorizationUrl: https://auth.example.com/authorize
          tokenUrl:         https://auth.example.com/token
          scopes:
            read:users:  Read user profiles
            write:users: Modify users
security:
  - bearerAuth: []
```
Top-level `security` is the default; override per-operation with `security: []` (public) or a different requirement.

### Path with parameters and reusable response
```yaml
paths:
  /users/{id}:
    parameters:
      - name: id
        in:   path
        required: true
        schema: { type: string, format: uuid }
    get:
      operationId: getUser
      responses:
        "200": { $ref: "#/components/responses/User" }
        "404": { $ref: "#/components/responses/NotFound" }
components:
  responses:
    NotFound:
      description: Resource not found
      content:
        application/problem+json:
          schema: { $ref: "#/components/schemas/Problem" }
```
Hoist common error responses (`401`, `404`, `429`, `5xx`) into `components.responses`. Use RFC 7807 `application/problem+json` for machine-readable errors.

### Reusable error envelope
```yaml
components:
  schemas:
    Problem:
      type: object
      required: [type, title, status]
      properties:
        type:     { type: string, format: uri }
        title:    { type: string }
        status:   { type: integer, minimum: 100, maximum: 599 }
        detail:   { type: string }
        instance: { type: string, format: uri }
```
Single error shape across the API — clients write one error handler, not one per endpoint.

## Common pitfalls

- **3.0 vs 3.1 incompatibility** — 3.1 adopts JSON Schema 2020-12 (`type: ["string", "null"]`, `examples` array, `const`). 3.0 uses `nullable: true`, single `example`, no `const`. Many codegen tools (especially older `openapi-generator`, `swagger-codegen`) only support 3.0. Pin your `openapi` version and check tool compatibility before authoring.
- **`oneOf` without `discriminator`** — codegen produces an awkward "wrapper" type that requires runtime trial-parse. Always add a `discriminator` (and a `propertyName` field on every variant) for tagged unions.
- **`$ref` is JSON Pointer, not a file path** — `$ref: "./schemas/user.yaml"` is a Swagger-style external ref, supported only by some tools. Internal refs use `#/components/schemas/User`. If you split files, validate with a tool that resolves them (`redocly bundle`, `swagger-cli bundle`) before committing.
- **`allOf` is intersection, not inheritance** — `allOf: [Base, { properties: { x: ... } }]` means "value must match all schemas," not "subclass with extra field." Required fields, additionalProperties, and discriminators don't propagate the way OO inheritance would. Codegen tools paper over this differently — verify the generated types.
- **Missing `operationId` breaks codegen** — without `operationId`, generators synthesize names from method+path (`getUsersById`, `getUsersByIdPosts`) that change whenever you reorganize paths. Always set a stable, unique `operationId` per operation.
- **Path parameters not marked `required: true`** — spec says they must be required, but many editors don't enforce it. Validators will accept the spec; codegen will silently treat them as optional and produce broken clients.
- **Forgetting `additionalProperties: false`** — by default JSON Schema allows extra properties. If you want strict request validation (reject unknown fields), set `additionalProperties: false` on every request body schema. Beware: this also breaks `allOf` composition (extra fields from one branch get rejected).
- **Examples don't validate** — `example` / `examples` are not type-checked against the schema by most tools. Run `redocly lint` or `spectral lint` in CI to catch drift.
- **Servers with variables hide environment** — `servers: [{ url: "https://{env}.example.com" }]` reads cleanly but means clients must know which env to inject. For internal APIs prefer one entry per environment with explicit URLs.
- **Security on the wrong level** — top-level `security` applies to every operation including health checks and OAuth callbacks. Use per-operation `security: []` to mark public endpoints, or your auth middleware will reject probes.

## See also

- `web/http.md` — underlying HTTP semantics (status codes, methods, headers) that OpenAPI describes
- `languages/yaml.md` — OpenAPI specs are usually authored in YAML; mind the anchor/alias and indentation traps
- `languages/json.md` — alternative serialization for OpenAPI; required understanding for `$ref` JSON Pointer syntax
- `web/grpc.md` — schema-first alternative for service-to-service RPC where HTTP/JSON ergonomics aren't the priority
