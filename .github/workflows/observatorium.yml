name: Observatorium

on:
  push:
    branches: [main]
  release:
    types: [published]
  # Releases created with GITHUB_TOKEN do not emit downstream release runs.
  workflow_run:
    workflows: [Release]
    types: [completed]
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: observatorium-production
  cancel-in-progress: false

jobs:
  deploy:
    if: >-
      github.event_name != 'workflow_run' ||
      (github.event.workflow_run.conclusion == 'success' &&
       github.event.workflow_run.head_repository.full_name == github.repository)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: observatorium
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: ${{ github.event.workflow_run.head_sha || github.event.release.tag_name || github.sha }}
      - name: Verify production source ancestry
        working-directory: .
        env:
          OBSERVATORIUM_EVENT: ${{ github.event_name }}
        run: |
          git fetch origin main --tags
          git merge-base --is-ancestor HEAD origin/main
          if [ "$OBSERVATORIUM_EVENT" = workflow_run ]; then
            test -n "$(git tag --points-at HEAD --list 'v[0-9]*')"
          fi
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
          cache-dependency-path: observatorium/package-lock.json
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: '3.47.7'
          cache: true
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - name: Build canonical plan fold
        working-directory: .
        run: |
          cargo build --locked --release -p tillandsias-plan
          echo "$GITHUB_WORKSPACE/target/release" >> "$GITHUB_PATH"
      - name: Restore durable observations
        run: node scripts/history.mjs restore
      - run: npm ci
      - run: npm test
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
      - name: Build and deploy CDN artifact
        run: npx wrangler deploy
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
      - name: Persist observations after successful deployment
        run: node scripts/history.mjs save
      - uses: actions/upload-artifact@v4
        with:
          name: observatorium-${{ github.sha }}
          path: |
            observatorium/build/web
            observatorium/.cache
          include-hidden-files: true
          retention-days: 90
