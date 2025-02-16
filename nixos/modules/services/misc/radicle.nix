{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.radicle;

  json = pkgs.formats.json { };

  env = rec {
    # rad fails if it cannot stat $HOME/.gitconfig
    HOME = "/var/lib/radicle";
    RAD_HOME = HOME;
  };

  # Convenient wrapper to run `rad` in the namespaces of `radicle-node.service`
  rad-system = pkgs.writeShellScriptBin "rad-system" ''
    set -o allexport
    ${toShellVars env}
    # Note that --env is not used to preserve host's envvars like $TERM
    exec ${getExe' pkgs.util-linux "nsenter"} -a \
      -t "$(${getExe' config.systemd.package "systemctl"} show -P MainPID radicle-node.service)" \
      -S "$(${getExe' config.systemd.package "systemctl"} show -P UID radicle-node.service)" \
      -G "$(${getExe' config.systemd.package "systemctl"} show -P GID radicle-node.service)" \
      ${getExe' cfg.package "rad"} "$@"
  '';

  commonServiceConfig = serviceName: {
    environment = env // {
      RUST_LOG = mkDefault "info";
    };
    path = [
      pkgs.gitMinimal
    ];
    documentation = [
      "https://docs.radicle.xyz/guides/seeder"
    ];
    after = [
      "network.target"
      "network-online.target"
    ];
    requires = [
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = mkMerge [
      {
        BindReadOnlyPaths = [
          "${cfg.configFile}:${env.RAD_HOME}/config.json"
          "${if types.path.check cfg.publicKey then cfg.publicKey else pkgs.writeText "radicle.pub" cfg.publicKey}:${env.RAD_HOME}/keys/radicle.pub"
        ];
        KillMode = "process";
        StateDirectory = [ "radicle" ];
        User = config.users.users.radicle.name;
        Group = config.users.groups.radicle.name;
        WorkingDirectory = env.HOME;
      }
      # The following options are only for optimizing:
      # systemd-analyze security ${serviceName}
      {
        BindReadOnlyPaths = [
          "-/etc/resolv.conf"
          "/etc/ssl/certs/ca-certificates.crt"
          "/run/systemd"
        ];
        AmbientCapabilities = "";
        CapabilityBoundingSet = "";
        DeviceAllow = ""; # ProtectClock= adds DeviceAllow=char-rtc r
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProcSubset = "pid";
        ProtectClock = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RuntimeDirectoryMode = "700";
        SocketBindDeny = [ "any" ];
        StateDirectoryMode = "0750";
        SystemCallFilter = [
          "@system-service"
          "~@aio"
          "~@chown"
          "~@keyring"
          "~@memlock"
          "~@privileged"
          "~@resources"
          "~@setuid"
          "~@timer"
        ];
        SystemCallArchitectures = "native";
        # This is for BindPaths= and BindReadOnlyPaths=
        # to allow traversal of directories they create inside RootDirectory=
        UMask = "0066";
      }
    ];
    confinement = {
      enable = true;
      mode = "full-apivfs";
      packages = [
        pkgs.gitMinimal
        cfg.package
        pkgs.iana-etc
        (getLib pkgs.nss)
        pkgs.tzdata
      ];
    };
  };
in
{
  options = {
    services.radicle = {
      enable = mkEnableOption "Radicle Seed Node";
      package = mkPackageOption pkgs "radicle-node" { };
      privateKeyFile = mkOption {
        type = types.path;
        description = ''
          Absolute file path to an SSH private key,
          usually generated by `rad auth`.

          If it contains a colon (`:`) the string before the colon
          is taken as the credential name
          and the string after as a path encrypted with `systemd-creds`.
        '';
      };
      publicKey = mkOption {
        type = with types; either path str;
        description = ''
          An SSH public key (as an absolute file path or directly as a string),
          usually generated by `rad auth`.
        '';
      };
      node = {
        listenAddress = mkOption {
          type = types.str;
          default = "[::]";
          example = "127.0.0.1";
          description = "The IP address on which `radicle-node` listens.";
        };
        listenPort = mkOption {
          type = types.port;
          default = 8776;
          description = "The port on which `radicle-node` listens.";
        };
        openFirewall = mkEnableOption "opening the firewall for `radicle-node`";
        extraArgs = mkOption {
          type = with types; listOf str;
          default = [ ];
          description = "Extra arguments for `radicle-node`";
        };
      };
      configFile = mkOption {
        type = types.package;
        internal = true;
        default = (json.generate "config.json" cfg.settings).overrideAttrs (previousAttrs: {
          preferLocalBuild = true;
          # None of the usual phases are run here because runCommandWith uses buildCommand,
          # so just append to buildCommand what would usually be a checkPhase.
          buildCommand = previousAttrs.buildCommand + optionalString cfg.checkConfig ''
            ln -s $out config.json
            install -D -m 644 /dev/stdin keys/radicle.pub <<<"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBgFMhajUng+Rjj/sCFXI9PzG8BQjru2n7JgUVF1Kbv5 snakeoil"
            export RAD_HOME=$PWD
            ${getExe' pkgs.buildPackages.radicle-node "rad"} config >/dev/null || {
              cat -n config.json
              echo "Invalid config.json according to rad."
              echo "Please double-check your services.radicle.settings (producing the config.json above),"
              echo "some settings may be missing or have the wrong type."
              exit 1
            } >&2
          '';
        });
      };
      checkConfig = mkEnableOption "checking the {file}`config.json` file resulting from {option}`services.radicle.settings`" // { default = true; };
      settings = mkOption {
        description = ''
          See https://app.radicle.xyz/nodes/seed.radicle.garden/rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5/tree/radicle/src/node/config.rs#L275
        '';
        default = { };
        example = literalExpression ''
          {
            web.pinned.repositories = [
              "rad:z3gqcJUoA1n9HaHKufZs5FCSGazv5" # heartwood
              "rad:z3trNYnLWS11cJWC6BbxDs5niGo82" # rips
            ];
          }
        '';
        type = types.submodule {
          freeformType = json.type;
        };
      };
      httpd = {
        enable = mkEnableOption "Radicle HTTP gateway to radicle-node";
        package = mkPackageOption pkgs "radicle-httpd" { };
        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "The IP address on which `radicle-httpd` listens.";
        };
        listenPort = mkOption {
          type = types.port;
          default = 8080;
          description = "The port on which `radicle-httpd` listens.";
        };
        nginx = mkOption {
          # Type of a single virtual host, or null.
          type = types.nullOr (types.submodule (
            recursiveUpdate (import ../web-servers/nginx/vhost-options.nix { inherit config lib; }) {
              options.serverName = {
                default = "radicle-${config.networking.hostName}.${config.networking.domain}";
                defaultText = "radicle-\${config.networking.hostName}.\${config.networking.domain}";
              };
            }
          ));
          default = null;
          example = literalExpression ''
            {
              serverAliases = [
                "seed.''${config.networking.domain}"
              ];
              enableACME = false;
              useACMEHost = config.networking.domain;
            }
          '';
          description = ''
            With this option, you can customize an nginx virtual host which already has sensible defaults for `radicle-httpd`.
            Set to `{}` if you do not need any customization to the virtual host.
            If enabled, then by default, the {option}`serverName` is
            `radicle-''${config.networking.hostName}.''${config.networking.domain}`,
            TLS is active, and certificates are acquired via ACME.
            If this is set to null (the default), no nginx virtual host will be configured.
          '';
        };
        extraArgs = mkOption {
          type = with types; listOf str;
          default = [ ];
          description = "Extra arguments for `radicle-httpd`";
        };
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      systemd.services.radicle-node = mkMerge [
        (commonServiceConfig "radicle-node")
        {
          description = "Radicle Node";
          documentation = [ "man:radicle-node(1)" ];
          serviceConfig = {
            ExecStart = "${getExe' cfg.package "radicle-node"} --force --listen ${cfg.node.listenAddress}:${toString cfg.node.listenPort} ${escapeShellArgs cfg.node.extraArgs}";
            Restart = mkDefault "on-failure";
            RestartSec = "30";
            SocketBindAllow = [ "tcp:${toString cfg.node.listenPort}" ];
            SystemCallFilter = mkAfter [
              # Needed by git upload-pack which calls alarm() and setitimer() when providing a rad clone
              "@timer"
            ];
          };
          confinement.packages = [
            cfg.package
          ];
        }
        # Give only access to the private key to radicle-node.
        {
          serviceConfig =
            let keyCred = builtins.split ":" "${cfg.privateKeyFile}"; in
            if length keyCred > 1
            then {
              LoadCredentialEncrypted = [ cfg.privateKeyFile ];
              # Note that neither %d nor ${CREDENTIALS_DIRECTORY} works in BindReadOnlyPaths=
              BindReadOnlyPaths = [ "/run/credentials/radicle-node.service/${head keyCred}:${env.RAD_HOME}/keys/radicle" ];
            }
            else {
              LoadCredential = [ "radicle:${cfg.privateKeyFile}" ];
              BindReadOnlyPaths = [ "/run/credentials/radicle-node.service/radicle:${env.RAD_HOME}/keys/radicle" ];
            };
        }
      ];

      environment.systemPackages = [
        rad-system
      ];

      networking.firewall = mkIf cfg.node.openFirewall {
        allowedTCPPorts = [ cfg.node.listenPort ];
      };

      users = {
        users.radicle = {
          description = "Radicle";
          group = "radicle";
          home = env.HOME;
          isSystemUser = true;
        };
        groups.radicle = {
        };
      };
    }

    (mkIf cfg.httpd.enable (mkMerge [
      {
        systemd.services.radicle-httpd = mkMerge [
          (commonServiceConfig "radicle-httpd")
          {
            description = "Radicle HTTP gateway to radicle-node";
            documentation = [ "man:radicle-httpd(1)" ];
            serviceConfig = {
              ExecStart = "${getExe' cfg.httpd.package "radicle-httpd"} --listen ${cfg.httpd.listenAddress}:${toString cfg.httpd.listenPort} ${escapeShellArgs cfg.httpd.extraArgs}";
              Restart = mkDefault "on-failure";
              RestartSec = "10";
              SocketBindAllow = [ "tcp:${toString cfg.httpd.listenPort}" ];
              SystemCallFilter = mkAfter [
                # Needed by git upload-pack which calls alarm() and setitimer() when providing a git clone
                "@timer"
              ];
            };
          confinement.packages = [
            cfg.httpd.package
          ];
          }
        ];
      }

      (mkIf (cfg.httpd.nginx != null) {
        services.nginx.virtualHosts.${cfg.httpd.nginx.serverName} = lib.mkMerge [
          cfg.httpd.nginx
          {
            forceSSL = mkDefault true;
            enableACME = mkDefault true;
            locations."/" = {
              proxyPass = "http://${cfg.httpd.listenAddress}:${toString cfg.httpd.listenPort}";
              recommendedProxySettings = true;
            };
          }
        ];

        services.radicle.settings = {
          node.alias = mkDefault cfg.httpd.nginx.serverName;
          node.externalAddresses = mkDefault [
            "${cfg.httpd.nginx.serverName}:${toString cfg.node.listenPort}"
          ];
        };
      })
    ]))
  ]);

  meta.maintainers = with lib.maintainers; [
    julm
    lorenzleutgeb
  ];
}
