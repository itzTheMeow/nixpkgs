# 1Password Connect {#module-services-_1password-connect}

[1Password Connect](https://www.1password.dev/connect/) exposes your 1Password
vaults to your infrastructure through a private REST API.

The module runs the Connect server natively: both upstream containers
(`connect-api` and `connect-sync`) run side by side as systemd services,
sharing one data directory like upstream's shared data volume, and talking to
each other over a publicly unpublished bus port through loopback.

All server configuration happens through environment variables
([upstream documentation](https://www.1password.dev/connect/server-configuration));
[](#opt-services._1password-connect.environment) and
[](#opt-services._1password-connect.environmentFile) expose that surface
directly. The options below are the variables this module owns its wiring for.

## Getting started {#module-services-_1password-connect-getting-started}

Provision a Connect server in the 1Password admin UI (or via the `op` CLI) to
obtain a `1password-credentials.json` file. Then enable the service:

```nix
{
  services._1password-connect = {
    enable = true;
    credentialsFile = "/var/lib/secrets/1password-credentials.json";
    openFirewall = true;
  };
}
```

Both `connect-api` and `connect-sync` run under a dedicated `op-connect`
system user with state in `/var/lib/1password-connect`.

Point your clients at the API by setting
`OP_CONNECT_HOST` to the server host combined with
[](#opt-services._1password-connect.apiPort), plus an access token for one of
your vaults. For example, with the default port:

```text
OP_CONNECT_HOST=host.example.com:8080
```

## Service layout {#module-services-_1password-connect-layout}

| systemd unit | binary | HTTP port option | upstream env var |
|---|---|---|---|
| `1password-connect-api.service` | `connect-api` | [](#opt-services._1password-connect.apiPort) | `OP_HTTP_PORT` |
| `1password-connect-sync.service` | `connect-sync` | [](#opt-services._1password-connect.syncPort) | `OP_HTTP_PORT` |

Both units are grouped under `1password-connect.target` and managed as one:
stopping/restarting the target restarts both, which re-establishes their bus
connection.

Unlike upstream, where each container runs on its own network namespace with
its own `OP_HTTP_PORT` = 8080, both processes here share a single host, so the
two HTTP ports must be distinct values.

# Bus configuration {#module-services-_1password-connect-bus}

The two processes share updates over a bus connection, akin to the upstream
containers. The automatic discovery of the upstream containers relies on the
`NET_BROADCAST` capability, which native systemd services should not be
granted; this module wires the [static bus
configuration](https://www.1password.dev/connect/server-configuration#manual-bus-configuration)
instead: both services reach their peer over `127.0.0.1`, each on the bus
port of its peer
([](#opt-services._1password-connect.apiBusPort) and
[](#opt-services._1password-connect.syncBusPort)).

Unlike the upstream containers, which may share one `OP_BUS_PORT` value
because of their separate network namespaces, both processes bind their own
bus listener on one host — the two bus ports must be distinct. Both bus
listeners bind on all network interfaces and must never be reachable by other
hosts — do not put them in the firewall and keep it in mind when running the
host in an untrusted network.

## TLS {#module-services-_1password-connect-tls}

Connect itself supports [configuring
TLS](https://www.1password.dev/connect/server-configuration#tls) through
`OP_TLS_*` environment variables, settable through
[](#opt-services._1password-connect.environment) or
[](#opt-services._1password-connect.environmentFile). This module does not
own those variables.

More commonly, TLS termination is put in front of the API port by a reverse
proxy (e.g. nginx, caddy) on the same host.

## Secrets and credentials {#module-services-_1password-connect-secrets}

- [](#opt-services._1password-connect.credentialsFile) is loaded into both
  services read-only via systemd `LoadCredential` and handed over as the
  `OP_SESSION` env variable per upstream convention. The path is typically
  part of the secrets management, e.g. via
  [sops-nix](https://github.com/Mic92/sops-nix) or other such means.
- [](#opt-services._1password-connect.environmentFile), when set, is loaded
  with systemd `EnvironmentFile` for secret material such as an upstream-style
  base64-encoded credentials payload via
  `OP_SESSION=<base64 content of 1password-credentials.json>`.

## Hardening {#module-services-_1password-connect-hardening}

Both services run with substantial systemd hardening (no capabilities,
strict protection of filesystem/kernel interfaces, loopback-only address
families beyond UNIX sockets, no network namespaces). When upstream or other
package updates change required system interfaces, harden
[](#opt-services._1password-connect.user) customizations as needed or override
`systemd.services."1password-connect-api".serviceConfig` accordingly.
