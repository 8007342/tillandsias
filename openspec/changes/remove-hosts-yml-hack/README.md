# remove-hosts-yml-hack

Remove hosts.yml plain-text token storage entirely. It is a security leak and ugly hack. All secret transport must use OS native keyring + tmpfs token files only. Remove 10+ call sites across secrets.rs, handlers.rs, runner.rs, github.rs, menu.rs, gh-auth-login.sh. Explicit errors on keyring unavailability instead of silent fallback.
