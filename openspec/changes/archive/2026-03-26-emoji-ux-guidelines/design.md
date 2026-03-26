## Decisions

### D1: Two emoji families, strictly separated

| Family | Purpose | Examples | Used by |
|--------|---------|----------|---------|
| Flowers | AI engines, dev environments | 🌸🌺🌻🌼🌷🌹... | Attach Here (OpenCode) |
| Tools | Maintenance, terminals, appliances | 🔧🪛🔩⚙️🪚🔨... | Maintenance terminals |

A container NEVER uses an emoji from the wrong family. This is a hard UX rule.

### D2: Tool emoji pool with rotation

Like flower() on TillandsiaGenus, add a tool() method or a separate ToolEmoji system:

```
Tool pool: 🔧 🪛 🔩 ⚙️ 🪚 🔨 🪜 🧲 🪣 🧰 🪝 🔗 📐 🪤 🧱 🪵
```

16 tools. Each Maintenance container allocated a unique tool emoji from the pool. Rotation is per-project (first terminal = 🔧, second = 🪛, etc.). Released when container stops.

### D3: Project label layout — name first, emojis as suffix

```
BEFORE:                           AFTER:
🌸⛏️ my-project                  my-project    🔧🌸
⛏️ tetris                        tetris        🔧
🌸 cool-app                      cool-app      🌸
plain-project                     plain-project
```

Emojis are RIGHT of the name. This makes the project column scannable (names align left). Emojis accumulate as containers launch.

### D4: Emoji ordering in suffix — tools then flowers

```
project-name    <tools...> <flowers...>
project-name    🔧🪛 🌸
```

Tools (maintenance/appliances) appear first, flowers (AI engines) appear last. Within each family, order is by launch time (oldest left, newest right).

### D5: ContainerInfo stores its display emoji

Add `display_emoji: String` to ContainerInfo. Set at container creation time:
- Forge: `genus.flower()`
- Maintenance: allocated from tool pool

This emoji is what shows in the menu AND in the window title. Single source of truth.

### D6: Window title uses display_emoji

```
Attach Here window:    🌸 my-project
Maintenance window:    🔧 my-project
```

The emoji in the title bar matches the emoji appended to the project name in the menu. User can visually link them.
