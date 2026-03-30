## 1. Embed locale files

- [x] 1.1 Add `include_str!` constants for `images/default/locales/en.sh` and `images/default/locales/es.sh` in `src-tauri/src/embedded.rs`

## 2. Extract locale files at runtime

- [x] 2.1 Create `images/default/locales/` directory in `write_image_sources()`
- [x] 2.2 Write `en.sh` and `es.sh` into the locales directory
- [x] 2.3 Update the doc comment directory tree to include `locales/{en.sh,es.sh}`

## 3. Verify

- [x] 3.1 Run `./build.sh --check` to confirm compilation succeeds on all targets
- [x] 3.2 Run `tillandsias init` to confirm the installed binary builds the forge image successfully
