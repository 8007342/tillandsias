# @trace spec:tillandsias-vault, spec:git-mirror-service
#
# Long-running git-mirror Vault authentication. The AppRole files are copied
# from one Podman secret to tmpfs by vault-agent-bootstrap; neither credential
# enters argv, environment variables, logs, or the client-token sink.

exit_after_auth = false
pid_file = "/tmp/tillandsias-vault-agent.pid"

vault {
  address = "https://vault:8200"
  ca_cert = "/etc/tillandsias/ca.crt"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/tmp/tillandsias-vault-role-id"
      secret_id_file_path = "/tmp/tillandsias-vault-secret-id"

      # Re-authentication after the client token reaches max_ttl needs the
      # same launch-scoped SecretID. The host destroys its accessor when the
      # Tillandsias session shuts down.
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/tmp/tillandsias-vault-token"
      mode = 0400
    }
  }
}
