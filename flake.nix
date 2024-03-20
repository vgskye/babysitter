{
  inputs.nixpkgs.url = "nixpkgs";

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    version = builtins.substring 0 7 self.lastModifiedDate;

    systems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forAllSystems = nixpkgs.lib.genAttrs systems;
    nixpkgsFor = forAllSystems (system: import nixpkgs {inherit system;});

    packageFn = pkgs:
      pkgs.rustPlatform.buildRustPackage {
        pname = "babysitter";
        inherit version;

        src = builtins.path {
          name = "source";
          path = ./.;
        };

        cargoLock = {
          lockFile = ./Cargo.lock;
          outputHashes = {
            "rpackwiz-0.1.0" = "sha256-pOotNPIZS/BXiJWZVECXzP1lkb/o9J1tu6G2OqyEnI8=";
          };
        };
      };
  in rec {
    packages = forAllSystems (s: let
      pkgs = nixpkgsFor.${s};
    in rec {
      babysitter = packageFn pkgs;
      default = babysitter;
    });

    devShells = forAllSystems (s: let
      pkgs = nixpkgsFor.${s};
      inherit (pkgs) mkShell;
    in {
      default = mkShell {
        packages = with pkgs; [rustc cargo rustfmt];
      };
    });

    nixosModules = rec {
      packwiz-server = {
        config,
        lib,
        pkgs,
        ...
      }:
        with lib; let
          cfg = config.services.packwiz-server;

          # We don't allow eula=false anyways
          eulaFile = builtins.toFile "eula.txt" ''
            # eula.txt managed by NixOS Configuration
            eula=true
          '';

          whitelistFile =
            pkgs.writeText "whitelist.json"
            (builtins.toJSON
              (mapAttrsToList (n: v: {
                  name = n;
                  uuid = v;
                })
                cfg.whitelist));

          cfgToString = v:
            if builtins.isBool v
            then boolToString v
            else toString v;

          serverPropertiesFile = pkgs.writeText "server.properties" (''
              # server.properties managed by NixOS configuration
            ''
            + concatStringsSep "\n" (mapAttrsToList
              (n: v: "${n}=${cfgToString v}")
              cfg.serverProperties));

          stopScript = pkgs.writeShellScript "packwiz-server-stop" ''
            echo stop > ${config.systemd.sockets.packwiz-server.socketConfig.ListenFIFO}

            # Wait for the PID of the minecraft server to disappear before
            # returning, so systemd doesn't attempt to SIGKILL it.
            while kill -0 "$1" 2> /dev/null; do
              sleep 1s
            done
          '';

          # To be able to open the firewall, we need to read out port values in the
          # server properties, but fall back to the defaults when those don't exist.
          # These defaults are from https://minecraft.gamepedia.com/Server.properties#Java_Edition_3
          defaultServerPort = 25565;

          serverPort = cfg.serverProperties.server-port or defaultServerPort;

          rconPort =
            if cfg.serverProperties.enable-rcon or false
            then cfg.serverProperties."rcon.port" or 25575
            else null;

          queryPort =
            if cfg.serverProperties.enable-query or false
            then cfg.serverProperties."query.port" or 25565
            else null;
        in {
          options = {
            services.packwiz-server = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = lib.mdDoc ''
                  If enabled, start a Minecraft Server. The server
                  data will be loaded from and saved to
                  {option}`services.packwiz-server.dataDir`.
                '';
              };

              packUrl = mkOption {
                type = types.string;
                description = lib.mdDoc ''
                  The URL to the `pack.toml` of your packwiz pack.
                '';
              };

              declarative = mkOption {
                type = types.bool;
                default = false;
                description = lib.mdDoc ''
                  Whether to use a declarative Minecraft server configuration.
                  Only if set to `true`, the options
                  {option}`services.packwiz-server.whitelist` and
                  {option}`services.packwiz-server.serverProperties` will be
                  applied.
                '';
              };

              eula = mkOption {
                type = types.bool;
                default = false;
                description = lib.mdDoc ''
                  Whether you agree to
                  [
                  Mojangs EULA](https://account.mojang.com/documents/minecraft_eula). This option must be set to
                  `true` to run Minecraft server.
                '';
              };

              dataDir = mkOption {
                type = types.path;
                default = "/var/lib/minecraft";
                description = lib.mdDoc ''
                  Directory to store Minecraft database and other state/data files.
                '';
              };

              openFirewall = mkOption {
                type = types.bool;
                default = false;
                description = lib.mdDoc ''
                  Whether to open ports in the firewall for the server.
                '';
              };

              whitelist = mkOption {
                type = let
                  minecraftUUID =
                    types.strMatching
                    "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                    // {
                      description = "Minecraft UUID";
                    };
                in
                  types.attrsOf minecraftUUID;
                default = {};
                description = lib.mdDoc ''
                  Whitelisted players, only has an effect when
                  {option}`services.packwiz-server.declarative` is
                  `true` and the whitelist is enabled
                  via {option}`services.packwiz-server.serverProperties` by
                  setting `white-list` to `true`.
                  This is a mapping from Minecraft usernames to UUIDs.
                  You can use <https://mcuuid.net/> to get a
                  Minecraft UUID for a username.
                '';
                example = literalExpression ''
                  {
                    username1 = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
                    username2 = "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy";
                  };
                '';
              };

              serverProperties = mkOption {
                type = with types; attrsOf (oneOf [bool int str]);
                default = {};
                example = literalExpression ''
                  {
                    server-port = 43000;
                    difficulty = "hard";
                    gamemode = "creative";
                    max-players = 5;
                    motd = "NixOS Minecraft server!";
                    white-list = true;
                    enable-rcon = true;
                    "rcon.password" = "hunter2";
                  }
                '';
                description = lib.mdDoc ''
                  Minecraft server properties for the server.properties file. Only has
                  an effect when {option}`services.packwiz-server.declarative`
                  is set to `true`. See
                  <https://minecraft.wiki/w/Server.properties#Keys>
                  for documentation on these values.
                '';
              };

              package = mkOption {
                type = types.package;
                default = packages.${pkgs.system}.babysitter;
                defaultText = literalExpression "packages.${pkgs.system}.babysitter";
                description = lib.mdDoc "The version for babysitter, the startup/update manager.";
              };

              javaPackage = mkOption {
                type = types.package;
                default = pkgs.jdk17;
                defaultText = literalExpression "pkgs.jdk17";
                example = literalExpression "pkgs.jdk8";
                description = lib.mdDoc "The Java package to use";
              };

              jvmOpts = mkOption {
                type = types.separatedString " ";
                default = "-Xmx2048M -Xms2048M";
                example = "-Xms4096M -Xmx4096M -XX:+UseZGC";
                description = lib.mdDoc "JVM options for the Minecraft server.";
              };
            };
          };

          config = mkIf cfg.enable {
            users.users.minecraft = {
              description = "Minecraft server service user";
              home = cfg.dataDir;
              createHome = true;
              isSystemUser = true;
              group = "minecraft";
            };
            users.groups.minecraft = {};

            systemd.sockets.packwiz-server = {
              bindsTo = ["packwiz-server.service"];
              socketConfig = {
                ListenFIFO = "/run/packwiz-server.stdin";
                SocketMode = "0660";
                SocketUser = "minecraft";
                SocketGroup = "minecraft";
                RemoveOnStop = true;
                FlushPending = true;
              };
            };

            systemd.services.packwiz-server = {
              description = "Minecraft Server Service";
              wantedBy = ["multi-user.target"];
              requires = ["packwiz-server.socket"];
              after = ["network.target" "packwiz-server.socket"];

              serviceConfig = {
                ExecStart = "${cfg.package}/bin/babysitter";
                ExecStop = "${stopScript} $MAINPID";
                Restart = "always";
                User = "minecraft";
                WorkingDirectory = cfg.dataDir;

                StandardInput = "socket";
                StandardOutput = "journal";
                StandardError = "journal";

                # Hardening
                CapabilityBoundingSet = [""];
                DeviceAllow = [""];
                LockPersonality = true;
                PrivateDevices = true;
                PrivateTmp = true;
                PrivateUsers = true;
                ProtectClock = true;
                ProtectControlGroups = true;
                ProtectHome = true;
                ProtectHostname = true;
                ProtectKernelLogs = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                ProtectProc = "invisible";
                RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
                RestrictNamespaces = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                SystemCallArchitectures = "native";
                UMask = "0077";
              };

              environment = {
                BABYSITTER_PACKWIZ_URL = cfg.packUrl;
                BABYSITTER_JAVA_PATH = "${cfg.javaPackage}/bin/java";
                BABYSITTER_JVM_FLAGS = cfg.jvmOpts;
              };

              preStart =
                ''
                  ln -sf ${eulaFile} eula.txt
                ''
                + (
                  if cfg.declarative
                  then ''

                    if [ -e .declarative ]; then

                      # Was declarative before, no need to back up anything
                      ln -sf ${whitelistFile} whitelist.json
                      cp -f ${serverPropertiesFile} server.properties

                    else

                      # Declarative for the first time, backup stateful files
                      ln -sb --suffix=.stateful ${whitelistFile} whitelist.json
                      cp -b --suffix=.stateful ${serverPropertiesFile} server.properties

                      # server.properties must have write permissions, because every time
                      # the server starts it first parses the file and then regenerates it..
                      chmod +w server.properties
                      echo "Autogenerated file that signifies that this server configuration is managed declaratively by NixOS" \
                        > .declarative

                    fi
                  ''
                  else ''
                    if [ -e .declarative ]; then
                      rm .declarative
                    fi
                  ''
                );
            };

            networking.firewall = mkIf cfg.openFirewall (
              if cfg.declarative
              then {
                allowedUDPPorts = [serverPort];
                allowedTCPPorts =
                  [serverPort]
                  ++ optional (queryPort != null) queryPort
                  ++ optional (rconPort != null) rconPort;
              }
              else {
                allowedUDPPorts = [defaultServerPort];
                allowedTCPPorts = [defaultServerPort];
              }
            );

            assertions = [
              {
                assertion = cfg.eula;
                message =
                  "You must agree to Mojangs EULA to run packwiz-server."
                  + " Read https://account.mojang.com/documents/minecraft_eula and"
                  + " set `services.packwiz-server.eula` to `true` if you agree.";
              }
            ];
          };
        };
      default = packwiz-server;
    };
  };
}
