# @trace spec:tillandsias-vault
# Full CRUD on the secret tree; the tray manages secret rotation on the
# user's behalf (--github-login and future credential acquisition flows).
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Order 1505-iysn: secret/data/cloudflare/token and secret/data/cloudflare/refresh
# are covered by secret/* above; this host-resident policy is the ONLY one that
# may read the refresh path. Deliberately NO narrower stanza here: Vault applies
# the most specific matching path, so a read-only cloudflare stanza would strip
# the create/update the rotation needs. No forge, mirror, inference or login
# policy may name anything under secret/data/cloudflare/ (asserted by
# cloudflare_token_rotation_policies_keep_forges_out).

# Order 1506-32k5: secret/data/fleet/msg/static (this host's fleet-messaging
# X25519 static key, minted by `tillandsias --msg-serve --mint`) is covered by
# secret/* above and by NO other policy: no forge, mirror, inference or login
# policy may name anything under secret/data/fleet/msg/ (asserted by
# msg_static_key_policies_keep_forges_out and scripts/test-fleet-msg-identity.sh).
