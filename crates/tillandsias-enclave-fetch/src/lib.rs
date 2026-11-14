//! enclave-fetch: an MCP service that gives agents `fetch`, `feed` and `docs`
//! from a curated catalog, so the forge's shell never needs research egress.
//!
//! Every safeguard is a pure function here so it can be tested without a
//! network: the catalog decides WHAT may be fetched, [`ipguard`] decides
//! WHERE a connection may go, [`robots`] honours the site's wishes, and
//! [`markdown`] turns the page into capped, paged text.
//!
//! @trace spec:proxy-container, order:2041-csm4

pub mod catalog;
pub mod fetch;
pub mod ipguard;
pub mod markdown;
pub mod ratelimit;
pub mod robots;
pub mod server;
