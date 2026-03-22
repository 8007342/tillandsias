## Context

The tray menu currently shows only discovered projects. If ~/src is empty or the user is starting fresh, there's nothing to click. The src/ directory itself should be a permanent attachment point.

## Goals / Non-Goals

**Goals:**
- ~/src/ always appears at the top of the menu with "Attach Here"
- Works even on a completely fresh system with no projects

**Non-Goals:**
- Multiple watch path roots as attachment points (future)

## Decisions

### D1: Permanent menu entry

Add `~/src/` as a permanent first entry in the menu, styled differently from project submenus (no submenu — just a direct "Attach Here" action). Label: `~/src/ — Attach Here`
