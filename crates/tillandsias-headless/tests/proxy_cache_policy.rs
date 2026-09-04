//! Static semantic checks for the Squid 6 selective HTTPS-cache policy.
//!
//! The forge test host does not carry Squid or Podman, so these tests parse the
//! shipped configuration directly. Runtime `squid -k parse` and MISS→HIT
//! evidence remain separate mutable-host gates.
//!
//! @trace spec:proxy-container, spec:transparent-https-caching, spec:security-privacy-isolation

use std::fs;
use std::path::Path;

fn repo_file(relative: &str) -> String {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    fs::read_to_string(repo_root.join(relative))
        .unwrap_or_else(|error| panic!("failed to read {relative}: {error}"))
}

fn active_lines(config: &str) -> Vec<&str> {
    config
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .collect()
}

#[test]
fn ssl_bump_is_step_scoped_to_one_exact_release_asset_host() {
    let config = repo_file("images/proxy/squid.conf");
    let active = active_lines(&config);

    let bump_rules: Vec<_> = active
        .iter()
        .copied()
        .filter(|line| line.starts_with("ssl_bump "))
        .collect();
    assert_eq!(
        bump_rules,
        [
            "ssl_bump peek ssl_bump_step1",
            "ssl_bump bump github_release_assets",
            "ssl_bump splice all",
        ],
        "peek must run only at step 1, followed by one narrow bump rule and a splice-all fallback"
    );
    assert!(
        active.contains(&"acl ssl_bump_step1 at_step SslBump1"),
        "the peek action must be guarded by Squid's SslBump1 at_step ACL"
    );

    let host_acl = active
        .iter()
        .copied()
        .find(|line| line.starts_with("acl github_release_assets "))
        .expect("GitHub release-asset ACL");
    let hosts: Vec<_> = host_acl.split_whitespace().skip(4).collect();
    assert_eq!(
        hosts,
        ["release-assets.githubusercontent.com"],
        "the bump allowlist must contain exactly GitHub's dedicated release-asset CDN host"
    );
    assert!(
        host_acl.contains("ssl::server_name --client-requested"),
        "the step-2 decision must use client SNI without reverse DNS"
    );

    for tls_sensitive_host in [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "registry.ollama.ai",
        "api.openai.com",
        "api.anthropic.com",
    ] {
        assert!(
            !hosts.contains(&tls_sensitive_host),
            "{tls_sensitive_host} must fall through to end-to-end splice"
        );
    }
}

#[test]
fn bumped_origin_tls_and_signed_url_logs_fail_closed() {
    let config = repo_file("images/proxy/squid.conf");
    let active = active_lines(&config).join("\n");

    assert!(
        active.contains("tls_outgoing_options cafile=/etc/ssl/certs/ca-certificates.crt"),
        "bumped origin TLS must use the Alpine system CA bundle"
    );
    for forbidden in [
        "DONT_VERIFY_PEER",
        "DONT_VERIFY_DOMAIN",
        "sslproxy_cert_error allow",
        "ssl_bump bump all",
        "ssl_bump peek all",
        "ssl_bump stare all",
    ] {
        assert!(
            !active.contains(forbidden),
            "unsafe or overbroad active Squid directive present: {forbidden}"
        );
    }
    assert!(
        active.lines().any(|line| line == "strip_query_terms on"),
        "signed release-asset query terms must stay out of access logs"
    );

    // ORDER 1022-px54. This asserted the literal `exec squid -N` and had been
    // red on the trunk since 7292b097b (767-es4w), which changed the launch to
    // `exec /usr/local/bin/squid-supervisor squid squid -N` so a mid-service
    // crash is counted and restarted instead of leaving the container
    // Exited(139) with nothing watching. The test's INTENT — the parser gate
    // runs before Squid serves — was never broken; only the string drifted.
    //
    // PARSE-BEFORE-SERVE HOLDS END-TO-END, which the packet left open and this
    // comment settles. The supervisor relaunches on crash with `"$@" &` and does
    // NOT re-run `squid -k parse`. That is correct rather than a gap: the parse
    // happens in the entrypoint BEFORE the supervisor is exec'd, so it precedes
    // every Squid launch in the container's life, restarts included, and the
    // config is immutable for that lifetime — a restart has nothing new to
    // validate. The property would only break if the config could change at
    // runtime, which would make a restart serve unvalidated syntax; if a reload
    // or a live config mount is ever added, this is the assertion to revisit.
    //
    // ASSERTING THE SUPERVISOR, NOT JUST `squid -N`. Matching the bare launch
    // string would also pass for a future `exec squid -N` that dropped the
    // supervisor entirely — silently undoing 767-es4w and restoring the
    // uncounted-crash state it was written to end. Pinning the supervised form
    // costs nothing and catches that.
    let entrypoint = repo_file("images/proxy/entrypoint.sh");
    let parse = entrypoint
        .find("squid -k parse")
        .expect("runtime Squid parser gate");
    let launch = entrypoint
        .find("exec /usr/local/bin/squid-supervisor")
        .expect("Squid must be launched under squid-supervisor (767-es4w)");
    assert!(
        parse < launch,
        "the runtime parser gate must run before Squid starts serving"
    );
    let launch_line = entrypoint[launch..]
        .lines()
        .next()
        .expect("supervisor launch line");
    assert!(
        launch_line.trim_end().ends_with("squid -N"),
        "the supervisor must still launch Squid in no-daemon mode; got {launch_line:?}"
    );
}

#[test]
fn cache_can_hold_the_observed_asset_without_overriding_origin_policy() {
    let config = repo_file("images/proxy/squid.conf");
    let active = active_lines(&config);

    let cache_dir = active
        .iter()
        .copied()
        .find(|line| line.starts_with("cache_dir "))
        .expect("cache_dir");
    let cache_tokens: Vec<_> = cache_dir.split_whitespace().collect();
    let cache_mib: u64 = cache_tokens[3].parse().expect("cache size in MiB");

    let max_object = active
        .iter()
        .copied()
        .find(|line| line.starts_with("maximum_object_size "))
        .expect("maximum_object_size");
    let max_object_mib: u64 = max_object
        .split_whitespace()
        .nth(1)
        .expect("maximum object size")
        .parse()
        .expect("maximum object size in MiB");

    assert!(
        max_object_mib >= 1536,
        "the ~1.44GiB observed release asset must fit under the per-object ceiling"
    );
    assert!(
        cache_mib >= max_object_mib * 2,
        "the disk cache must have bounded room for the large object plus normal traffic"
    );

    let refresh_rules: Vec<_> = active
        .iter()
        .copied()
        .filter(|line| line.starts_with("refresh_pattern "))
        .collect();
    assert_eq!(
        refresh_rules,
        [
            r"refresh_pattern -i ^https://release-assets\.githubusercontent\.com/ 0 20% 4320",
            r"refresh_pattern -i (/cgi-bin/|\?) 0 0% 0",
            "refresh_pattern . 0 20% 4320",
        ],
        "the exact-host rule must precede conservative defaults"
    );

    let active_config = active.join("\n");
    for forbidden in [
        "override-expire",
        "ignore-no-store",
        "ignore-private",
        "ignore-reload",
        "store_id_program",
        "url_rewrite_program",
    ] {
        assert!(
            !active_config.contains(forbidden),
            "cache policy must not override origin semantics or normalize signed URLs: {forbidden}"
        );
    }
}
