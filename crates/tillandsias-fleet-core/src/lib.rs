//! Pure, no-I/O core of the fleet rendezvous: constants, the availability
//! score and the per-service affinity table. No clock, no filesystem, no
//! network, no threads, so it compiles natively and to wasm32.
//!
//! @trace plan:1548-dylo

pub mod score;
