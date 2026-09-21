# @trace order:1313-prin, spec:tillandsias-vault, spec:git-mirror-service
#
# The mirror's SECOND Vault identity: the per-mirror HOST-CERTIFICATE SIGNER.
#
# WHY A SECOND AGENT AND NOT A SECOND POLICY ON THE FIRST. One token must never
# carry both authorities. The relay identity (git-mirror-agent, sink
# /tmp/tillandsias-vault-token) reads secret/github/token and pushes upstream;
# this one may do exactly ssh-host-signer/sign/host-<mirror-id> and nothing
# else. Merging them would mean the token that reaches GitHub also mints host
# certificates, and the token that mints certificates can read the GitHub
# credential — neither needs the other's power. Attaching the per-mirror signer
# policy to the SHARED git-mirror-agent role would additionally grant one
# project's mirror the authority to sign another project's host certificates,
# which is what D12 withdrew (see provision_host_signer_approle).
#
# EVERY PATH HERE DIFFERS FROM vault-agent.hcl ON PURPOSE. Two agents run in
# the same container; a shared pid_file, role-id file, secret-id file or sink
# would have them overwrite each other's state, and the failure would look like
# an intermittent auth problem rather than a collision.
#
# vault-agent-bootstrap.sh needs NO change to drive this: it already takes
# VAULT_APPROLE_DOCUMENT, VAULT_AGENT_CONFIG, VAULT_ROLE_ID_FILE and
# VAULT_SECRET_ID_FILE from the environment.

exit_after_auth = false
pid_file = "/tmp/tillandsias-vault-signer-agent.pid"

vault {
  address = "https://vault:8200"
  ca_cert = "/etc/tillandsias/ca.crt"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path = "/tmp/tillandsias-vault-signer-role-id"
      secret_id_file_path = "/tmp/tillandsias-vault-signer-secret-id"

      # Same reasoning as the relay agent: re-authentication after max_ttl
      # needs the launch-scoped SecretID to still be readable.
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      # sshd-identity.sh is pointed HERE via TILLANDSIAS_VAULT_TOKEN_FILE.
      path = "/tmp/tillandsias-vault-signer-token"
      mode = 0400
    }
  }
}
