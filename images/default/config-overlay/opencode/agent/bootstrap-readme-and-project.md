---
description: "Empty-project welcome flow. Displays sample prompts and forge capabilities."
---

# /bootstrap-readme-and-project

@trace spec:project-bootstrap-readme @cheatsheet runtime/agent-startup-skills.md

**Purpose**: Welcome new users to an empty project container with sample prompts and capability summary.

## Flow

1. Detect project name (from PWD or ask user)
2. Load ASCII banner from curated cache
3. Load `cheatsheets/welcome/sample-prompts.md`
4. Display 3 sample prompts (first 3, or randomize with `shuf -n 3`)
5. Print forge capability summary (one paragraph)
6. End with open-ended "What would you like to build?" (no forced choice)

## Output (one screen)

```
╔═══════════════════════════════════════════════════════════╗
║           🌺 Welcome to [ProjectName]                      ║
╚═══════════════════════════════════════════════════════════╝

You're starting from scratch. Here are three ideas to get you going:

1. Build a Pong web app. "Build me a single-page web Pong game
   using Flutter web and the Flame engine..."

2. Inventory for my business. "Help me build an inventory app for
   my small business..."

3. Calculus tutor. "Design a single-page web app that helps me
   understand derivatives..."

This forge can build Flutter apps (web and desktop), Nix packages,
data pipelines with Rust, and more. You've got Ollama for local AI.

What would you like to build?
```

## Telemetry

- Event: `startup_routing`
- Field: `resolved_via` = `"empty"`
- Field: `spec` = `project-bootstrap-readme`
