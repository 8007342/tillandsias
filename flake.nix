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
        forgeOpencode = ./images/default/opencode.json;
        forgeSkills = ./images/default/skills;
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
              # Dev tools
              git
              gh
              curl
              wget
              jq
              ripgrep
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

              # Copy entrypoint
              cp ${forgeEntrypoint} ./home/forge/entrypoint.sh
              chmod +x ./home/forge/entrypoint.sh

              # Copy opencode config
              cp ${forgeOpencode} ./home/forge/.config/opencode/config.json

              # Copy skills — entrypoint deploys these to ~/src/.opencode/ at runtime
              mkdir -p ./usr/local/share/tillandsias/opencode
              cp -r ${forgeSkills}/* ./usr/local/share/tillandsias/opencode/

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
            '';

            config = {
              User = "1000:1000";
              WorkingDir = "/home/forge/src";
              Entrypoint = [ "/home/forge/entrypoint.sh" ];
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
