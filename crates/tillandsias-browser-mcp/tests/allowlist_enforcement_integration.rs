//! Integration tests for browser allowlist enforcement post-proxy.
//!
//! @trace spec:host-browser-mcp, spec:subdomain-routing-via-reverse-proxy, spec:browser-isolation-core
//! @cheatsheet web/http.md, web/mcp.md
//!
//! These tests validate the defense-in-depth allowlist enforcement at the MCP application layer,
//! independent of the network-layer router. They simulate real-world scenarios:
//!
//! 1. Allowed routes (.localhost subdomains, RFC 6761 loopback addresses)
//! 2. Blocked routes (external domains, non-standard ports, recursive OpenCode)
//! 3. Project isolation (services under one project cannot access another's routes)
//! 4. Port enforcement (only 8080, 80 allowed for localhost; 443 via HTTPS)
//!
//! **Note**: These tests verify the RPC interface behavior. The network-layer validation
//! (router enforcing Caddyfile routes) is tested separately in the router crate.
//!
//! Test strategy: Each test calls browser.open via the RPC interface and validates
//! whether the request succeeds or fails based on allowlist rules. Tests are organized
//! by layer: format validation (Layer 1), then allowlist enforcement (Layer 2).

use serde_json::json;
use tillandsias_browser_mcp::server::{BrowserMcpServer, McpServerConfig};
use tillandsias_browser_mcp::framing::{RpcRequest, RpcResponse};

/// Test helper: create a server with fake launch mode (no real browser spawning).
fn test_server(project: &str) -> BrowserMcpServer {
    BrowserMcpServer::with_project_label_and_mode(
        McpServerConfig::default(),
        project,
        None, // no browser binary override
        true, // fake_launch: true (don't actually spawn browser)
    )
}

/// Check if response is a tool-level error (Success with isError=true)
fn is_tool_error(response: &RpcResponse) -> bool {
    match response {
        RpcResponse::Success { result, .. } => {
            result.get("isError").and_then(|v| v.as_bool()).unwrap_or(false)
        }
        _ => false,
    }
}

/// Extract error message from tool-level error response
fn get_tool_error_message(response: &RpcResponse) -> Option<String> {
    match response {
        RpcResponse::Success { result, .. } if is_tool_error(response) => {
            result
                .get("content")
                .and_then(|c| c.as_array())
                .and_then(|arr| arr.first())
                .and_then(|obj| obj.get("text"))
                .and_then(|t| t.as_str())
                .map(|s| s.to_string())
        }
        _ => None,
    }
}

// ============================================================================
// Layer 1: Format Validation Tests
// ============================================================================
// These tests verify the first defense layer: basic URL format validation
// against the RFC 6761 allowed patterns.

#[tokio::test]
async fn format_validation_accepts_valid_subdomain_url() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(1),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    // Should succeed at the format validation layer
    assert!(
        !is_tool_error(&response),
        "valid format should not be an error"
    );
}

#[tokio::test]
async fn format_validation_rejects_ip_literal() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(2),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://127.0.0.1:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "IP literals should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_wrong_port() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(3),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:3000/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "wrong port should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_missing_project_label() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(4),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "missing project should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_bare_localhost() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(5),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://localhost:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "bare localhost should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_wrong_project() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(6),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.beta.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "wrong project should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_opencode_self_reference() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(7),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://opencode.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "opencode-self should be rejected");
}

// ============================================================================
// Layer 2: Allowlist Enforcement Tests (vs Active Routes)
// ============================================================================
// These tests verify the second defense layer: enforcement against active routes
// registered in the window registry.

#[tokio::test]
async fn allowlist_allows_matching_active_route() {
    // @trace spec:subdomain-routing-via-reverse-proxy
    let server = test_server("acme");

    // Register a route in the window registry by calling browser.open with valid format
    let initial = server
        .handle_request(RpcRequest {
            id: Some(100),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&initial),
        "should succeed at the format validation layer"
    );

    // Try to open the same route again (should be debounced or allowed)
    let second = server
        .handle_request(RpcRequest {
            id: Some(101),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/path"
                }
            }),
        })
        .await;

    // Second request to same host should succeed (debounced)
    assert!(
        !is_tool_error(&second),
        "registered route should be allowed on subsequent request"
    );
}

#[tokio::test]
async fn allowlist_blocks_unregistered_route_with_active_routes() {
    // @trace spec:subdomain-routing-via-reverse-proxy, spec:host-browser-mcp
    let server = test_server("acme");

    // Register one route
    let _ = server
        .handle_request(RpcRequest {
            id: Some(102),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    // Attempt to open a different service that's NOT registered
    let attempt = server
        .handle_request(RpcRequest {
            id: Some(103),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://api.acme.localhost:8080/"
                }
            }),
        })
        .await;

    // This should fail at Layer 2 (allowlist enforcement)
    assert!(
        is_tool_error(&attempt),
        "unregistered route should be blocked at allowlist layer"
    );
    let message = get_tool_error_message(&attempt);
    assert!(
        message.as_ref().map(|m| m.contains("URL_NOT_ALLOWED")).unwrap_or(false),
        "error should indicate URL not allowed"
    );
}

// ============================================================================
// IP Literal Tests
// ============================================================================

#[tokio::test]
async fn format_validation_rejects_ipv4_loopback() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(250),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://127.0.0.1:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "IPv4 loopback should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_ipv6_loopback() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(251),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://[::1]:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "IPv6 loopback should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_non_loopback_ipv4() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(252),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://192.168.1.1:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "non-loopback IPv4 should be rejected");
}

#[tokio::test]
async fn format_validation_rejects_non_loopback_ipv6() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(253),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://[2001:db8::1]:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "non-loopback IPv6 should be rejected");
}

// ============================================================================
// Scheme and Port Enforcement Tests
// ============================================================================

#[tokio::test]
async fn format_validation_blocks_unsupported_schemes() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    for (scheme, url) in &[
        ("ftp", "ftp://web.acme.localhost:8080/"),
        ("file", "file:///etc/passwd"),
        ("javascript", "javascript:alert('xss')"),
        ("data", "data:text/html,<h1>hi</h1>"),
    ] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(260),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(
            is_tool_error(&response),
            "scheme {scheme} should be blocked"
        );
    }
}

#[tokio::test]
async fn format_validation_blocks_non_standard_ports() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    for port in &[3000, 5173, 9000, 443, 5000] {
        let url = format!("http://web.acme.localhost:{}/", port);
        let response = server
            .handle_request(RpcRequest {
                id: Some(261),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(is_tool_error(&response), "port {port} should be blocked");
    }
}

#[tokio::test]
async fn format_validation_accepts_https_with_port_8080() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(262),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "https://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&response),
        "HTTPS on port 8080 should be allowed"
    );
}

// ============================================================================
// External Domain Blocking Tests
// ============================================================================

#[tokio::test]
async fn format_validation_blocks_all_external_domains() {
    // @trace spec:host-browser-mcp, spec:browser-isolation-core
    let server = test_server("acme");

    for url in &[
        "http://google.com/",
        "https://github.com/",
        "http://example.com/",
        "http://amazon.com:8080/",
        "https://api.example.org/v1/data",
    ] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(270),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(is_tool_error(&response), "external domain {url} should be blocked");
    }
}

#[tokio::test]
async fn format_validation_blocks_localhost_lookalikes() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    for url in &[
        "http://web.acme.local:8080/",
        "http://web.acme.test:8080/",
        "http://web.acme.localhost.fake:8080/",
    ] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(271),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(is_tool_error(&response), "localhost lookalike {url} should be blocked");
    }
}

// ============================================================================
// Recursive OpenCode Prevention Tests
// ============================================================================

#[tokio::test]
async fn format_validation_blocks_opencode_self_references() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    for url in &[
        "http://opencode.acme.localhost:8080/",
        "https://opencode.acme.localhost:8080/",
        "http://opencode.beta.localhost:8080/",
    ] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(280),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(is_tool_error(&response), "opencode URL {url} should be blocked");
    }
}

// ============================================================================
// Project Isolation Tests
// ============================================================================

#[tokio::test]
async fn format_validation_respects_project_isolation() {
    // @trace spec:subdomain-routing-via-reverse-proxy
    let server_acme = test_server("acme");
    let server_beta = test_server("beta");

    // Acme server should reject URLs from a different project
    let acme_wrong_project = server_acme
        .handle_request(RpcRequest {
            id: Some(290),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.beta.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        is_tool_error(&acme_wrong_project),
        "acme server should reject beta URLs"
    );

    // Beta server should reject URLs from acme project
    let beta_wrong_project = server_beta
        .handle_request(RpcRequest {
            id: Some(291),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        is_tool_error(&beta_wrong_project),
        "beta server should reject acme URLs"
    );
}

// ============================================================================
// Multiple Services Per Project Tests
// ============================================================================

#[tokio::test]
async fn allowlist_allows_multiple_services_same_project() {
    // @trace spec:subdomain-routing-via-reverse-proxy
    let server = test_server("java");

    // Register flutter service
    let flutter_response = server
        .handle_request(RpcRequest {
            id: Some(300),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://flutter.java.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&flutter_response),
        "flutter service registration should succeed"
    );

    // Multiple paths under the same service should be accessible
    let flutter_reopen = server
        .handle_request(RpcRequest {
            id: Some(302),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://flutter.java.localhost:8080/dashboard"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&flutter_reopen),
        "flutter service should be accessible with different path"
    );

    // Different port variant should fail (format validation)
    let flutter_bad_port = server
        .handle_request(RpcRequest {
            id: Some(303),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://flutter.java.localhost:3000/"
                }
            }),
        })
        .await;

    assert!(
        is_tool_error(&flutter_bad_port),
        "non-standard port should be blocked by format validation"
    );
}

// ============================================================================
// Malformed URL Tests
// ============================================================================

#[tokio::test]
async fn format_validation_blocks_malformed_urls() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    for url in &["not a url", "http://", "", "http://web.acme.localhost:8080:extra"] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(310),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(is_tool_error(&response), "malformed URL '{url}' should be rejected");
    }
}

// ============================================================================
// Userinfo and Credentials Tests
// ============================================================================

#[tokio::test]
async fn format_validation_rejects_userinfo() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    let response = server
        .handle_request(RpcRequest {
            id: Some(400),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://user:pass@web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(is_tool_error(&response), "userinfo should be rejected");
}

// ============================================================================
// HTTP vs HTTPS Tests
// ============================================================================

#[tokio::test]
async fn allowlist_allows_both_http_and_https_for_same_host() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    // Register HTTP first
    let http_response = server
        .handle_request(RpcRequest {
            id: Some(500),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&http_response),
        "HTTP route registration should succeed"
    );

    // Now try HTTPS for the same host (should be allowed at Layer 2)
    let https_response = server
        .handle_request(RpcRequest {
            id: Some(501),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "https://web.acme.localhost:8080/foo"
                }
            }),
        })
        .await;

    // Should succeed (or be debounced, but not be an error)
    let is_error = is_tool_error(&https_response);
    let message = get_tool_error_message(&https_response);
    assert!(
        !is_error || !message.as_ref().map(|m| m.contains("scheme")).unwrap_or(false),
        "HTTPS should be allowed for same hostname (error should not be about scheme)"
    );
}

// ============================================================================
// Path and Query Parameters Tests
// ============================================================================

#[tokio::test]
async fn allowlist_ignores_paths_and_query_params() {
    // @trace spec:host-browser-mcp
    let server = test_server("acme");

    // Register a basic route
    let register = server
        .handle_request(RpcRequest {
            id: Some(600),
            method: "tools/call".to_string(),
            params: json!({
                "name": "browser.open",
                "arguments": {
                    "url": "http://web.acme.localhost:8080/"
                }
            }),
        })
        .await;

    assert!(
        !is_tool_error(&register),
        "route registration should succeed"
    );

    // Paths and query parameters should not affect allowlist decision
    for (description, url) in &[
        ("with path", "http://web.acme.localhost:8080/long/path/to/page"),
        ("with query params", "http://web.acme.localhost:8080/?key=value&foo=bar"),
        ("with path and query", "http://web.acme.localhost:8080/path?query=value#fragment"),
    ] {
        let response = server
            .handle_request(RpcRequest {
                id: Some(601),
                method: "tools/call".to_string(),
                params: json!({
                    "name": "browser.open",
                    "arguments": {
                        "url": url
                    }
                }),
            })
            .await;

        assert!(
            !is_tool_error(&response),
            "URL {description} should be allowed"
        );
    }
}
