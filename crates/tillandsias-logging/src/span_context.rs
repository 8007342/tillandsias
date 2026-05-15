// @trace spec:distributed-tracing, gap:OBS-007
//! Cross-container span linkage for distributed tracing.
//!
//! Provides:
//! - SpanContext struct tracking span_id, parent_span_id, and trace_id
//! - Context propagation across container boundaries
//! - Builder pattern for creating child spans
//! - Queryable parent-child span relationships
//! - Thread-local context storage for automatic propagation

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use uuid::Uuid;

/// Unique identifier for a span
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SpanId(u64);

impl SpanId {
    /// Generate a new random span ID
    pub fn new() -> Self {
        // Use atomic counter + random component for uniqueness across threads
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let random = Uuid::new_v4().as_u128() as u64;
        SpanId(counter.wrapping_mul(31) ^ random)
    }

    /// Create span ID from u64
    pub fn from_u64(id: u64) -> Self {
        SpanId(id)
    }

    /// Get the underlying u64 value
    pub fn as_u64(self) -> u64 {
        self.0
    }
}

impl Default for SpanId {
    fn default() -> Self {
        SpanId::new()
    }
}

impl std::fmt::Display for SpanId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:016x}", self.0)
    }
}

impl std::str::FromStr for SpanId {
    type Err = std::num::ParseIntError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        u64::from_str_radix(s, 16).map(SpanId)
    }
}

/// Unique identifier for a trace (group of spans across containers)
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct TraceId(String);

impl TraceId {
    /// Generate a new trace ID (UUID-based for global uniqueness)
    pub fn new() -> Self {
        TraceId(Uuid::new_v4().to_string())
    }

    /// Create trace ID from string
    pub fn from_string(id: String) -> Self {
        TraceId(id)
    }

    /// Get the underlying string value
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for TraceId {
    fn default() -> Self {
        TraceId::new()
    }
}

impl std::fmt::Display for TraceId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Context for a span in a distributed trace.
///
/// Tracks:
/// - span_id: Unique identifier for this span
/// - trace_id: Identifier for the entire trace (shared across containers)
/// - parent_span_id: Optional reference to parent span for linkage
///
/// # Example
///
/// ```ignore
/// // Create root span
/// let root = SpanContext::root();
/// let root_id = root.span_id();
///
/// // Create child span (logs will link via parent_span_id)
/// let child = root.child_span();
/// assert_eq!(child.parent_span_id(), Some(root_id));
/// assert_eq!(child.trace_id(), root.trace_id());
/// ```
#[derive(Clone, Debug, PartialEq)]
pub struct SpanContext {
    span_id: SpanId,
    trace_id: TraceId,
    parent_span_id: Option<SpanId>,
}

impl SpanContext {
    /// Create a new root span (no parent)
    pub fn root() -> Self {
        SpanContext {
            span_id: SpanId::new(),
            trace_id: TraceId::new(),
            parent_span_id: None,
        }
    }

    /// Create a new root span with explicit trace ID (for cross-container linkage)
    pub fn root_with_trace(trace_id: TraceId) -> Self {
        SpanContext {
            span_id: SpanId::new(),
            trace_id,
            parent_span_id: None,
        }
    }

    /// Create a child span with this span as parent
    pub fn child_span(&self) -> Self {
        SpanContext {
            span_id: SpanId::new(),
            trace_id: self.trace_id.clone(),
            parent_span_id: Some(self.span_id),
        }
    }

    /// Get this span's ID
    pub fn span_id(&self) -> SpanId {
        self.span_id
    }

    /// Get the trace ID (shared across all spans in the trace)
    pub fn trace_id(&self) -> TraceId {
        self.trace_id.clone()
    }

    /// Get the parent span ID (if this is a child span)
    pub fn parent_span_id(&self) -> Option<SpanId> {
        self.parent_span_id
    }

    /// Check if this is a root span (no parent)
    pub fn is_root(&self) -> bool {
        self.parent_span_id.is_none()
    }

    /// Create a new builder for more control
    pub fn builder() -> SpanContextBuilder {
        SpanContextBuilder::new()
    }

    /// Export span context as a propagation header (for cross-container transit)
    ///
    /// Format: `trace_id:span_id:parent_span_id` (parent_span_id omitted if root)
    pub fn to_propagation_header(&self) -> String {
        match self.parent_span_id {
            Some(parent) => {
                format!("{}:{}:{}", self.trace_id, self.span_id, parent)
            }
            None => {
                format!("{}:{}", self.trace_id, self.span_id)
            }
        }
    }

    /// Import span context from a propagation header (for cross-container receipt)
    pub fn from_propagation_header(header: &str) -> Option<Self> {
        let parts: Vec<&str> = header.split(':').collect();

        match parts.as_slice() {
            // Root span header: trace_id:span_id
            [trace_id_str, span_id_str] => Some(SpanContext {
                span_id: SpanId::from_u64(u64::from_str_radix(span_id_str, 16).ok()?),
                trace_id: TraceId::from_string(trace_id_str.to_string()),
                parent_span_id: None,
            }),
            // Child span header: trace_id:span_id:parent_span_id
            [trace_id_str, span_id_str, parent_span_id_str] => Some(SpanContext {
                span_id: SpanId::from_u64(u64::from_str_radix(span_id_str, 16).ok()?),
                trace_id: TraceId::from_string(trace_id_str.to_string()),
                parent_span_id: Some(SpanId::from_u64(
                    u64::from_str_radix(parent_span_id_str, 16).ok()?,
                )),
            }),
            _ => None,
        }
    }
}

impl Default for SpanContext {
    fn default() -> Self {
        SpanContext::root()
    }
}

/// Builder for constructing SpanContext with explicit values
pub struct SpanContextBuilder {
    span_id: Option<SpanId>,
    trace_id: Option<TraceId>,
    parent_span_id: Option<SpanId>,
}

impl SpanContextBuilder {
    /// Create a new builder
    pub fn new() -> Self {
        SpanContextBuilder {
            span_id: None,
            trace_id: None,
            parent_span_id: None,
        }
    }

    /// Set the span ID
    pub fn with_span_id(mut self, id: SpanId) -> Self {
        self.span_id = Some(id);
        self
    }

    /// Set the trace ID
    pub fn with_trace_id(mut self, id: TraceId) -> Self {
        self.trace_id = Some(id);
        self
    }

    /// Set the parent span ID
    pub fn with_parent_span_id(mut self, id: SpanId) -> Self {
        self.parent_span_id = Some(id);
        self
    }

    /// Build the span context
    pub fn build(self) -> SpanContext {
        SpanContext {
            span_id: self.span_id.unwrap_or_else(SpanId::new),
            trace_id: self.trace_id.unwrap_or_else(TraceId::new),
            parent_span_id: self.parent_span_id,
        }
    }
}

impl Default for SpanContextBuilder {
    fn default() -> Self {
        SpanContextBuilder::new()
    }
}

// Thread-local storage for the current span context
// Enables automatic propagation without explicit passing
thread_local! {
    static CURRENT_SPAN: std::cell::RefCell<Option<Arc<SpanContext>>> = std::cell::RefCell::new(None);
}

/// Set the current span context for the thread
pub fn set_current_span(ctx: SpanContext) {
    CURRENT_SPAN.with(|s| {
        *s.borrow_mut() = Some(Arc::new(ctx));
    });
}

/// Get the current span context (returns None if not set)
pub fn current_span() -> Option<SpanContext> {
    CURRENT_SPAN.with(|s| s.borrow().as_ref().map(|arc| arc.as_ref().clone()))
}

/// Clear the current span context
pub fn clear_current_span() {
    CURRENT_SPAN.with(|s| {
        *s.borrow_mut() = None;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_span_id_generation() {
        let id1 = SpanId::new();
        let id2 = SpanId::new();

        // IDs should be unique
        assert_ne!(id1, id2);
    }

    #[test]
    fn test_trace_id_generation() {
        let trace1 = TraceId::new();
        let trace2 = TraceId::new();

        // Trace IDs should be unique
        assert_ne!(trace1, trace2);
    }

    #[test]
    fn test_root_span_context() {
        let root = SpanContext::root();

        // Root span has no parent
        assert!(root.is_root());
        assert_eq!(root.parent_span_id(), None);

        // Root span has valid span and trace IDs
        assert_ne!(root.span_id().as_u64(), 0);
        assert!(!root.trace_id().as_str().is_empty());
    }

    #[test]
    fn test_child_span_context() {
        let root = SpanContext::root();
        let root_id = root.span_id();
        let trace_id = root.trace_id();

        let child = root.child_span();

        // Child has same trace ID as parent
        assert_eq!(child.trace_id(), trace_id);

        // Child references parent
        assert_eq!(child.parent_span_id(), Some(root_id));

        // Child is not a root span
        assert!(!child.is_root());

        // Child has different span ID
        assert_ne!(child.span_id(), root_id);
    }

    #[test]
    fn test_span_context_hierarchy() {
        let root = SpanContext::root();
        let child1 = root.child_span();
        let child2 = root.child_span();
        let grandchild = child1.child_span();

        let root_id = root.span_id();
        let child1_id = child1.span_id();
        let trace_id = root.trace_id();

        // All spans share same trace ID
        assert_eq!(root.trace_id(), trace_id);
        assert_eq!(child1.trace_id(), trace_id);
        assert_eq!(child2.trace_id(), trace_id);
        assert_eq!(grandchild.trace_id(), trace_id);

        // Parent-child relationships correct
        assert_eq!(child1.parent_span_id(), Some(root_id));
        assert_eq!(child2.parent_span_id(), Some(root_id));
        assert_eq!(grandchild.parent_span_id(), Some(child1_id));
    }

    #[test]
    fn test_propagation_header_root_span() {
        let root = SpanContext::root();
        let header = root.to_propagation_header();

        // Root span header should not contain parent span ID
        let parts: Vec<&str> = header.split(':').collect();
        assert_eq!(parts.len(), 2);
    }

    #[test]
    fn test_propagation_header_child_span() {
        let root = SpanContext::root();
        let child = root.child_span();
        let header = child.to_propagation_header();

        // Child span header should contain parent span ID
        let parts: Vec<&str> = header.split(':').collect();
        assert_eq!(parts.len(), 3);
    }

    #[test]
    fn test_propagation_header_roundtrip_root() {
        let root = SpanContext::root();
        let header = root.to_propagation_header();

        let restored = SpanContext::from_propagation_header(&header);
        assert!(restored.is_some());

        let restored = restored.unwrap();
        assert_eq!(restored.span_id(), root.span_id());
        assert_eq!(restored.trace_id(), root.trace_id());
        assert_eq!(restored.parent_span_id(), root.parent_span_id());
    }

    #[test]
    fn test_propagation_header_roundtrip_child() {
        let root = SpanContext::root();
        let child = root.child_span();
        let header = child.to_propagation_header();

        let restored = SpanContext::from_propagation_header(&header);
        assert!(restored.is_some());

        let restored = restored.unwrap();
        assert_eq!(restored.span_id(), child.span_id());
        assert_eq!(restored.trace_id(), child.trace_id());
        assert_eq!(restored.parent_span_id(), child.parent_span_id());
    }

    #[test]
    fn test_span_context_builder() {
        let trace_id = TraceId::new();
        let span_id = SpanId::new();
        let parent_id = SpanId::new();

        let ctx = SpanContextBuilder::new()
            .with_span_id(span_id)
            .with_trace_id(trace_id.clone())
            .with_parent_span_id(parent_id)
            .build();

        assert_eq!(ctx.span_id(), span_id);
        assert_eq!(ctx.trace_id(), trace_id);
        assert_eq!(ctx.parent_span_id(), Some(parent_id));
    }

    #[test]
    fn test_thread_local_span_context() {
        clear_current_span();
        assert!(current_span().is_none());

        let root = SpanContext::root();
        let root_id = root.span_id();

        set_current_span(root);

        let retrieved = current_span();
        assert!(retrieved.is_some());
        assert_eq!(retrieved.unwrap().span_id(), root_id);
    }

    #[test]
    fn test_thread_local_span_context_child() {
        clear_current_span();

        let root = SpanContext::root();
        let root_id = root.span_id();

        set_current_span(root);

        // Get current span and create child
        let current = current_span().unwrap();
        let child = current.child_span();

        assert_eq!(child.parent_span_id(), Some(root_id));
    }

    #[test]
    fn test_span_id_display_and_parsing() {
        let span_id = SpanId::new();
        let display = format!("{}", span_id);

        // Should be able to parse back the same ID
        let parsed: SpanId = display.parse().unwrap();
        assert_eq!(parsed, span_id);
    }

    #[test]
    fn test_invalid_propagation_header() {
        // Invalid headers should return None
        assert!(SpanContext::from_propagation_header("").is_none());
        assert!(SpanContext::from_propagation_header("only-one-part").is_none());
        assert!(SpanContext::from_propagation_header("invalid:hex:values:too:many").is_none());
    }
}
