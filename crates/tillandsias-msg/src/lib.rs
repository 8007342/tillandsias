// @trace order:1506-q7ab, openspec/changes/fleet-messaging-poc/specs/fleet-messaging/spec.md
//
// tillandsias-msg — what the msg CLI (tillandsias-plan, 1506-nvqt) and the
// resident mover (tillandsias --msg-serve, 1506-q7ab) must agree on byte for
// byte: the body checks, the envelope and receipt formats, and every write the
// infrastructure makes inside a lane directory.

/// The pure body checks: budget, KIND vocabulary, secret shapes, TTL bounds.
pub mod shape;

/// No-follow, fd-relative file operations beneath a lane directory, so a forge
/// that holds its own lane directory cannot steer the host-side mover through
/// a symlink into another lane or anywhere else on the host.
pub mod lanefs;

/// The Maildir-shaped lane store: envelope and receipt formats and the
/// infrastructure's writes (mailbox acceptance, ack, undelivered, TTL sweep).
pub mod store;
