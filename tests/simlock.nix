# A gateway and a worker on one machine, as the module runs them: the
# declared tokens are what the gateway takes (the worker joins with its own,
# T3 Code's agent token reads back as an agent), and a dropped declaration
# stops working. No SDK, so the worker has no Android driver; joining
# doesn't need one, and emulators would need nested KVM.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "simlock";
  nodes.machine = {
    imports = [self.nixosModules.simlock];
    environment.etc = {
      "simlock-test/worker".text = "slk_test-worker\n";
      "simlock-test/agent".text = "slk_test-agent\n";
      "simlock-test/old".text = "slk_test-old\n";
    };
    environment.systemPackages = [pkgs.curl pkgs.jq];
    specialisation.withOld.configuration.services.simlock.gateway.tokens.old = {
      role = "agent";
      secretFile = "/etc/simlock-test/old";
    };
    services.simlock = {
      gateway = {
        enable = true;
        tokens = {
          box = {
            role = "worker";
            secretFile = "/etc/simlock-test/worker";
          };
          t3 = {
            role = "agent";
            secretFile = "/etc/simlock-test/agent";
          };
        };
      };
      worker = {
        enable = true;
        android.sdk = pkgs.emptyDirectory;
        gateway = {
          url = "ws://127.0.0.1:4700";
          tokenFile = "/etc/simlock-test/worker";
        };
      };
    };
  };

  testScript = ''
    import json

    def identity(secret):
        return machine.succeed(f"curl -fsS -H 'authorization: Bearer {secret}' http://127.0.0.1:4700/v1/identity")

    machine.wait_for_unit("simlock-gateway.service")
    machine.wait_for_unit("simlock-worker.service")

    with subtest("declared agent token is an agent"):
        print(identity("slk_test-agent"))
        assert json.loads(identity("slk_test-agent"))["role"] == "agent"
        machine.fail("curl -fsS -H 'authorization: Bearer slk_nope' http://127.0.0.1:4700/v1/identity")

    with subtest("worker joins with its declared token"):
        # The module's `simlock` wrapper, as an admin would run it.
        machine.wait_until_succeeds(
            "sudo -u simlock simlock --gateway worker list --json"
            " | tee /dev/stderr | jq -e '[.. | objects | select(.label? == \"machine\")] | length > 0'",
            timeout=120,
        )

    with subtest("config.json is rendered, token included"):
        machine.succeed("jq -e '.gateway.token == \"slk_test-worker\"' /var/lib/simlock/config.json")
        machine.succeed("jq -e '.capabilities.stream.enabled' /var/lib/simlock/gateway/config.json")

    with subtest("a token no longer declared stops working"):
        machine.succeed("/run/booted-system/specialisation/withOld/bin/switch-to-configuration test")
        machine.succeed("systemctl restart simlock-gateway.service")
        machine.wait_for_unit("simlock-gateway.service")
        identity("slk_test-old")
        machine.succeed("/run/booted-system/bin/switch-to-configuration test")
        machine.succeed("systemctl restart simlock-gateway.service")
        machine.wait_for_unit("simlock-gateway.service")
        machine.fail("curl -fsS -H 'authorization: Bearer slk_test-old' http://127.0.0.1:4700/v1/identity")
        identity("slk_test-agent")
  '';
}
