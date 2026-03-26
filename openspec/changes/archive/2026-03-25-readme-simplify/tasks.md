## 1. Rewrite Install Section in README.md

- [ ] 1.1 Remove the outer `<details open>` / `<details>` wrapper for Linux and the nested "Other ways to install" block (APT, COPR, Silverblue rpm-ostree, RPM/DEB table)
- [ ] 1.2 Remove the `<details>` wrapper for macOS and its nested "Other ways to install" block (DMG table + `.app.tar.gz` link)
- [ ] 1.3 Remove the `<details>` wrapper for Windows and its nested "Other ways to install" block (MSI link)
- [ ] 1.4 Write three flat platform sections: `**Linux**`, `**macOS**`, `**Windows**` — each containing only its one-shot install command block
- [ ] 1.5 Add a single collapsed `<details><summary>Direct downloads</summary>` block after the three platform sections with a four-row table (Linux AppImage, macOS Apple Silicon DMG, macOS Intel DMG, Windows setup.exe)

## 2. Verification

- [ ] 2.1 Confirm `## Run` and all sections after it are byte-for-byte unchanged
- [ ] 2.2 Confirm no broken HTML — every `<details>` has a matching `</details>`, every `<summary>` has a matching `</summary>`
- [ ] 2.3 Confirm the direct-downloads table renders (pipe-delimited markdown table inside the `<details>` block)
