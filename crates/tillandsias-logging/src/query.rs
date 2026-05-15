// @trace spec:structured-query-language
//! Loki-style structured log query language for trace index.
//!
//! Provides query parser and executor for filtering, aggregating, and analyzing logs.
//!
//! # Query Syntax
//!
//! ## Filters (Label Matching)
//! ```text
//! {spec="browser-isolation"}           # Match spec label
//! {level="error"}                      # Match log level
//! {component="proxy"}                  # Match component
//! {spec="browser-isolation", level="warn"}  # Multiple filters (AND)
//! ```
//!
//! ## Pipes (Operations)
//! ```text
//! {spec="browser-isolation"} | count   # Count matching entries
//! {level="error"} | stats count() by spec  # Stats with grouping
//! {container="proxy"} | json           # Parse context as JSON
//! {spec="foo"} | json | .latency_ms > 100  # JSON filtering
//! ```
//!
//! ## Aggregations
//! - `count` — Count all matching entries
//! - `stats count() by <field>` — Group and count by field
//! - `stats avg(<field>) by <group>` — Average values
//! - `stats sum(<field>) by <group>` — Sum values
//! - `stats max(<field>) by <group>` — Maximum value
//! - `stats min(<field>) by <group>` — Minimum value

use serde_json::{Value, json};
use std::collections::HashMap;

/// Parsed query filter with label matchers
#[derive(Debug, Clone, PartialEq)]
pub struct Filter {
    /// Label-value pairs to match (e.g., {"spec": "browser-isolation", "level": "error"})
    pub matchers: HashMap<String, String>,
}

/// Aggregation operation
#[derive(Debug, Clone, PartialEq)]
pub enum AggregationOp {
    /// Count all entries
    Count,
    /// Count grouped by field
    CountBy(String),
    /// Average of field grouped by key
    AvgBy(String, String),
    /// Sum of field grouped by key
    SumBy(String, String),
    /// Max of field grouped by key
    MaxBy(String, String),
    /// Min of field grouped by key
    MinBy(String, String),
}

/// JSON filtering expression
#[derive(Debug, Clone, PartialEq)]
pub enum JsonFilter {
    /// Field comparison: .latency_ms > 100
    Greater(String, f64),
    /// Field comparison: .latency_ms < 100
    Less(String, f64),
    /// Field comparison: .latency_ms == 100
    Equal(String, f64),
    /// Field contains substring: .message contains "error"
    Contains(String, String),
}

/// Parsed query with filters, transformations, and aggregations
#[derive(Debug, Clone, PartialEq)]
pub struct Query {
    /// Label matchers for filtering
    pub filter: Filter,
    /// Optional JSON context filtering
    pub json_filters: Vec<JsonFilter>,
    /// Optional aggregation operation
    pub aggregation: Option<AggregationOp>,
}

/// Query parsing error
#[derive(Debug, Clone, PartialEq)]
pub enum ParseError {
    InvalidSyntax(String),
    MissingFilter,
    InvalidFilter(String),
    InvalidAggregation(String),
    InvalidJsonFilter(String),
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ParseError::InvalidSyntax(s) => write!(f, "Invalid syntax: {}", s),
            ParseError::MissingFilter => write!(f, "Query must start with filter {{...}}"),
            ParseError::InvalidFilter(s) => write!(f, "Invalid filter: {}", s),
            ParseError::InvalidAggregation(s) => write!(f, "Invalid aggregation: {}", s),
            ParseError::InvalidJsonFilter(s) => write!(f, "Invalid JSON filter: {}", s),
        }
    }
}

/// Parse a query string into a structured Query
pub fn parse(query_str: &str) -> Result<Query, ParseError> {
    let query_str = query_str.trim();

    // Step 1: Extract filter {spec="value", ...}
    if !query_str.starts_with('{') {
        return Err(ParseError::MissingFilter);
    }

    let close_brace = query_str.find('}').ok_or(ParseError::InvalidFilter(
        "Missing closing brace".to_string(),
    ))?;

    let filter_str = &query_str[1..close_brace];
    let filter = parse_filter(filter_str)?;

    let rest = query_str[close_brace + 1..].trim();

    // Step 2: Parse pipe operations
    let mut json_filters = Vec::new();
    let mut aggregation = None;

    let mut remaining = rest;
    while !remaining.is_empty() {
        if remaining.starts_with('|') {
            remaining = remaining[1..].trim();

            // Parse operation
            if remaining.starts_with("json") {
                remaining = remaining[4..].trim();
                // After json, we might have filters
                while remaining.starts_with('|') {
                    remaining = remaining[1..].trim();
                    if let Some((filter, new_remaining)) = try_parse_json_filter(remaining) {
                        json_filters.push(filter);
                        remaining = new_remaining;
                    } else {
                        break;
                    }
                }
            } else if remaining.starts_with("count") {
                remaining = remaining[5..].trim();
                aggregation = Some(AggregationOp::Count);
            } else if remaining.starts_with("stats") {
                let (agg, new_remaining) = parse_stats(remaining)?;
                aggregation = Some(agg);
                remaining = new_remaining;
            } else {
                return Err(ParseError::InvalidAggregation(format!(
                    "Unknown operation: {}",
                    remaining.split_whitespace().next().unwrap_or("?")
                )));
            }
        } else {
            return Err(ParseError::InvalidSyntax(format!(
                "Expected pipe or end, got: {}",
                remaining
            )));
        }
    }

    Ok(Query {
        filter,
        json_filters,
        aggregation,
    })
}

/// Parse label matchers: spec="value", level="error"
fn parse_filter(filter_str: &str) -> Result<Filter, ParseError> {
    let mut matchers = HashMap::new();

    if filter_str.is_empty() {
        return Ok(Filter { matchers });
    }

    for pair in filter_str.split(',') {
        let pair = pair.trim();
        let (key, value) = pair
            .split_once('=')
            .ok_or(ParseError::InvalidFilter(format!(
                "Expected key=value, got: {}",
                pair
            )))?;

        let key = key.trim();
        let value = value.trim();

        // Remove quotes
        let value = if (value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\''))
        {
            &value[1..value.len() - 1]
        } else {
            value
        };

        matchers.insert(key.to_string(), value.to_string());
    }

    Ok(Filter { matchers })
}

/// Try to parse a JSON filter like .latency_ms > 100
fn try_parse_json_filter(input: &str) -> Option<(JsonFilter, &str)> {
    if !input.starts_with('.') {
        return None;
    }

    // Find the field name
    let mut i = 1;
    while i < input.len()
        && (input[i..].chars().next().unwrap().is_alphanumeric() || input[i..].starts_with('_'))
    {
        i += 1;
    }

    let field = &input[1..i];
    let mut remaining = input[i..].trim_start();

    // Check for operator
    if remaining.starts_with('>') {
        remaining = remaining[1..].trim_start();
        if let Some((num, rest)) = parse_number(remaining) {
            let field_name = format!(".{}", field);
            return Some((JsonFilter::Greater(field_name, num), rest));
        }
    } else if remaining.starts_with('<') {
        remaining = remaining[1..].trim_start();
        if let Some((num, rest)) = parse_number(remaining) {
            let field_name = format!(".{}", field);
            return Some((JsonFilter::Less(field_name, num), rest));
        }
    } else if remaining.starts_with("==") {
        remaining = remaining[2..].trim_start();
        if let Some((num, rest)) = parse_number(remaining) {
            let field_name = format!(".{}", field);
            return Some((JsonFilter::Equal(field_name, num), rest));
        }
    } else if remaining.starts_with("contains") {
        remaining = remaining[8..].trim_start();
        if let Some((s, rest)) = parse_string(remaining) {
            let field_name = format!(".{}", field);
            return Some((JsonFilter::Contains(field_name, s), rest));
        }
    }

    None
}

/// Parse a number from the input, returning (number, remaining)
fn parse_number(input: &str) -> Option<(f64, &str)> {
    let mut i = 0;
    let chars: Vec<char> = input.chars().collect();

    // Handle negative
    if i < chars.len() && chars[i] == '-' {
        i += 1;
    }

    // Parse digits
    let start = i;
    while i < chars.len() && chars[i].is_ascii_digit() {
        i += 1;
    }

    // Parse decimal
    if i < chars.len() && chars[i] == '.' {
        i += 1;
        while i < chars.len() && chars[i].is_ascii_digit() {
            i += 1;
        }
    }

    if i > start || (i > 0 && chars[i - 1] != '.') {
        let num_str = input[..i].parse::<f64>().ok()?;
        return Some((num_str, input[i..].trim_start()));
    }

    None
}

/// Parse a quoted string
fn parse_string(input: &str) -> Option<(String, &str)> {
    if !input.starts_with('"') {
        return None;
    }

    let mut i = 1;
    let chars: Vec<char> = input.chars().collect();

    while i < chars.len() && chars[i] != '"' {
        i += 1;
    }

    if i >= chars.len() {
        return None;
    }

    let s = input[1..i].to_string();
    Some((s, input[i + 1..].trim_start()))
}

/// Parse stats aggregation
fn parse_stats(input: &str) -> Result<(AggregationOp, &str), ParseError> {
    if !input.starts_with("stats") {
        return Err(ParseError::InvalidAggregation("Expected stats".to_string()));
    }

    let mut remaining = input[5..].trim_start();

    // Parse aggregation function
    if remaining.starts_with("count()") {
        remaining = remaining[7..].trim_start();

        if remaining.starts_with("by") {
            remaining = remaining[2..].trim_start();
            // Parse field name
            let mut field_end = 0;
            for ch in remaining.chars() {
                if ch.is_alphanumeric() || ch == '_' {
                    field_end += 1;
                } else {
                    break;
                }
            }

            if field_end == 0 {
                return Err(ParseError::InvalidAggregation(
                    "Expected field name after 'by'".to_string(),
                ));
            }

            let field = remaining[..field_end].to_string();
            let new_remaining = remaining[field_end..].trim_start();

            return Ok((AggregationOp::CountBy(field), new_remaining));
        }

        return Ok((AggregationOp::Count, remaining));
    }

    // Parse other functions: avg, sum, max, min
    let (func_name, func_remaining) = extract_function_name(remaining)?;
    remaining = func_remaining;

    if !remaining.starts_with('(') {
        return Err(ParseError::InvalidAggregation(format!(
            "Expected '(' after {}",
            func_name
        )));
    }

    remaining = remaining[1..].trim_start();
    let close_paren = remaining.find(')').ok_or(ParseError::InvalidAggregation(
        "Missing closing paren".to_string(),
    ))?;

    let field_arg = remaining[..close_paren].trim().to_string();
    remaining = remaining[close_paren + 1..].trim_start();

    if !remaining.starts_with("by") {
        return Err(ParseError::InvalidAggregation(
            "Expected 'by' clause".to_string(),
        ));
    }

    remaining = remaining[2..].trim_start();
    let mut group_end = 0;
    for ch in remaining.chars() {
        if ch.is_alphanumeric() || ch == '_' {
            group_end += 1;
        } else {
            break;
        }
    }

    if group_end == 0 {
        return Err(ParseError::InvalidAggregation(
            "Expected field name after 'by'".to_string(),
        ));
    }

    let group_field = remaining[..group_end].to_string();
    remaining = remaining[group_end..].trim_start();

    let agg = match func_name.as_str() {
        "avg" => AggregationOp::AvgBy(field_arg, group_field),
        "sum" => AggregationOp::SumBy(field_arg, group_field),
        "max" => AggregationOp::MaxBy(field_arg, group_field),
        "min" => AggregationOp::MinBy(field_arg, group_field),
        _ => {
            return Err(ParseError::InvalidAggregation(format!(
                "Unknown function: {}",
                func_name
            )));
        }
    };

    Ok((agg, remaining))
}

/// Extract function name (avg, sum, max, min)
fn extract_function_name(input: &str) -> Result<(String, &str), ParseError> {
    let mut i = 0;
    for ch in input.chars() {
        if ch.is_alphabetic() {
            i += 1;
        } else {
            break;
        }
    }

    if i == 0 {
        return Err(ParseError::InvalidAggregation(
            "Expected function name".to_string(),
        ));
    }

    let func_name = input[..i].to_string();
    Ok((func_name, &input[i..]))
}

/// Query executor — applies filters and aggregations to log entries
pub struct QueryExecutor;

impl QueryExecutor {
    /// Check if a log entry matches the query filter
    pub fn matches_filter(entry: &Value, filter: &Filter) -> bool {
        for (key, value) in &filter.matchers {
            match entry.get(key) {
                Some(v) => {
                    if v.as_str().unwrap_or("") != value.as_str() {
                        return false;
                    }
                }
                None => return false,
            }
        }
        true
    }

    /// Check if a log entry matches all JSON filters
    pub fn matches_json_filters(context: Option<&Value>, filters: &[JsonFilter]) -> bool {
        if filters.is_empty() {
            return true;
        }

        let ctx = match context {
            Some(v) => v,
            None => return false,
        };

        for filter in filters {
            if !Self::matches_json_filter(ctx, filter) {
                return false;
            }
        }
        true
    }

    /// Check if JSON context matches a single filter
    fn matches_json_filter(context: &Value, filter: &JsonFilter) -> bool {
        match filter {
            JsonFilter::Greater(field, threshold) => {
                // field is ".latency_ms", convert to "/latency_ms" for pointer
                let ptr = format!("/{}", &field[1..]);
                context
                    .pointer(&ptr)
                    .and_then(|v| v.as_f64())
                    .map(|v| v > *threshold)
                    .unwrap_or(false)
            }
            JsonFilter::Less(field, threshold) => {
                let ptr = format!("/{}", &field[1..]);
                context
                    .pointer(&ptr)
                    .and_then(|v| v.as_f64())
                    .map(|v| v < *threshold)
                    .unwrap_or(false)
            }
            JsonFilter::Equal(field, value) => {
                let ptr = format!("/{}", &field[1..]);
                context
                    .pointer(&ptr)
                    .and_then(|v| v.as_f64())
                    .map(|v| (v - value).abs() < f64::EPSILON)
                    .unwrap_or(false)
            }
            JsonFilter::Contains(field, substr) => {
                let ptr = format!("/{}", &field[1..]);
                context
                    .pointer(&ptr)
                    .and_then(|v| v.as_str())
                    .map(|v| v.contains(substr.as_str()))
                    .unwrap_or(false)
            }
        }
    }

    /// Execute query on log entries, returning aggregated results
    pub fn execute(query: &Query, entries: Vec<Value>) -> Result<Value, String> {
        // Filter entries
        let filtered: Vec<&Value> = entries
            .iter()
            .filter(|entry| {
                Self::matches_filter(entry, &query.filter)
                    && Self::matches_json_filters(entry.get("context"), &query.json_filters)
            })
            .collect();

        // Apply aggregation or return raw count
        match &query.aggregation {
            None => {
                // No aggregation, return filtered entries
                Ok(Value::Array(filtered.into_iter().cloned().collect()))
            }
            Some(AggregationOp::Count) => Ok(json!({"count": filtered.len()})),
            Some(AggregationOp::CountBy(field)) => {
                let mut groups: HashMap<String, usize> = HashMap::new();
                for entry in &filtered {
                    let key = entry
                        .get(field)
                        .and_then(|v| v.as_str())
                        .unwrap_or("unknown")
                        .to_string();
                    *groups.entry(key).or_insert(0) += 1;
                }
                let mut result = Vec::new();
                for (key, count) in groups {
                    result.push(json!({"group": key, "count": count}));
                }
                Ok(Value::Array(result))
            }
            Some(AggregationOp::AvgBy(field_arg, group_field)) => {
                Self::aggregate_numeric(filtered, field_arg, group_field, |values| {
                    if values.is_empty() {
                        0.0
                    } else {
                        values.iter().sum::<f64>() / values.len() as f64
                    }
                })
            }
            Some(AggregationOp::SumBy(field_arg, group_field)) => {
                Self::aggregate_numeric(filtered, field_arg, group_field, |values| {
                    values.iter().sum()
                })
            }
            Some(AggregationOp::MaxBy(field_arg, group_field)) => {
                Self::aggregate_numeric(filtered, field_arg, group_field, |values| {
                    values.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
                })
            }
            Some(AggregationOp::MinBy(field_arg, group_field)) => {
                Self::aggregate_numeric(filtered, field_arg, group_field, |values| {
                    values.iter().cloned().fold(f64::INFINITY, f64::min)
                })
            }
        }
    }

    /// Aggregate numeric field by group
    fn aggregate_numeric<F>(
        entries: Vec<&Value>,
        field_arg: &str,
        group_field: &str,
        aggregator: F,
    ) -> Result<Value, String>
    where
        F: Fn(Vec<f64>) -> f64,
    {
        let mut groups: HashMap<String, Vec<f64>> = HashMap::new();

        for entry in entries {
            let group_key = entry
                .get(group_field)
                .and_then(|v| v.as_str())
                .unwrap_or("unknown")
                .to_string();

            let value = entry.get(field_arg).and_then(|v| v.as_f64()).unwrap_or(0.0);

            groups.entry(group_key).or_default().push(value);
        }

        let mut result = Vec::new();
        for (group_key, values) in groups {
            let aggregated = aggregator(values);
            result.push(json!({
                "group": group_key,
                "value": aggregated
            }));
        }

        Ok(Value::Array(result))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_filter() {
        let query = parse(r#"{spec="browser-isolation"}"#).unwrap();
        assert_eq!(
            query.filter.matchers.get("spec").unwrap(),
            "browser-isolation"
        );
        assert_eq!(query.aggregation, None);
    }

    #[test]
    fn test_parse_multiple_filters() {
        let query = parse(r#"{spec="browser-isolation", level="error"}"#).unwrap();
        assert_eq!(
            query.filter.matchers.get("spec").unwrap(),
            "browser-isolation"
        );
        assert_eq!(query.filter.matchers.get("level").unwrap(), "error");
    }

    #[test]
    fn test_parse_count_aggregation() {
        let query = parse(r#"{spec="foo"} | count"#).unwrap();
        assert_eq!(query.aggregation, Some(AggregationOp::Count));
    }

    #[test]
    fn test_parse_count_by() {
        let query = parse(r#"{level="error"} | stats count() by spec"#).unwrap();
        assert_eq!(
            query.aggregation,
            Some(AggregationOp::CountBy("spec".to_string()))
        );
    }

    #[test]
    fn test_parse_avg_by() {
        let query = parse(r#"{component="proxy"} | stats avg(latency_ms) by spec"#).unwrap();
        assert_eq!(
            query.aggregation,
            Some(AggregationOp::AvgBy(
                "latency_ms".to_string(),
                "spec".to_string()
            ))
        );
    }

    #[test]
    fn test_parse_json_filter() {
        let query = parse(r#"{container="proxy"} | json | .latency_ms > 100"#).unwrap();
        assert_eq!(query.json_filters.len(), 1);
        assert_eq!(
            query.json_filters[0],
            JsonFilter::Greater(".latency_ms".to_string(), 100.0)
        );
    }

    #[test]
    fn test_parse_json_contains() {
        let query = parse(r#"{spec="foo"} | json | .message contains "error""#).unwrap();
        assert_eq!(query.json_filters.len(), 1);
        assert!(matches!(query.json_filters[0], JsonFilter::Contains(_, _)));
    }

    #[test]
    fn test_execute_count() {
        let entries = vec![
            json!({"spec": "foo", "level": "error", "message": "test"}),
            json!({"spec": "foo", "level": "warn", "message": "test"}),
            json!({"spec": "bar", "level": "error", "message": "test"}),
        ];

        let query = parse(r#"{spec="foo"} | count"#).unwrap();
        let result = QueryExecutor::execute(&query, entries).unwrap();
        assert_eq!(result.get("count").unwrap(), 2);
    }

    #[test]
    fn test_execute_count_by() {
        let entries = vec![
            json!({"spec": "foo", "level": "error", "component": "proxy"}),
            json!({"spec": "foo", "level": "warn", "component": "git"}),
            json!({"spec": "bar", "level": "error", "component": "proxy"}),
        ];

        let query = parse(r#"{spec="foo"} | stats count() by component"#).unwrap();
        let result = QueryExecutor::execute(&query, entries).unwrap();

        assert!(result.is_array());
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 2);
    }

    #[test]
    fn test_json_filter_execution() {
        let entries = vec![
            json!({
                "spec": "proxy",
                "context": {"latency_ms": 150}
            }),
            json!({
                "spec": "proxy",
                "context": {"latency_ms": 50}
            }),
        ];

        let query = parse(r#"{spec="proxy"} | json | .latency_ms > 100"#).unwrap();
        let result = QueryExecutor::execute(&query, entries).unwrap();

        assert!(result.is_array());
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
    }

    #[test]
    fn test_error_missing_filter() {
        assert_eq!(parse("count"), Err(ParseError::MissingFilter));
    }

    #[test]
    fn test_error_unclosed_brace() {
        assert!(parse(r#"{spec="foo""#).is_err());
    }

    #[test]
    fn test_parse_sum_by() {
        let query = parse(r#"{component="proxy"} | stats sum(requests) by spec"#).unwrap();
        assert_eq!(
            query.aggregation,
            Some(AggregationOp::SumBy(
                "requests".to_string(),
                "spec".to_string()
            ))
        );
    }
}
