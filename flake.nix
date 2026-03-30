{
  description = "Tillandsias container images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Local files — changing these triggers rebuild
        forgeEntrypoint = ./images/default/entrypoint.sh;
        forgeLibCommon = ./images/default/lib-common.sh;
        forgeEntrypointOpencode = ./images/default/entrypoint-forge-opencode.sh;
        forgeEntrypointClaude = ./images/default/entrypoint-forge-claude.sh;
        forgeEntrypointTerminal = ./images/default/entrypoint-terminal.sh;
        forgeOpencode = ./images/default/opencode.json;
        forgeShellConfigs = ./images/default/shell;
        forgeWelcome = ./images/default/forge-welcome.sh;
        forgeLocales = ./images/default/locales;
        webEntrypoint = ./images/web/entrypoint.sh;

      in {
        packages = {
          forge-image = pkgs.dockerTools.buildLayeredImage {
            name = "tillandsias-forge";
            tag = "latest";
            maxLayers = 100;

            contents = with pkgs; [
              # Shell and core utils
              bash
              coreutils
              findutils
              gnugrep
              gnused
              gawk
              gnutar
              gzip
              xz
              # Alternative shells
              fish
              zsh
              # Dev tools
              git
              gh
              curl
              wget
              jq
              ripgrep
              # Terminal tools
              mc            # midnight commander
              vim
              nano
              eza           # modern ls
              bat           # modern cat
              fd            # modern find
              fzf           # fuzzy finder
              zoxide        # smart cd
              htop          # process viewer
              tree          # directory tree
              # Node.js + npm (for OpenSpec deferred install)
              nodejs_22
              nodePackages.npm
              # OpenCode: installed at runtime via official installer (curl | bash)
              # The binary is cached in ~/.cache/tillandsias/opencode/
              # Nix itself (for nix develop inside container)
              nix
              # TLS certificates
              cacert
              # Make /usr/bin/env and /bin/sh work
              dockerTools.usrBinEnv
              dockerTools.binSh
            ];

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
              cp ${forgeEntrypointTerminal} ./usr/local/bin/entrypoint-terminal.sh
              chmod +x ./usr/local/bin/entrypoint-forge-opencode.sh
              chmod +x ./usr/local/bin/entrypoint-forge-claude.sh
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

            contents = with pkgs; [
              bash
              coreutils
              busybox
              dockerTools.usrBinEnv
              dockerTools.binSh
            ];

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
      }
    );
}
