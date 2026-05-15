//! Integration tests for Squid cache_peer routing to enclave router.
//!
//! @trace spec:subdomain-routing-via-reverse-proxy, gap:BR-003
//! @cheatsheet runtime/squid-cache-peer-routing.md, runtime/caddy-reverse-proxy.md
//!
//! These tests validate that Squid's cache_peer directive correctly forwards
//! .localhost requests to the Caddy router container on the enclave network.
//!
//! Test scenarios:
//! 1. cache_peer configuration parsing — verify Squid syntax is valid
//! 2. ACL matching for .localhost subdomains — ensure .localhost traffic is captured
//! 3. Never-direct rule enforcement — guarantee .localhost never goes to public DNS
//! 4. Enclave network peer addressing — confirm router is reachable at `router:8080`
//! 5. CONNECT method support — verify HTTPS tunneling for .localhost domains

use std::fs;
use std::path::Path;

// ============================================================================
// Test 1: Squid Configuration Syntax Validation
// ============================================================================

#[test]
fn test_cache_peer_directive_syntax() {
    // @trace gap:BR-003
    // Verify that the cache_peer directive in squid.conf follows correct syntax:
    //   cache_peer <hostname> <peer_type> <port> <icp_port> [options]
    //
    // Expected configuration for router peer:
    //   cache_peer router parent 8080 0 no-query default name=tillandsias-router connect-timeout=1

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // Verify cache_peer directive exists and references the router
    assert!(
        squid_conf.contains("cache_peer router parent 8080 0 no-query default name=tillandsias-router"),
        "cache_peer directive should reference 'router' hostname, not localhost"
    );

    // Verify it has proper connection timeout
    assert!(
        squid_conf.contains("connect-timeout=1"),
        "cache_peer should have 1-second connection timeout for graceful degradation"
    );

    // Verify the directive appears after ACL definitions
    let cache_peer_idx = squid_conf.find("cache_peer router").expect("cache_peer not found");
    let acl_idx = squid_conf.find("acl localhost_subdomain").expect("ACL not found");
    assert!(
        cache_peer_idx > acl_idx,
        "cache_peer should come after ACL definitions"
    );
}

// ============================================================================
// Test 2: .localhost Subdomain ACL Matching
// ============================================================================

#[test]
fn test_localhost_subdomain_acl_definition() {
    // @trace gap:BR-003
    // Verify that the `.localhost` ACL is properly defined to match all
    // RFC 6761 loopback subdomains.
    //
    // ACL should match:
    //   - service.localhost
    //   - project.service.localhost
    //   - deeply.nested.service.localhost
    //
    // Pattern: dstdomain .localhost

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // Verify ACL definition
    assert!(
        squid_conf.contains("acl localhost_subdomain dstdomain .localhost"),
        "ACL must match *.localhost subdomains"
    );

    // Verify it uses dstdomain (not src, not method)
    let acl_line = squid_conf
        .lines()
        .find(|line| line.contains("acl localhost_subdomain dstdomain"))
        .expect("localhost_subdomain ACL not found");

    assert!(
        acl_line.contains("dstdomain .localhost"),
        "ACL must use 'dstdomain' to match destination domain"
    );
}

// ============================================================================
// Test 3: Cache Peer Access Control Rules
// ============================================================================

#[test]
fn test_cache_peer_access_rules() {
    // @trace gap:BR-003
    // Verify that cache_peer_access rules enforce:
    //   1. Only .localhost traffic uses the peer
    //   2. All other traffic is denied to the peer
    //   3. Rules are in correct order (allow before deny)

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // Verify allow rule
    assert!(
        squid_conf.contains("cache_peer_access tillandsias-router allow localhost_subdomain"),
        "cache_peer_access should allow localhost_subdomain ACL"
    );

    // Verify deny rule
    assert!(
        squid_conf.contains("cache_peer_access tillandsias-router deny all"),
        "cache_peer_access should deny all other traffic"
    );

    // Verify order: allow comes before deny
    if let (Some(allow_idx), Some(deny_idx)) = (
        squid_conf.find("cache_peer_access tillandsias-router allow localhost_subdomain"),
        squid_conf.find("cache_peer_access tillandsias-router deny all"),
    ) {
        assert!(
            allow_idx < deny_idx,
            "allow rule must come before deny rule"
        );
    }
}

// ============================================================================
// Test 4: Never-Direct Rule for .localhost
// ============================================================================

#[test]
fn test_never_direct_localhost_rule() {
    // @trace gap:BR-003
    // Verify that .localhost requests will NEVER be resolved directly
    // and MUST go through the cache_peer (router).
    //
    // Rule: never_direct allow localhost_subdomain
    //
    // This prevents Squid from:
    //   1. Attempting external DNS resolution of .localhost
    //   2. Connecting directly to the internet for these requests
    //   3. Bypassing the enclave router

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    assert!(
        squid_conf.contains("never_direct allow localhost_subdomain"),
        "never_direct rule must prevent .localhost requests from escaping to public DNS"
    );

    // Verify it appears near cache_peer rules (they work together)
    let never_direct_idx = squid_conf.find("never_direct allow localhost_subdomain").unwrap();
    let cache_peer_idx = squid_conf.find("cache_peer router").unwrap();
    let distance = (never_direct_idx as i32 - cache_peer_idx as i32).abs();
    assert!(
        distance < 1000,
        "never_direct should be close to cache_peer definition (within 1000 chars)"
    );
}

// ============================================================================
// Test 5: Enclave Network Peer Configuration
// ============================================================================

#[test]
fn test_cache_peer_enclave_network_addressing() {
    // @trace gap:BR-003, spec:subdomain-routing-via-reverse-proxy
    // Verify that cache_peer references the router by hostname on the
    // enclave network, NOT by IP address or localhost binding.
    //
    // Correct: cache_peer router ...
    // Wrong: cache_peer 127.0.0.1 ...
    // Wrong: cache_peer 10.0.42.x ...
    //
    // The router container has:
    //   - Network alias: `router` on tillandsias-enclave network
    //   - Listens on: :8080 (inside container)
    //   - Hostname: tillandsias-router

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // MUST use hostname, not IP address
    assert!(
        squid_conf.contains("cache_peer router parent 8080"),
        "cache_peer must reference 'router' hostname on enclave network"
    );

    // Verify it's NOT using localhost or any other IP
    let cache_peer_line = squid_conf
        .lines()
        .find(|line| line.starts_with("cache_peer"))
        .expect("cache_peer directive not found");

    assert!(
        !cache_peer_line.contains("127.0.0.1"),
        "cache_peer should NOT use 127.0.0.1 (localhost); must use 'router' hostname"
    );

    assert!(
        !cache_peer_line.contains("0.0.0.0"),
        "cache_peer should NOT use 0.0.0.0; must use 'router' hostname"
    );

    // Verify port is 8080 (internal container port, not 80)
    assert!(
        cache_peer_line.contains("8080"),
        "cache_peer port must be 8080 (rootless podman cannot bind <1024)"
    );
}

// ============================================================================
// Test 6: Cache Peer Naming and Identification
// ============================================================================

#[test]
fn test_cache_peer_unique_identifier() {
    // @trace gap:BR-003
    // Verify that the cache_peer has a unique name for logging and
    // referencing in ACL rules.
    //
    // Expected: name=tillandsias-router
    //
    // This allows:
    //   1. Squid logs to identify which peer handled a request
    //   2. ACL rules to reference this specific peer
    //   3. Monitoring and debugging of peer interactions

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    let cache_peer_line = squid_conf
        .lines()
        .find(|line| line.starts_with("cache_peer"))
        .expect("cache_peer directive not found");

    assert!(
        cache_peer_line.contains("name=tillandsias-router"),
        "cache_peer must have name=tillandsias-router for identification"
    );
}

// ============================================================================
// Test 7: CONNECT Method Support for HTTPS Tunneling
// ============================================================================

#[test]
fn test_https_connect_method_for_localhost() {
    // @trace gap:BR-003, spec:subdomain-routing-via-reverse-proxy
    // Verify that Squid allows CONNECT method for .localhost domains
    // to support HTTPS tunneling through the router.
    //
    // Agents inside forge may need:
    //   curl https://service.localhost/
    //
    // This requires CONNECT tunneling through the proxy and then to the router.

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // Verify CONNECT ACL exists
    assert!(
        squid_conf.contains("acl CONNECT method CONNECT"),
        "CONNECT ACL must be defined for HTTPS tunneling"
    );

    // Verify SSL ports ACL exists (port 443, 8443)
    assert!(
        squid_conf.contains("acl SSL_ports port 443"),
        "SSL_ports ACL should include port 443"
    );

    // Verify .localhost is allowed independently (so HTTPS tunneling works)
    assert!(
        squid_conf.contains("http_access allow localhost_subdomain"),
        ".localhost should be allowed on all ports, enabling HTTPS tunneling"
    );

    // The design allows .localhost BEFORE the CONNECT-on-SSL-ports rule,
    // which means HTTPS .localhost requests are permitted regardless of port restriction
    let localhost_idx = squid_conf.find("http_access allow localhost_subdomain").unwrap();
    let connect_rule_idx = squid_conf.find("http_access allow CONNECT SSL_ports").unwrap();
    assert!(
        localhost_idx < connect_rule_idx,
        ".localhost rule should be evaluated before port-restricted CONNECT rule"
    );
}

// ============================================================================
// Test 8: No-Query ICP Configuration
// ============================================================================

#[test]
fn test_cache_peer_no_query_setting() {
    // @trace gap:BR-003
    // Verify that the cache_peer is configured with `no-query` option.
    //
    // no-query means:
    //   - Don't send ICP (Internet Cache Protocol) queries to the peer
    //   - Always forward requests to the peer without ICP handshake
    //   - Reduces latency for .localhost requests
    //
    // The 0 in "parent 8080 0" also disables ICP port (0 = disabled)

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    let cache_peer_line = squid_conf
        .lines()
        .find(|line| line.starts_with("cache_peer"))
        .expect("cache_peer directive not found");

    assert!(
        cache_peer_line.contains("no-query"),
        "cache_peer should have no-query option (disable ICP)"
    );

    // Verify ICP port is disabled (0)
    assert!(
        cache_peer_line.contains("parent 8080 0"),
        "cache_peer should have ICP port disabled (0)"
    );
}

// ============================================================================
// Test 9: Configuration Comments and Documentation
// ============================================================================

#[test]
fn test_cache_peer_documentation() {
    // @trace gap:BR-003
    // Verify that the cache_peer section includes comprehensive documentation
    // explaining the purpose, configuration, and behavior.

    let squid_conf = fs::read_to_string("images/proxy/squid.conf")
        .or_else(|_| fs::read_to_string("../images/proxy/squid.conf"))
        .or_else(|_| fs::read_to_string("../../images/proxy/squid.conf"))
        .expect("Failed to read squid.conf");

    // Find the comment section before cache_peer
    let cache_peer_idx = squid_conf.find("cache_peer router").unwrap();
    let comment_section = &squid_conf[..cache_peer_idx];

    // Verify trace annotation references the gap
    assert!(
        comment_section.contains("gap:BR-003"),
        "cache_peer section should reference gap:BR-003"
    );

    // Verify spec annotation
    assert!(
        comment_section.contains("spec:subdomain-routing-via-reverse-proxy"),
        "cache_peer section should reference subdomain-routing-via-reverse-proxy spec"
    );

    // Verify documentation of router container setup
    assert!(
        comment_section.contains("router") || comment_section.contains("tillandsias-router"),
        "comment should explain router container configuration"
    );

    // Verify documentation of enclave network
    assert!(
        comment_section.contains("enclave"),
        "comment should mention enclave network"
    );
}
