{ pkgs, ... }:

{
  name = "1password-connect";

  nodes.server = {
    services._1password-connect = {
      enable = true;
      credentialsFile = pkgs.writeText "1password-credentials.json" (
        builtins.toJSON {
          version = 1;
          # Placeholder payload: structurally the same file, but not
          # connected to any real Connect server (which cannot be done in
          # CI without 1Password infrastructure).
          accessToken = "placeholder";
        }
      );
    };
  };

  testScript =
    # The 1Password Connect server needs a real 1password-credentials.json,
    # whose cryptographic validation against 1Password's infrastructure
    # cannot run offline in CI. This test therefore asserts structural
    # correctness: both services come up with the module's wiring intact,
    # connect-sync binds its ports and serves its health endpoint, and both
    # units reach their graceful "retry later" states rather than crashing.
    ''
      start_all()

      server.wait_for_unit("1password-connect-api.service")
      server.wait_for_unit("1password-connect-sync.service")

      # connect-sync binds its HTTP and bus ports before credential
      # validation; verify reachability of the endpoints.
      server.wait_for_open_port(8081)
      server.wait_for_open_port(11223)
      server.succeed("curl -fsS http://127.0.0.1:8081/health")

      # connect-api keeps running in its database wait loop once the shared
      # data directory is fully wired up.
      server.wait_until_succeeds(
        "journalctl -u 1password-connect-api.service | grep -q 'no database found'"
      )

      # connect-sync read the credentials file presented through
      # LoadCredential/OP_SESSION; the message below comes specifically from
      # handling a successfully located (but structurally insufficient)
      # credentials file.
      server.wait_until_succeeds(
        "journalctl -u 1password-connect-sync.service | grep -q 'credentials file is not version 2'"
      )

      # Structural wiring: LoadCredential, environment variables as intended.
      server.succeed(
        "systemctl cat 1password-connect-api.service | grep -q 'LoadCredential=1password-credentials.json:'"
      )
      server.succeed(
        "systemctl cat 1password-connect-api.service | grep -q 'OP_SESSION=/run/credentials/1password-connect-api.service/1password-credentials.json'"
      )
      server.succeed(
        "systemctl cat 1password-connect-api.service | grep -q 'OP_BUS_PORT=11223'"
      )
      server.succeed(
        "systemctl cat 1password-connect-api.service | grep -q 'OP_BUS_PEERS=127.0.0.1:11224'"
      )
      server.succeed(
        "systemctl cat 1password-connect-sync.service | grep -q 'OP_HTTP_PORT=8081'"
      )
      server.succeed(
        "systemctl cat 1password-connect-api.service | grep -q 'OP_HTTP_PORT=8080'"
      )

      # Shared data directory with correct ownership.
      server.wait_until_succeeds(
        "[ -d /var/lib/1password-connect/.op/data ] && stat -c %U:%G /var/lib/1password-connect | grep -q op-connect:op-connect"
      )

      # The bus listener binds on all interfaces but must never be reachable
      # externally: this module never opens the ports, and the firewall's
      # default closed policy has to be retained. Hitting the same listeners
      # over the QEMU default interface address (10.0.2.15) must fail rather
      # than succeed.
      server.fail("curl -fsS --max-time 1 http://10.0.2.15:11223/health")
      server.fail("curl -fsS --max-time 1 http://10.0.2.15:11224/health")
    '';
}
