---
id: toml-config
title: TOML Configuration Format
category: formats/config
tags: [toml, config, serde, configuration, format]
upstream: https://toml.io/en/v1.0.0
version_pinned: "1.0.0"
last_verified: "2026-03-30"
authority: official
---

# TOML v1.0.0 Quick Reference

TOML (Tom's Obvious Minimal Language) is a minimal configuration file format.
Full spec: <https://toml.io/en/v1.0.0>

## Basic Types

```toml
# Strings
basic    = "tabs \t newlines \n unicode \u0041"
literal  = 'no \escapes \here'
multi_basic = """
  line one
  line two"""
multi_literal = '''
  no \escapes
  even across lines'''

# Numbers
integer  = 42
hex      = 0xDEADBEEF
octal    = 0o755
binary   = 0b11010110
float    = 3.14
sci      = 5e+22
inf_val  = inf          # also -inf, +inf
nan_val  = nan

# Boolean (lowercase only)
flag = true

# Datetime
odt   = 1979-05-27T07:32:00Z          # offset datetime
ldt   = 1979-05-27T07:32:00            # local datetime
ld    = 1979-05-27                      # local date
lt    = 07:32:00                        # local time
```

Underscores are allowed in numbers for readability: `1_000_000`.

## Keys

```toml
bare-key   = "letters, digits, dashes, underscores"
"quoted.key" = "allows any character"
'lit.key'    = "literal quoting works too"

# Dotted keys define nested tables inline
fruit.apple.color = "red"
# equivalent to:
# [fruit.apple]
# color = "red"
```

**Rule:** A key may be bare, basic-quoted, or literal-quoted. Bare keys may
contain `A-Za-z0-9`, `-`, and `_` only.

## Tables

```toml
[server]
host = "0.0.0.0"
port = 8080

[server.tls]              # nested table via dotted header
cert = "/path/to/cert"

[database]
enabled = true
```

Tables collect all key/value pairs beneath them until the next table header
or EOF.

## Inline Tables

```toml
point = { x = 1, y = 2 }
nested = { a.b = "dotted keys work" }
```

**Restrictions:** Inline tables must appear on a single line. No trailing
comma. Once defined inline, you cannot add keys to that table elsewhere
in the file.

## Arrays

```toml
ports = [8001, 8002, 8003]
mixed = ["string", 42, true]       # mixed types allowed in v1.0.0
nested = [[1, 2], [3, 4]]

# Multiline
hosts = [
  "alpha",
  "beta",       # trailing comma OK
]
```

## Arrays of Tables

```toml
[[products]]
name = "Hammer"
sku  = 738594937

[[products]]
name = "Nail"
sku  = 284758393

# Nested array of tables
[[fruits]]
  name = "apple"

  [[fruits.varieties]]
    name = "red delicious"

  [[fruits.varieties]]
    name = "granny smith"
```

Each `[[header]]` appends a new table to the array. Sub-tables and nested
arrays of tables belong to the most recently defined element.

## Multiline Strings

```toml
# Basic multiline: escapes processed, line-ending backslash trims whitespace
desc = """\
  The quick brown \
  fox jumps over \
  the lazy dog."""
# Result: "The quick brown fox jumps over the lazy dog."

# Literal multiline: no escape processing at all
regex = '''\\d{3}-\\d{4}'''
```

A newline immediately after the opening `"""` or `'''` is trimmed.

## Rust serde Integration

```toml
# Cargo.toml
[dependencies]
toml = "0.8"
serde = { version = "1", features = ["derive"] }
```

```rust
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
struct Config {
    host: String,
    port: u16,
    #[serde(default)]
    debug: bool,
    #[serde(rename = "log-level")]
    log_level: Option<String>,
}

// Deserialize
let config: Config = toml::from_str(toml_string)?;

// Serialize
let output: String = toml::to_string_pretty(&config)?;
```

Common serde attributes: `#[serde(default)]`, `#[serde(rename = "...")]`,
`#[serde(skip_serializing_if = "Option::is_none")]`,
`#[serde(deny_unknown_fields)]`.

### Enum Representations

```rust
#[derive(Deserialize)]
#[serde(tag = "type")]          // internally tagged
enum Backend {
    #[serde(rename = "postgres")]
    Postgres { url: String },
    #[serde(rename = "sqlite")]
    Sqlite { path: String },
}
```

```toml
[backend]
type = "postgres"
url  = "postgres://localhost/db"
```

## Common Config Patterns

```toml
# Defaults with override
[defaults]
timeout = 30
retries = 3

[profiles.production]
timeout = 60

# Feature flags
[features]
experimental = false
```

## Gotchas

1. **Table vs inline table:** A `[table]` can be extended across the file.
   An inline `{ ... }` is sealed -- no further keys can be added to it.

2. **Dotted keys create intermediate tables** that can conflict with later
   `[table]` headers if order is wrong.

3. **No null type.** Use `Option<T>` in Rust and omit the key entirely.

4. **Booleans are lowercase only.** `True`, `TRUE`, `yes`, `on` are all
   invalid.

5. **Integer range:** 64-bit signed (`i64`). No leading zeros except in
   `0x`, `0o`, `0b` prefixes.

6. **Trailing commas:** Allowed in arrays, forbidden in inline tables.

7. **Key redefinition is an error.** You cannot set the same key twice.

8. **Quoted keys are not dotted.** `"a.b"` is a single key named `a.b`,
   not a path into a nested table.

---

Sources:
- [TOML v1.0.0 Spec](https://toml.io/en/v1.0.0)
- [toml crate docs](https://docs.rs/toml)
- [Serde derive usage](https://serde.rs/derive.html)
