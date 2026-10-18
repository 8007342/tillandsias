# Tasks — tray-icon-state-machine

## 1. Reducer (core)

- [x] 1.1 `tillandsias_core::tray_icon_state_machine`: Phase, Event, reduce,
      level; cargo tests written red first (monotonic blush, completion →
      pups, menu-open acknowledges pups only, failure never pups) [1778-gct2]

## 2. Icon sets

- [ ] 2.1 SVG sources: blush-1..4 and pups, as operator mock-ups [1778-gct2]
- [ ] 2.2 Operator approves each platform's set (event on 1778-gct2)
- [ ] 2.3 `build.rs` renders the per-platform set; a test pins every
      platform × phase × level and the macOS set's template flags [1778-gct2]

## 3. Wiring

- [ ] 3.1 Typed container-work progress (done/total) on `VmStatusReply`
      [1778-gct2]
- [ ] 3.2 Linux: events from the launch paths, MenuOpened from SNI and
      dbusmenu [1778-gct2]
- [ ] 3.3 macOS: NSMenuDelegate `menuWillOpen:`, non-template blush/pups
      images [1778-gct2]
- [ ] 3.4 Windows: MenuOpened from `show_context_menu` [1778-gct2]

## 4. Live

- [ ] 4.1 The next published release, on the operator's Mac: blush during a
      forge launch, pups after, plain after opening the menu
