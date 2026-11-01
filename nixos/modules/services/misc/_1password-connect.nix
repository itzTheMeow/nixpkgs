# The 1Password Connect server is closed-source software distributed by
# 1Password only as Docker images on Docker Hub. The `_1password-connect`
# package extracts the native binaries (connect-api and connect-sync) from
# those images. This module runs them as two systemd services mirroring the
# upstream container pair, sharing one data directory like upstream's shared
# volume. All server configuration happens through environment variables
# (https://www.1password.dev/connect/server-configuration).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services._1password-connect;

  # Writes the two systemd service attrsets. Unlike upstream, each process
  # gets its own bus port: the containers share one data volume like
  # upstream, but they share a single host rather than per-container network
  # namespaces, and each process binds its own bus listener.
  mkConnectService =
    {
      unitName,
      binary,
      httpPort,
      ownBusPort,
      peerBusPort,
    }:
    {
      description = "1Password Connect ${binary}";
      # The management target allows grouped start/stop of both services.
      wantedBy = [ "1password-connect.target" ];
      partOf = [ "1password-connect.target" ];
      after = [ "network.target" ];

      # Module-owned wiring is applied after cfg.environment so accidentally
      # set variables in it cannot break the structural configuration.
      # Overrides for these variables are made through their dedicated
      # options instead.
      environment = cfg.environment // {
        XDG_DATA_HOME = "${cfg.dataDir}";
        OP_SESSION = "/run/credentials/${unitName}/1password-credentials.json";
        OP_HTTP_PORT = toString httpPort;
        OP_BUS_PORT = toString ownBusPort;
        # Static bus configuration: each process reaches its peer over
        # loopback. This replaces the automatic bus discovery of the
        # upstream containers, which relies on the NET_BROADCAST
        # capability that we (deliberately) do not grant.
        OP_BUS_PEERS = "127.0.0.1:${toString peerBusPort}";
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/${binary}";
        User = cfg.user;
        Group = cfg.group;
        LoadCredential = "1password-credentials.json:${cfg.credentialsFile}";
        StateDirectory = mkIf stateDirectoryUsed stateDirectoryName;
        Restart = "on-failure";
        RestartSec = "10s";
        UMask = "0077";

        # Hardening. The bus listeners bind on all interfaces so the bus
        # ports must be treated as unpublished (not firewalled); bus traffic
        # is only expected between the two local peers over loopback.
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        ReadWritePaths = [ "${cfg.dataDir}" ];
        CapabilityBoundingSet = [ ];
        SystemCallArchitectures = "native";
      }
      // lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = "${cfg.environmentFile}";
      };
    };

  # Only usable when dataDir is exactly one directory level below /var/lib;
  # any other layout falls back to plain directory management below.
  stateDirUnderVarLib = lib.removePrefix "/var/lib/" cfg.dataDir;
  stateDirectoryUsed =
    lib.hasPrefix "/var/lib/" cfg.dataDir
    && !lib.hasInfix "/" (lib.removeSuffix "/" stateDirUnderVarLib);
  stateDirectoryName = lib.removeSuffix "/" stateDirUnderVarLib;
in
{
  options = {
    services._1password-connect = {
      enable = mkEnableOption "the 1Password Connect server";

      package = mkPackageOption pkgs "1Password Connect" {
        default = [ "_1password-connect" ];
      };

      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a `1password-credentials.json` file, obtained when
          provisioning a Connect server in the 1Password account. Loaded via
          systemd `LoadCredential` and wired as `OP_SESSION`.

          Required when the server is enabled.
        '';
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/1password-connect";
        example = "/var/lib/1password-connect/state";
        description = ''
          Directory shared by both services, in which the service manages the
          encrypted copy of the vault data (`XDG_DATA_HOME` upstream). Both
          upstream containers mount the same data volume here, so this
          directory must not be per-service.
        '';
      };

      apiPort = mkOption {
        type = types.port;
        default = 8080;
        description = ''
          Port for the connect-api HTTP server (`OP_HTTP_PORT` upstream). The
          API address that 1Password clients point at via
          `OP_CONNECT_HOST=<host>:<port>`.

          Must be distinct from all other ports of this module, since both
          processes share a single host (unlike upstream's
          one-8080-per-container setup).
        '';
      };

      syncPort = mkOption {
        type = types.port;
        default = 8081;
        description = ''
          Port for the connect-sync HTTP meta server (`OP_HTTP_PORT`
          upstream). Must be distinct from all other ports of this module.
        '';
      };

      apiBusPort = mkOption {
        type = types.port;
        default = 11223;
        description = ''
          Port for connect-api's bus listener (`OP_BUS_PORT` upstream).
          Unlike the upstream containers, which may reuse one port value
          across their separate network namespaces, each process here binds
          its own bus listener and both must be distinct; connect-api exits
          early if its port is already taken.

          Also distinct from all other ports of this module. The bus listener
          binds on all network interfaces; keep it out of the firewall.
        '';
      };

      syncBusPort = mkOption {
        type = types.port;
        default = 11224;
        description = ''
          Port for connect-sync's bus listener (`OP_BUS_PORT` upstream).
          See `services._1password-connect.apiBusPort` for details.
        '';
      };

      user = mkOption {
        type = types.str;
        default = "op-connect";
        description = ''
          User account for both services. When left at the default, the
          module creates the account. When overridden, the referenced account
          (and group) must already exist and be permitted to write to
          `services._1password-connect.dataDir`.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "op-connect";
        description = ''
          Group account for both services. When left at the default, the
          module creates the group; see `services._1password-connect.user`.
        '';
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open `services._1password-connect.apiPort` in the firewall.
          Only ever specifies the HTTP API port; the sync port and
          the bus port are strictly local.
        '';
      };

      environment = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          Additional environment variables passed to both services, e.g.
          `OP_LOG_LEVEL = "debug"` or the `OP_TLS_*` variables for configuring
          TLS (https://www.1password.dev/connect/server-configuration).

          A few wiring variables (`OP_SESSION`, `OP_HTTP_PORT`, `OP_BUS_PORT`,
          `OP_BUS_PEERS`, `XDG_DATA_HOME`) are owned by this module and
          cannot be overridden here; use the corresponding module options
          instead.
          Secret material further overrides these values via
          [](#opt-services._1password-connect.environmentFile).
        '';
      };

      environmentFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Systemd `EnvironmentFile` loaded by both services, for secret
          material like an upstream base64-encoded credentials payload via
          `OP_SESSION=<base64>`.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.credentialsFile != null;
        message = ''
          A `1password-credentials.json` file is required when enabling
          `services._1password-connect`, via
          `services._1password-connect.credentialsFile`.
        '';
      }
      {
        assertion =
          cfg.apiPort != cfg.syncPort
          && cfg.syncPort != cfg.syncBusPort
          && cfg.syncPort != cfg.apiBusPort
          && cfg.apiPort != cfg.apiBusPort
          && cfg.apiPort != cfg.syncBusPort
          && cfg.apiBusPort != cfg.syncBusPort;
        message = ''
          `services._1password-connect` requires all ports in use (apiPort,
          syncPort, apiBusPort, syncBusPort) to be distinct, since both
          processes share a single host, each binding its own HTTP and bus
          listeners.
        '';
      }
      {
        assertion = cfg.user == "op-connect" || config.users.users ? ${cfg.user};
        message = ''
          `services._1password-connect.user` "''${cfg.user}" is set to a
          custom value; define that account
          (e.g. via `users.users."''${cfg.user}"`) while making sure it can
          write to `services._1password-connect.dataDir`.
        '';
      }
      {
        assertion = cfg.group == "op-connect" || config.users.groups ? ${cfg.group};
        message = ''
          `services._1password-connect.group` "''${cfg.group}" is set to a
          custom value; define that group (e.g. via
          `users.groups."''${cfg.group}"`).
        '';
      }
    ];

    users = {
      users = mkIf (cfg.user == "op-connect") {
        ${cfg.user} = {
          description = "1Password Connect service user";
          isSystemUser = true;
          group = cfg.group;
          home = "${cfg.dataDir}";
        };
      };
      groups = mkIf (cfg.group == "op-connect") {
        ${cfg.group} = { };
      };
    };

    # Creates dataDir (with the right ownership; StateDirectory already takes
    # care of the default /var/lib layout, this is the fallback for custom
    # dataDir values and for enforcing ownership) idempotently.
    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services = {
      "1password-connect-api" = mkConnectService {
        unitName = "1password-connect-api.service";
        binary = "connect-api";
        httpPort = cfg.apiPort;
        ownBusPort = cfg.apiBusPort;
        peerBusPort = cfg.syncBusPort;
      };

      "1password-connect-sync" = mkConnectService {
        unitName = "1password-connect-sync.service";
        binary = "connect-sync";
        httpPort = cfg.syncPort;
        ownBusPort = cfg.syncBusPort;
        peerBusPort = cfg.apiBusPort;
      };
    };

    systemd.targets."1password-connect" = {
      description = "1Password Connect server";
      wantedBy = [ "multi-user.target" ];
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.apiPort ];
    };
  };

  meta = {
    doc = ./_1password-connect.md;
    maintainers = with lib.maintainers; [ xelacodes ];
  };
}
