//! Quick-start litmus test for image building.
//!
//! Usage:
//!   cargo run --bin build-image -- forge
//!   cargo run --bin build-image -- git
//!   cargo run --bin build-image -- proxy
//!
//! This exercises the exact ImageBuilder code path that tillandsias app uses.
//! Records podman calls for litmus assertion (test harness mode).
//!
//! In toolbox:
//!   toolbox run cargo run --bin build-image -- forge
//!
//! @trace spec:user-runtime-lifecycle, spec:litmus-framework

use std::env;
use std::process;

// TODO: When ImageBuilder trait is implemented, import and use it here
// For now, this is a stub that documents the pattern

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        eprintln!("Usage: {} <image_name> [--assert-calls]", args[0]);
        eprintln!();
        eprintln!("Examples:");
        eprintln!(
            "  {} forge          # Build forge, record podman calls",
            args[0]
        );
        eprintln!(
            "  {} git            # Build git, record podman calls",
            args[0]
        );
        eprintln!(
            "  {} proxy          # Build proxy, record podman calls",
            args[0]
        );
        eprintln!();
        eprintln!("With --assert-calls: verify exact podman invocation against spec");
        process::exit(1);
    }

    let image_name = &args[1];
    let assert_calls = args.len() > 2 && args[2] == "--assert-calls";

    println!("[litmus] Building image: {}", image_name);
    println!(
        "[litmus] Mode: {}",
        if assert_calls { "assert" } else { "record" }
    );

    // TODO: Replace with real ImageBuilder implementation:
    //
    // let builder = if assert_calls {
    //     Box::new(PodmanCapture::new()) as Box<dyn ImageBuilder>
    // } else {
    //     Box::new(PodmanDirect::new())
    // };
    //
    // match builder.build(image_name).await {
    //     Ok(result) => {
    //         println!("[litmus✓] Build succeeded");
    //         println!("  Image tag: {}", result.image_tag);
    //         println!("  Size: {} MB", result.size_mb);
    //         println!("  Staleness: {}", result.was_stale);
    //         if let Some(call) = builder.last_podman_call() {
    //             println!("  Podman call: {:?}", call);
    //             if assert_calls {
    //                 // Verify against spec
    //             }
    //         }
    //         process::exit(0);
    //     }
    //     Err(e) => {
    //         eprintln!("[litmus✗] Build failed: {}", e);
    //         process::exit(1);
    //     }
    // }

    println!("[litmus→] ImageBuilder trait not yet integrated");
    println!("[litmus→] This is a placeholder for the convergence pattern");
    process::exit(0);
}
