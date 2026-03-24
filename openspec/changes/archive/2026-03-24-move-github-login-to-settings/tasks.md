## 1. Menu Restructure

- [x] 1.1 In `menu.rs`, convert the Settings `MenuItem` to a `SubmenuBuilder`
- [x] 1.2 Move the GitHub Login `MenuItem` inside the Settings submenu (preserve conditional logic)
- [x] 1.3 Add a disabled "All set" placeholder item when GitHub Login is not needed
- [x] 1.4 Remove the top-level GitHub Login item and its separator

## 2. Verification

- [x] 2.1 Build and run: verify Settings submenu appears with GitHub Login inside it
- [x] 2.2 Verify clicking GitHub Login from the submenu still triggers the auth flow
