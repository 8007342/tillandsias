{
  description = "Tillandsias container images";

  inputs = {
    # nixos-26.05 — the current security-supported stable line (606-um5s).
    # Was nixos-24.11, which went EOL. Branch chosen by ENUMERATING what exists
    # (`git ls-remote --heads .../nixpkgs 'refs/heads/nixos-2[5-6]*'` ->
    # 25.05, 25.11, 26.05) rather than by assuming a numbering scheme.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    # crane: build the Rust release binaries via the flake with the
    # edition-2024-capable rust-overlay toolchain. nixpkgs' own rust may lag
    # edition 2024, so buildRustPackage can't be relied on directly.
    #
    # THE BUMP IS A COUPLED PAIR, NOT TWO INDEPENDENT UPDATES. crane v0.20.3
    # was the latest targeting nixpkgs-24.11; v0.21+ needs >= nixpkgs-25.11
    # (crane-utils fails to build otherwise). So the nixpkgs move and the crane
    # move have to land together or neither builds — which is why this packet
    # sat at "bump two inputs" for months and is not a two-line change.
    crane.url = "github:ipetkov/crane/v0.24.0";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ rust-overlay.overlays.default ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" "rust-analyzer" ];
          targets = [ "x86_64-unknown-linux-musl" "aarch64-unknown-linux-musl" ];
        };

        # ---- Hermetic musl-static release binaries (crane + pkgsCross) -------
        # Replaces the musl.cc download / `cross` container (both failed in CI:
        # musl.cc network timeout; cross 0.2.5's ancient-glibc container choked
        # on tillandsias-headless's build.rs). nix compiles build scripts for
        # the BUILD host (native glibc) and the binary for the TARGET, and the
        # aarch64-musl C cross-compiler comes from nixpkgs pkgsCross — no
        # external download, modern toolchain. TLS is rustls/ring (no OpenSSL),
        # so cross only needs the C compiler for ring.
        # @trace spec:linux-native-portable-executable (musl-static requirement)
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        # NOT cleanCargoSource: tillandsias-headless's build.rs embeds runtime
        # assets from images/, observatorium/, and scripts/ (per
        # spec:linux-native-portable-executable "carries runtime image
        # contexts"). Keep the full tree but drop build outputs (target/,
        # out-cache/, dist/, result) for purity + size; cleanSource drops .git.
        craneSrc = pkgs.lib.cleanSourceWith {
          src = pkgs.lib.cleanSource ./.;
          filter = path: _type:
            !(builtins.elem (baseNameOf path) [ "target" "out-cache" "dist" "result" ]);
        };
        crossPkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
        aarch64Cc = "${crossPkgs.stdenv.cc}/bin/${crossPkgs.stdenv.cc.targetPrefix}cc";
        aarch64Ar = "${crossPkgs.stdenv.cc.bintools.bintools}/bin/${crossPkgs.stdenv.cc.targetPrefix}ar";

        # Secure-channel key: SHA-256 of the running binary (computed at
        # runtime, not compile time). No build-time env injection needed,
        # so nix builds are pure (no --impure). All binaries compiled from
        # identical source produce identical hashes and therefore derive
        # matching PSKs — "same binary talks to same binary".

        # ORDER 765-8hc3 — READ BEFORE "FIXING" THE DEPS CACHING HERE.
        #
        # It looks like passing the whole tree as `src` makes every
        # `buildDepsOnly` below churn on any file change, cold-compiling ~1,000
        # vendored crates per target on every commit. The 2026-08-15 velocity
        # audit (finding F7) inferred exactly that. MEASURED 2026-08-17, it is
        # FALSE: `buildDepsOnly` runs its `src` through crane's `mkDummySrc`,
        # which keeps the dependency-defining inputs and stubs the rest, so the
        # deps derivations are already stable. Observed on this flake:
        #
        #   source-only edit    -> top-level drv CHANGED, deps drv UNCHANGED
        #   Cargo.toml metadata -> deps drv UNCHANGED (crane normalizes it)
        #   Cargo.lock edit     -> deps drv CHANGED   (dependency graph moved)
        #
        # So do NOT add a hand-rolled `depsOnlySrc` filter here. It would buy
        # nothing, and an over-narrow filter silently drops a manifest — the
        # failure mode is a deps set that no longer matches the real graph.
        #
        # What DOES break the property: giving buildDepsOnly an explicit
        # `dummySrc`, an `extraDummyScript`, or a `preBuild` that reads real
        # sources. `scripts/check-nix-deps-stability.sh` perturbs the tree and
        # asserts the invariant directly (and refuses to pass if it cannot
        # observe the perturbation at all); it fails loud on precisely those
        # regressions.
        commonCraneArgs = {
          src = craneSrc;
          strictDeps = true;
          doCheck = false; # release builds don't run tests (./build.sh does)
        };

        # ORDER 723-sazx. The sidecar must be a BUILD-GRAPH INPUT, not a file
        # someone remembered to stage.
        #
        # crates/tillandsias-headless/build.rs:93 lists
        # images/router/tillandsias-router-sidecar among its REQUIRED runtime
        # assets and panics at :116 without it. Order 710-w9kc un-committed that
        # blob — correctly — and `.gitignore:79` now ignores it. But `nix build
        # .#...` resolves this flake against the GIT TREE, so an ignored,
        # untracked file is not copied into `craneSrc` at all.
        #
        # That makes the release workflow's staging step ineffective by
        # construction: release.yml builds the sidecar, `install`s it into the
        # working tree, and then runs three flake builds that cannot see it.
        # The staging fixed the `./build.sh` and `build-image.sh` paths, which
        # compile from the working tree, and could never have fixed the nix
        # path. Nothing measured it because the last release predates the blob's
        # removal, so the nix lane has not been exercised since.
        #
        # Making it a `preBuild` closes the class rather than the instance: the
        # sidecar derivation becomes a dependency edge, so it is impossible to
        # build these binaries without it, on any host, in any lane.
        stageRouterSidecar = ''
          install -Dm0755 \
            ${tillandsias-router-sidecar-x86_64-musl}/bin/tillandsias-router-sidecar \
            images/router/tillandsias-router-sidecar
        '';

        tillandsias-x86_64-musl =
          let
            cargoArtifacts = craneLib.buildDepsOnly (commonCraneArgs // {
              CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
              cargoExtraArgs = "--bin tillandsias --features tray";
            });
          in
          craneLib.buildPackage (commonCraneArgs // {
            inherit cargoArtifacts;
            pname = "tillandsias";
            version = "0.0.0";
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            cargoExtraArgs = "--bin tillandsias --features tray";
            preBuild = stageRouterSidecar;
          });

        tillandsias-headless-x86_64-musl =
          let
            cargoArtifacts = craneLib.buildDepsOnly (commonCraneArgs // {
              CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
              cargoExtraArgs = "-p tillandsias-headless --bin tillandsias --features listen-vsock";
            });
          in
          craneLib.buildPackage (commonCraneArgs // {
            inherit cargoArtifacts;
            pname = "tillandsias-headless-x86_64";
            version = "0.0.0";
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            cargoExtraArgs = "-p tillandsias-headless --bin tillandsias --features listen-vsock";
            preBuild = stageRouterSidecar;
          });

        tillandsias-headless-aarch64-musl =
          let
            cargoArtifacts = craneLib.buildDepsOnly (commonCraneArgs // {
              CARGO_BUILD_TARGET = "aarch64-unknown-linux-musl";
              cargoExtraArgs = "-p tillandsias-headless --bin tillandsias --features listen-vsock";
              # aarch64-musl cross toolchain (ring's build.rs + linker).
              depsBuildBuild = [ crossPkgs.stdenv.cc ];
              CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER = aarch64Cc;
              CC_aarch64_unknown_linux_musl = aarch64Cc;
              AR_aarch64_unknown_linux_musl = aarch64Ar;
              TARGET_CC = aarch64Cc;
              HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
            });
          in
          craneLib.buildPackage (commonCraneArgs // {
            inherit cargoArtifacts;
            pname = "tillandsias-headless-aarch64";
            version = "0.0.0";
            CARGO_BUILD_TARGET = "aarch64-unknown-linux-musl";
            cargoExtraArgs = "-p tillandsias-headless --bin tillandsias --features listen-vsock";
            preBuild = stageRouterSidecar;
            # aarch64-musl cross toolchain (ring's build.rs + linker).
            depsBuildBuild = [ crossPkgs.stdenv.cc ];
            CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER = aarch64Cc;
            CC_aarch64_unknown_linux_musl = aarch64Cc;
            AR_aarch64_unknown_linux_musl = aarch64Ar;
            TARGET_CC = aarch64Cc;
            HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
          });

        # Router sidecar (order 710-w9kc): the static-musl binary the router
        # image runs and the tray embeds. Built hermetically here so the release
        # publishes a VERSION-MATCHED, cosign-signed asset alongside the linux/
        # macos/windows binaries — never a committed blob. Mirrors build-sidecar.sh
        # (`-p tillandsias-router-sidecar --bin ... --features unix-only`).
        tillandsias-router-sidecar-x86_64-musl =
          let
            cargoArtifacts = craneLib.buildDepsOnly (commonCraneArgs // {
              CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
              cargoExtraArgs = "-p tillandsias-router-sidecar --bin tillandsias-router-sidecar --features unix-only";
            });
          in
          craneLib.buildPackage (commonCraneArgs // {
            inherit cargoArtifacts;
            pname = "tillandsias-router-sidecar-x86_64";
            version = "0.0.0";
            CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
            cargoExtraArgs = "-p tillandsias-router-sidecar --bin tillandsias-router-sidecar --features unix-only";
          });

        # Local files — changing these triggers rebuild
        forgeEntrypoint = ./images/default/entrypoint.sh;
        forgeLibCommon = ./images/default/lib-common.sh;
        forgeEntrypointOpencode = ./images/default/entrypoint-forge-opencode.sh;
        forgeEntrypointClaude = ./images/default/entrypoint-forge-claude.sh;
        forgeEntrypointCodex = ./images/default/entrypoint-forge-codex.sh;
        forgeEntrypointTerminal = ./images/default/entrypoint-terminal.sh;
        forgeOpencode = ./images/default/opencode.json;
        forgeShellConfigs = ./images/default/shell;
        forgeWelcome = ./images/default/forge-welcome.sh;
        forgeLocales = ./images/default/locales;
        forgeCliCommands = ./images/default/cli;
        forgeShellHelpers = ./images/default/config-overlay/shell-helpers.sh;
        webEntrypoint = ./images/web/entrypoint.sh;
        forgeImageRoot = pkgs.buildEnv {
          name = "tillandsias-forge-root";
          paths = with pkgs; [
            # Shell and core utils
            bash
            coreutils
            diffutils
            findutils
            gnugrep
            gnumake
            gnused
            gawk
            gnutar
            gzip
            less
            patch
            unzip
            which
            xz
            # Alternative shells
            fish
            zsh
            # Dev tools
            file
            git
            gh
            curl
            wget
            jq
            openssh
            ripgrep
            strace
            # Terminal tools
            mc
            vim
            nano
            eza
            bat
            fd
            fzf
            zoxide
            htop
            tree
            # System tools
            iproute2
            procps
            # Node.js + npm (for OpenSpec deferred install)
            # npm comes FROM nodejs_22, not from a separate attribute (606-um5s).
            # nixpkgs-26.05 removed `nodePackages` entirely ("nodePackages has
            # been removed. Many packages are now available at the top level"),
            # and there is no `pkgs.npm` to move to — enumerated: npm ABSENT,
            # nodejs/nodejs_22/nodejs_24 present.
            #
            # VERIFIED rather than assumed, because dropping a line here would
            # otherwise silently remove a tool and this packet's exit criteria
            # forbid that: nodejs-22.23.2's bin/ contains corepack, node, NPM,
            # npx. So npm survives the removal of the line that named it.
            nodejs_22
            # Nix itself (for build-time developer workflows inside the image)
            nix
            # TLS certificates and shell support
            cacert
            dockerTools.usrBinEnv
            dockerTools.binSh
          ];
          pathsToLink = [ "/bin" "/etc" "/lib" "/lib64" "/share" "/usr/bin" "/usr/local/bin" ];
        };
        webImageRoot = pkgs.buildEnv {
          name = "tillandsias-web-root";
          paths = with pkgs; [
            bash
            coreutils
            busybox
            dockerTools.usrBinEnv
            dockerTools.binSh
          ];
          pathsToLink = [ "/bin" "/lib" "/lib64" "/share" "/usr/bin" ];
        };

      in {
        packages = {
          # Hermetic musl-static release binaries (see let-bindings above).
          inherit tillandsias-x86_64-musl
                  tillandsias-headless-x86_64-musl
                  tillandsias-headless-aarch64-musl
                  tillandsias-router-sidecar-x86_64-musl;

          forge-image = pkgs.dockerTools.buildLayeredImage {
            name = "tillandsias-forge";
            tag = "latest";
            maxLayers = 100;

            # @trace spec:forge-shell-tools
            #
            # `contents`, NOT `copyToRoot` (606-um5s). These are two different
            # builders with two different parameter names, and nixpkgs-24.11
            # happened to accept the wrong one here:
            #   buildImage        -> copyToRoot   (`contents` deprecated)
            #   buildLayeredImage -> contents
            # nixpkgs-26.05 stopped accepting the alias and evaluation fails with
            # `function 'anonymous lambda' called with unexpected argument
            # 'copyToRoot'`. Confirmed by ENUMERATING streamLayeredImage's actual
            # formals in the locked nixpkgs rather than guessing the new name.
            contents = forgeImageRoot;

            fakeRootCommands = ''
              # FHS compatibility: pre-built binaries (OpenCode, etc.) expect
              # the dynamic linker at /lib64/ld-linux-x86-64.so.2
              mkdir -p ./lib64
              ln -sf ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 ./lib64/ld-linux-x86-64.so.2

              # Create user home and standard dirs
              mkdir -p ./home/forge/src
              mkdir -p ./home/forge/.cache/tillandsias/{nix,opencode}
              mkdir -p ./home/forge/.config/opencode
              mkdir -p ./home/forge/.config/nix
              mkdir -p ./tmp
              chmod 1777 ./tmp

              # Copy shared library
              mkdir -p ./usr/local/lib/tillandsias
              cp ${forgeLibCommon} ./usr/local/lib/tillandsias/lib-common.sh
              chmod +r ./usr/local/lib/tillandsias/lib-common.sh

              # Copy per-type entrypoints
              mkdir -p ./usr/local/bin
              cp ${forgeEntrypointOpencode} ./usr/local/bin/entrypoint-forge-opencode.sh
              cp ${forgeEntrypointClaude} ./usr/local/bin/entrypoint-forge-claude.sh
              cp ${forgeEntrypointCodex} ./usr/local/bin/entrypoint-forge-codex.sh
              cp ${forgeEntrypointTerminal} ./usr/local/bin/entrypoint-terminal.sh
              chmod +x ./usr/local/bin/entrypoint-forge-opencode.sh
              chmod +x ./usr/local/bin/entrypoint-forge-claude.sh
              chmod +x ./usr/local/bin/entrypoint-forge-codex.sh
              chmod +x ./usr/local/bin/entrypoint-terminal.sh
              # Copy legacy entrypoint (backward compat redirect)
              cp ${forgeEntrypoint} ./usr/local/bin/tillandsias-entrypoint.sh
              chmod +x ./usr/local/bin/tillandsias-entrypoint.sh

              # Copy opencode config
              cp ${forgeOpencode} ./home/forge/.config/opencode/config.json

              # Shell configs — entrypoint deploys these from /etc/skel/ to $HOME
              mkdir -p ./etc/skel/.config/fish
              cp ${forgeShellConfigs}/bashrc ./etc/skel/.bashrc
              cp ${forgeShellConfigs}/zshrc ./etc/skel/.zshrc
              cp ${forgeShellConfigs}/config.fish ./etc/skel/.config/fish/config.fish

              # Welcome script
              mkdir -p ./usr/local/share/tillandsias
              cp ${forgeWelcome} ./usr/local/share/tillandsias/forge-welcome.sh
              chmod +x ./usr/local/share/tillandsias/forge-welcome.sh

              # CLI commands (inventory, services, models, logs)
              # @trace spec:forge-environment-discoverability
              cp ${forgeCliCommands}/tillandsias-inventory ./usr/local/bin/tillandsias-inventory
              cp ${forgeCliCommands}/tillandsias-services ./usr/local/bin/tillandsias-services
              cp ${forgeCliCommands}/tillandsias-models ./usr/local/bin/tillandsias-models
              cp ${forgeCliCommands}/tillandsias-logs ./usr/local/bin/tillandsias-logs
              chmod +x ./usr/local/bin/tillandsias-inventory
              chmod +x ./usr/local/bin/tillandsias-services
              chmod +x ./usr/local/bin/tillandsias-models
              chmod +x ./usr/local/bin/tillandsias-logs

              # Shell helper functions
              # @trace spec:forge-shell-tools, spec:forge-environment-discoverability
              mkdir -p ./etc/tillandsias
              cp ${forgeShellHelpers} ./etc/tillandsias/shell-helpers.sh
              chmod +x ./etc/tillandsias/shell-helpers.sh

              # Locale files — sourced by lib-common.sh for i18n
              mkdir -p ./etc/tillandsias/locales
              cp ${forgeLocales}/en.sh ./etc/tillandsias/locales/en.sh
              cp ${forgeLocales}/es.sh ./etc/tillandsias/locales/es.sh
              chmod +r ./etc/tillandsias/locales/en.sh ./etc/tillandsias/locales/es.sh

              # Fish config in the user's config dir — fish reads from
              # $__fish_config_dir/conf.d/ which is ~/.config/fish/conf.d/
              # NOT /etc/fish/conf.d/ (which points to the Nix store).
              mkdir -p ./home/forge/.config/fish/conf.d
              cp ${forgeShellConfigs}/config.fish ./home/forge/.config/fish/conf.d/tillandsias.fish

              # Enable flakes inside container
              echo "experimental-features = nix-command flakes" > ./home/forge/.config/nix/nix.conf

              # Create passwd/group for user mapping
              mkdir -p ./etc
              echo "root:x:0:0:root:/root:/bin/bash" > ./etc/passwd
              echo "forge:x:1000:1000:forge:/home/forge:/bin/bash" >> ./etc/passwd
              echo "root:x:0:" > ./etc/group
              echo "forge:x:1000:" >> ./etc/group

              # Own everything to forge user
              chown -R 1000:1000 ./home/forge
              # Ensure all home dir files are at least user-readable and user-writable.
              # Nix store files are copied as 0444 (read-only); without this chmod,
              # shell configs and other copied files cannot be modified inside the
              # container, and tools like zoxide or npm that update dotfiles will fail.
              chmod -R u+rw ./home/forge
              # Skel files must be readable so entrypoint.sh can cp them to $HOME.
              chmod -R a+r ./etc/skel
            '';

            config = {
              User = "1000:1000";
              WorkingDir = "/home/forge/src";
              Entrypoint = [ "/usr/local/bin/entrypoint-forge-claude.sh" ];
              ExposedPorts = {
                "3000-3099/tcp" = {};
              };
              Env = [
                "HOME=/home/forge"
                "USER=forge"
                "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
                "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              ];
            };
          };

          web-image = pkgs.dockerTools.buildLayeredImage {
            name = "tillandsias-web";
            tag = "latest";
            maxLayers = 20;

            # `contents`, not `copyToRoot` — see the forge-image site above (606-um5s).
            contents = webImageRoot;

            fakeRootCommands = ''
              mkdir -p ./var/www
              mkdir -p ./tmp
              chmod 1777 ./tmp
              cp ${webEntrypoint} ./entrypoint.sh
              chmod +x ./entrypoint.sh
            '';

            config = {
              WorkingDir = "/var/www";
              Entrypoint = [ "/entrypoint.sh" ];
              ExposedPorts = {
                "8080/tcp" = {};
              };
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Shell and core utilities
            bash
            coreutils
            diffutils
            findutils
            gnugrep
            gnumake
            gnused
            gawk
            gnutar
            gzip
            less
            patch
            unzip
            which
            xz
            # General-purpose CLI tooling
            fish
            zsh
            file
            git
            gh
            curl
            wget
            jq
            openssh
            ripgrep
            strace
            mc
            vim
            nano
            eza
            bat
            fd
            fzf
            zoxide
            htop
            tree
            iproute2
            procps
            # Rust toolchain (Nix-managed, edition-2024-capable)
            rustToolchain
            # Native build helpers
            stdenv.cc
            pkg-config
            cmake
            ninja
            autoconf
            automake
            libtool
            clang
            lld
            llvm
            # Runtime/native libraries used by the project and its tooling
            openssl
            gtk3
            webkitgtk_4_1
            libappindicator-gtk3
            librsvg
            glib
            # Miscellaneous language/tooling support
            # npm comes FROM nodejs_22, not from a separate attribute (606-um5s).
            # nixpkgs-26.05 removed `nodePackages` entirely ("nodePackages has
            # been removed. Many packages are now available at the top level"),
            # and there is no `pkgs.npm` to move to — enumerated: npm ABSENT,
            # nodejs/nodejs_22/nodejs_24 present.
            #
            # VERIFIED rather than assumed, because dropping a line here would
            # otherwise silently remove a tool and this packet's exit criteria
            # forbid that: nodejs-22.23.2's bin/ contains corepack, node, NPM,
            # npx. So npm survives the removal of the line that named it.
            nodejs_22
            python3
            python3Packages.pip
            perl
            go
            jdk21
            nix
            cacert
          ];

          shellHook = ''
            export NIX_SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          '';
        };
      }
    );
}
