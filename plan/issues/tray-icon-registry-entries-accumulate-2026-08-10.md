# Tray-icon registry entries accumulate per path, and the canonical one goes stale (663-64xi)

- Date: 2026-08-10
- Reporter: **operator, at the terminal**, during the 646-qde5 verification
- Class: `enhancement/` — user-visible clutter, and a wrong version shown in Windows Settings
- Related: `621-2re2` (made the portable exe a primary landing-page download)

## Operator report

> "there's pollution in Windows Registry, there are multiple tillandsias app
> (different versions) in the Windows Taskbar Settings > Other System Tray Icons
> settings menu, there's two now"

Confirmed immediately. `HKCU\Control Panel\NotifyIconSettings` held two
Tillandsias entries:

```
tooltip='Tillandsias 0.4.260728.1'   path=...\Local\Programs\Tillandsias\tillandsias-tray.exe
tooltip='Tillandsias 0.4.260810.1'   path=...\Local\Temp\bare-exe-test\tillandsias-tray.exe
```

The second was created seconds earlier by the 646-qde5 verification run and has
been removed. The first is the real finding.

## Defect 1 — the portable flow has no cleanup path at all

Windows keys `NotifyIconSettings` **by executable path**, so every distinct
location the tray is ever run from earns a permanent entry.

`scripts/install-windows.ps1:457` already knows this and prunes correctly —
during last night's smoke it reported:

```
removed stale tray-icon entry: C:\Users\bullo\OneDrive\Desktop\tillandsias-tray.exe
removed stale tray-icon entry: C:\Users\bullo\claudia\tillandsias\target\release\tillandsias-tray.exe
```

But that prune runs **only inside the installer**. And `621-2re2` made
`tillandsias-tray.exe` a *primary landing-page download* — a portable binary
explicitly meant to be run directly, with no installer. So the flow the landing
page advertises is precisely the flow that never prunes.

A user who downloads the portable exe to `Downloads\`, runs it, later moves it to
`Tools\`, and runs it again now has two permanent entries, one pointing at a file
that no longer exists — and nothing in the product will ever remove either.

## Defect 2 — the canonical entry's tooltip is never refreshed on upgrade

This is what made the operator read the list as "different versions":

```
registry tooltip : Tillandsias 0.4.260728.1     (28 July)
actual binary    : tillandsias-tray 0.4.260810.1 (10 August)
```

Same path, same install. The entry was written when 0.4.260728.1 first
registered its icon and has never been updated across every upgrade since. The
installer's prune deliberately *keeps* the canonical entry — correctly — but
nothing rewrites its `InitialTooltip`, so Windows Settings has been showing a
two-week-old version number for the currently installed build.

Note the interaction: prune-on-install plus never-refresh means the ONE entry
guaranteed to survive is also the one guaranteed to go stale.

## Suggested resolution

- **Prune at tray startup, not only at install.** The tray knows its own path; on
  start it can drop any other `tillandsias-tray.exe` entry whose target no longer
  exists. That covers the portable flow, which the installer cannot.
- **Write the tooltip on every start**, so the entry tracks the running build
  instead of the first one ever registered.
- Deliberately NOT suggested: pruning entries whose target still exists but is a
  different path. A user may legitimately run a portable build and an installed
  build; deleting the other one's entry from under it would be the product
  removing state it does not own.

## Verification note

Found only because the operator was asked to look at the notification area for
`646-qde5` and looked at the Settings list too. No automated check would have
surfaced it — the tray works correctly, the icon appears, and nothing errors. It
is visible only as clutter in a Windows settings page, which is exactly the kind
of thing a headless loop cannot see.
