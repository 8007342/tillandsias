//! Cross-crate contract pin: every prompt the macOS host's `--github-login`
//! expect script WAITS FOR must be a prompt the guest's CURRENT GitHub login
//! path actually prints, in the order it prints them.
//!
//! `DynamicExpect` is strictly sequential, so a needle the guest never prints
//! is a silent deadlock (the host scans forever), and with the guest's 30s PTY
//! heartbeat resetting the exec idle deadline it is an UNBOUNDED one. It has
//! happened twice:
//!   - 2026-08-10/11: the guest moved to credential-first (operator directive
//!     2026-07-29) and the host still asked name -> email -> token.
//!   - 2026-09-25 (1383-dkxi): the guest's GitHub terminal login became a
//!     DEVICE FLOW (1381-za6b, 3a2b01d9e) that prints a QR code and a
//!     one-time code and never prints "authentication token", while the host
//!     still waited for it first.
//!
//! WHY THE OLD PIN PASSED THROUGH THE SECOND ONE. It checked that the guest
//! SOURCE contained "GitHub authentication token" somewhere, and it does: in
//! GH_LOGIN_TOKEN_SCRIPT, the retired paste path, which the GitHub terminal
//! branch no longer calls. A fixture that pins a string's existence rather
//! than the path that is taken pins the retired path. This one reads the
//! branch the guest takes and the function it calls.
//!
//! @trace spec:macos-native-tray, spec:gh-auth-script, plan 663-acdw, order:1383-dkxi

#![cfg(target_os = "macos")]

const HOST: &str = include_str!("../src/diagnose.rs");
const GUEST: &str = include_str!("../../tillandsias-headless/src/main.rs");

/// The text from `start` to the first `end` after it. Panics loudly when a
/// landmark is gone, so a rename fails here instead of making a check vacuous.
fn window<'a>(src: &'a str, start: &str, end: &str) -> &'a str {
    let s = src
        .find(start)
        .unwrap_or_else(|| panic!("landmark {start:?} is gone; update this pin with the code"));
    let rest = &src[s..];
    let e = rest
        .find(end)
        .unwrap_or_else(|| panic!("no {end:?} after {start:?}; update this pin with the code"));
    &rest[..e]
}

/// The host's `expects` vec literal inside `github_login_main`.
fn host_expects() -> &'static str {
    let login = window(HOST, "pub fn github_login_main() -> i32", "\n}\n");
    window(login, "let expects = vec![", "\n        ];")
}

/// The body of the guest's GitHub device login.
fn guest_device_login() -> &'static str {
    window(GUEST, "fn run_github_device_login(", "\n}\n")
}

/// The guest's GitHub TERMINAL login takes the device flow. If this fails the
/// guest has changed paths again, and every check below is about the wrong one.
#[test]
fn guest_github_terminal_login_takes_the_device_flow() {
    let branch = window(
        GUEST,
        "if matches!(config.provider, ProviderId::GitHub)\n        && matches!(config.input_mode, LoginInputMode::Terminal)",
        "} else {",
    );
    assert!(
        branch.contains("run_github_device_login(&container"),
        "the GitHub terminal branch no longer calls run_github_device_login: {branch}"
    );
    let device = guest_device_login();
    assert!(
        device.contains("Scan this QR code") && device.contains("Enter one-time code"),
        "the device flow must print the QR code and the one-time code the host has to show"
    );
}

/// THE PIN. The host waits for nothing the guest's current path does not print.
/// Pre-fix result: FAILS — the host's first needle was b"authentication token",
/// which the device flow never prints.
#[test]
fn host_waits_for_no_prompt_the_device_flow_never_prints() {
    let expects = host_expects();
    let device = guest_device_login();
    assert!(
        !device.contains("authentication token"),
        "premise: the device flow must not print the retired paste prompt"
    );
    assert!(
        !expects.contains("b\"authentication token\""),
        "the host still waits for \"authentication token\", which the guest's device flow \
         never prints: a silent, unbounded deadlock. There is nothing to type for the \
         credential any more; drop that expect. Host expects: {expects}"
    );
}

/// The prompts the host DOES answer are the guest's identity prompts, in the
/// guest's order (name, then email).
#[test]
fn host_identity_expects_match_the_guest_prompt_order() {
    let expects = host_expects();
    let host_name = expects
        .find("b\"author name\"")
        .expect("host must answer the git author name");
    let host_email = expects
        .find("b\"author email\"")
        .expect("host must answer the git author email");
    assert!(host_name < host_email, "host must answer name before email");

    let guest_name = GUEST
        .find("\"Git author name\"")
        .expect("guest must prompt for the git author name");
    let guest_email = GUEST
        .find("\"Git author email\"")
        .expect("guest must prompt for the git author email");
    assert!(guest_name < guest_email, "guest prompts name before email");
}

/// The QR code and one-time code must reach the user. Through the escaped log
/// preview they were unreadable, so the host must pass the guest's output to
/// the terminal raw. Pre-fix result: FAILS — only the escaped `on_event` path
/// existed.
#[test]
fn host_shows_the_guest_output_raw() {
    let login = window(HOST, "pub fn github_login_main() -> i32", "\n}\n");
    assert!(
        login.contains("exec_over_stream_expect_dynamic_with_output("),
        "the host must use the raw-output variant so the QR code reaches the user"
    );
    assert!(
        login.contains("write_all(bytes)"),
        "the raw sink must write the guest's bytes to the user's terminal verbatim"
    );
}

/// NEGATIVE CONTROL. Each check above could pass vacuously if its window were
/// empty or wrong. Prove the extraction discriminates: the host window really
/// contains the identity needles, and the guest source really does still carry
/// the retired paste prompt OUTSIDE the device flow, which is exactly the
/// string the old pin found and mistook for the live path.
#[test]
fn extraction_discriminates_the_live_path_from_the_retired_one() {
    assert!(
        host_expects().contains("DynamicExpect"),
        "host window is empty or wrong"
    );
    assert!(
        GUEST.contains("Paste your GitHub authentication token"),
        "the retired paste prompt is gone from the guest source; the old failure mode this \
         pin guards against no longer exists, so review whether this control still means anything"
    );
    assert!(
        !guest_device_login().contains("Paste your GitHub authentication token"),
        "the device-flow window swallowed the retired paste path; the window is wrong"
    );
}
