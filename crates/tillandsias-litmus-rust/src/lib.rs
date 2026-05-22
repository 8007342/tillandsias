//! @trace spec:spec-traceability
//!
//! Rust-aware source relevance checks for litmus tests.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use quote::ToTokens;
use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
struct LitmusDocument {
    #[serde(default)]
    rust_queries: Vec<RustQuery>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RustQuery {
    pub id: String,
    #[serde(default)]
    pub spec: Option<String>,
    #[serde(default)]
    pub processor: Option<Processor>,
    pub file: PathBuf,
    pub method: String,
    #[serde(default)]
    pub param: Option<String>,
    #[serde(default, rename = "type")]
    pub type_: Option<String>,
    #[serde(default)]
    pub usage: Option<UsageSpec>,
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub score: Option<String>,
    #[serde(default)]
    pub name_quality: Option<NameQualityPolicy>,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Processor {
    #[default]
    Syn,
    TreeSitter,
    RustAnalyzer,
}

impl fmt::Display for Processor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let value = match self {
            Processor::Syn => "syn",
            Processor::TreeSitter => "tree_sitter",
            Processor::RustAnalyzer => "rust_analyzer",
        };
        f.write_str(value)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum UsageSpec {
    Scalar(String),
    Detailed {
        kind: UsageKind,
        #[serde(default)]
        text: Option<String>,
        #[serde(default)]
        call: Option<String>,
        #[serde(default)]
        arg: Option<String>,
    },
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum UsageKind {
    ParamUsed,
    Contains,
    Calls,
    PassedToCall,
    DoesNotContain,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NameQualityPolicy {
    Warn,
    Required,
    Off,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct QueryResult {
    pub id: String,
    pub processor: Processor,
    pub status: QueryStatus,
    pub reason: String,
    pub spec: Option<String>,
    pub score: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "UPPERCASE")]
pub enum QueryStatus {
    Pass,
    Fail,
    Warn,
}

struct FunctionView {
    name: String,
    params: Vec<ParamView>,
    body_tokens: String,
}

struct ParamView {
    name: String,
    type_tokens: String,
}

pub fn run_cli(args: Vec<String>) -> Result<String, String> {
    let Some(command) = args.first().map(String::as_str) else {
        return Err(usage());
    };

    match command {
        "check" => {
            let mut litmus_path = None;
            let mut json = false;
            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--litmus" if i + 1 < args.len() => {
                        litmus_path = Some(PathBuf::from(&args[i + 1]));
                        i += 2;
                    }
                    "--json" => {
                        json = true;
                        i += 1;
                    }
                    _ => return Err(usage()),
                }
            }
            let Some(litmus_path) = litmus_path else {
                return Err(usage());
            };
            let results = check_litmus_file(&litmus_path)?;
            let has_failure = results.iter().any(|r| r.status == QueryStatus::Fail);
            let output = if json {
                serde_json::to_string_pretty(&results).map_err(|err| err.to_string())? + "\n"
            } else {
                format_results(&results)
            };
            if has_failure { Err(output) } else { Ok(output) }
        }
        _ => Err(usage()),
    }
}

fn usage() -> String {
    "usage: tillandsias-litmus-rust check --litmus <path> [--json]".to_string()
}

pub fn check_litmus_file(path: &Path) -> Result<Vec<QueryResult>, String> {
    let text = fs::read_to_string(path)
        .map_err(|err| format!("failed to read litmus file {}: {err}", path.display()))?;
    let doc: LitmusDocument = serde_yaml::from_str(&text)
        .map_err(|err| format!("failed to parse litmus YAML {}: {err}", path.display()))?;
    let root = path
        .parent()
        .and_then(Path::parent)
        .unwrap_or_else(|| Path::new("."));
    let repo_root = root.parent().unwrap_or(root);

    let mut results = Vec::new();
    for query in doc.rust_queries {
        results.extend(check_query(repo_root, &query));
    }
    Ok(results)
}

pub fn check_query(repo_root: &Path, query: &RustQuery) -> Vec<QueryResult> {
    let processor = query.processor.unwrap_or_default();
    let file_path = repo_root.join(&query.file);
    let mut results = Vec::new();

    let source = match fs::read_to_string(&file_path) {
        Ok(source) => source,
        Err(err) => {
            results.push(failed_result(
                query,
                processor,
                format!("source_file_unreadable:{}:{err}", file_path.display()),
            ));
            return results;
        }
    };

    if processor == Processor::TreeSitter {
        match parse_with_tree_sitter(&source) {
            Ok(()) => {}
            Err(reason) => {
                results.push(failed_result(query, processor, reason));
                return results;
            }
        }
    }

    if processor == Processor::RustAnalyzer {
        match rust_analyzer_version() {
            Ok(_) => {}
            Err(reason) => {
                results.push(failed_result(query, processor, reason));
                return results;
            }
        }
    }

    let functions = match parse_functions(&source) {
        Ok(functions) => functions,
        Err(reason) => {
            results.push(failed_result(query, processor, reason));
            return results;
        }
    };

    let Some(function) = functions.iter().find(|f| f.name == query.method) else {
        results.push(failed_result(
            query,
            processor,
            format!("wrong_method_match:missing_method:{}", query.method),
        ));
        return results;
    };

    let param = match query.param.as_deref() {
        Some(expected_param) => match function.params.iter().find(|p| p.name == expected_param) {
            Some(param) => Some(param),
            None => {
                results.push(failed_result(
                    query,
                    processor,
                    format!("missing_required_param:{expected_param}"),
                ));
                return results;
            }
        },
        None => None,
    };

    if let (Some(expected_type), Some(param)) = (query.type_.as_deref(), param)
        && normalize_type(&param.type_tokens) != normalize_type(expected_type)
    {
        results.push(failed_result(
            query,
            processor,
            format!(
                "wrong_param_type:{}:expected={}:actual={}",
                param.name, expected_type, param.type_tokens
            ),
        ));
        return results;
    }

    if let Some(param) = param {
        let policy = query.name_quality.unwrap_or(NameQualityPolicy::Warn);
        if policy != NameQualityPolicy::Off && !is_meaningful_name(&param.name) {
            let status = if policy == NameQualityPolicy::Required {
                QueryStatus::Fail
            } else {
                QueryStatus::Warn
            };
            results.push(result(
                query,
                processor,
                status,
                format!("meaningless_param_name:{}", param.name),
            ));
            if status == QueryStatus::Fail {
                return results;
            }
        }
    }

    if let Some(usage) = &query.usage
        && let Err(reason) = check_usage(usage, function, param.map(|p| p.name.as_str()))
    {
        results.push(failed_result(query, processor, reason));
        return results;
    }

    results.push(result(
        query,
        processor,
        QueryStatus::Pass,
        "matched".to_string(),
    ));
    results
}

fn result(
    query: &RustQuery,
    processor: Processor,
    status: QueryStatus,
    reason: String,
) -> QueryResult {
    QueryResult {
        id: query.id.clone(),
        processor,
        status,
        reason,
        spec: query.spec.clone(),
        score: query.score.clone(),
    }
}

fn failed_result(query: &RustQuery, processor: Processor, reason: String) -> QueryResult {
    let status = if query.required {
        QueryStatus::Fail
    } else {
        QueryStatus::Warn
    };
    result(query, processor, status, reason)
}

fn parse_with_tree_sitter(source: &str) -> Result<(), String> {
    let mut parser = tree_sitter::Parser::new();
    let language: tree_sitter::Language = tree_sitter_rust::LANGUAGE.into();
    parser
        .set_language(&language)
        .map_err(|err| format!("tree_sitter_language_unavailable:{err}"))?;
    let tree = parser
        .parse(source, None)
        .ok_or_else(|| "tree_sitter_parse_failed".to_string())?;
    if tree.root_node().has_error() {
        return Err("tree_sitter_parse_error".to_string());
    }
    Ok(())
}

fn rust_analyzer_version() -> Result<String, String> {
    let output = Command::new("rust-analyzer")
        .arg("--version")
        .output()
        .map_err(|err| format!("processor_unavailable:rust_analyzer:{err}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(format!("processor_unavailable:rust_analyzer:{stderr}"));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn parse_functions(source: &str) -> Result<Vec<FunctionView>, String> {
    let file = syn::parse_file(source).map_err(|err| format!("rust_parse_error:{err}"))?;
    let mut functions = Vec::new();

    for item in file.items {
        match item {
            syn::Item::Fn(func) => functions.push(function_from_item_fn(&func)),
            syn::Item::Impl(impl_block) => {
                for item in impl_block.items {
                    if let syn::ImplItem::Fn(func) = item {
                        functions.push(function_from_impl_fn(&func));
                    }
                }
            }
            syn::Item::Mod(module) => {
                if let Some((_, items)) = module.content {
                    collect_module_functions(items, &mut functions);
                }
            }
            _ => {}
        }
    }

    Ok(functions)
}

fn collect_module_functions(items: Vec<syn::Item>, functions: &mut Vec<FunctionView>) {
    for item in items {
        match item {
            syn::Item::Fn(func) => functions.push(function_from_item_fn(&func)),
            syn::Item::Impl(impl_block) => {
                for item in impl_block.items {
                    if let syn::ImplItem::Fn(func) = item {
                        functions.push(function_from_impl_fn(&func));
                    }
                }
            }
            syn::Item::Mod(module) => {
                if let Some((_, items)) = module.content {
                    collect_module_functions(items, functions);
                }
            }
            _ => {}
        }
    }
}

fn function_from_item_fn(func: &syn::ItemFn) -> FunctionView {
    FunctionView {
        name: func.sig.ident.to_string(),
        params: params_from_signature(&func.sig),
        body_tokens: func.block.to_token_stream().to_string(),
    }
}

fn function_from_impl_fn(func: &syn::ImplItemFn) -> FunctionView {
    FunctionView {
        name: func.sig.ident.to_string(),
        params: params_from_signature(&func.sig),
        body_tokens: func.block.to_token_stream().to_string(),
    }
}

fn params_from_signature(sig: &syn::Signature) -> Vec<ParamView> {
    sig.inputs
        .iter()
        .filter_map(|arg| match arg {
            syn::FnArg::Receiver(_) => None,
            syn::FnArg::Typed(typed) => param_from_pat_type(typed),
        })
        .collect()
}

fn param_from_pat_type(typed: &syn::PatType) -> Option<ParamView> {
    let name = match typed.pat.as_ref() {
        syn::Pat::Ident(ident) => ident.ident.to_string(),
        syn::Pat::Reference(reference) => match reference.pat.as_ref() {
            syn::Pat::Ident(ident) => ident.ident.to_string(),
            _ => return None,
        },
        _ => return None,
    };
    Some(ParamView {
        name,
        type_tokens: typed.ty.to_token_stream().to_string(),
    })
}

fn check_usage(
    usage: &UsageSpec,
    function: &FunctionView,
    param_name: Option<&str>,
) -> Result<(), String> {
    match usage {
        UsageSpec::Scalar(value) => check_scalar_usage(value, function, param_name),
        UsageSpec::Detailed {
            kind,
            text,
            call,
            arg,
        } => match kind {
            UsageKind::ParamUsed => {
                let param = arg.as_deref().or(param_name).ok_or_else(|| {
                    "param_unused:no_param_declared_for_param_used_query".to_string()
                })?;
                if token_contains_ident(&function.body_tokens, param) {
                    Ok(())
                } else {
                    Err(format!("param_unused:{param}"))
                }
            }
            UsageKind::Contains => {
                let text = text
                    .as_deref()
                    .ok_or_else(|| "query_ambiguous:contains_missing_text".to_string())?;
                if compact_tokens(&function.body_tokens).contains(&compact_tokens(text)) {
                    Ok(())
                } else {
                    Err(format!("usage_missing:contains:{text}"))
                }
            }
            UsageKind::DoesNotContain => {
                let text = text
                    .as_deref()
                    .ok_or_else(|| "query_ambiguous:does_not_contain_missing_text".to_string())?;
                if compact_tokens(&function.body_tokens).contains(&compact_tokens(text)) {
                    Err(format!("usage_forbidden:contains:{text}"))
                } else {
                    Ok(())
                }
            }
            UsageKind::Calls => {
                let call = call
                    .as_deref()
                    .or(text.as_deref())
                    .ok_or_else(|| "query_ambiguous:calls_missing_call".to_string())?;
                let needle = format!("{}(", compact_tokens(call));
                if compact_tokens(&function.body_tokens).contains(&needle) {
                    Ok(())
                } else {
                    Err(format!("usage_missing:calls:{call}"))
                }
            }
            UsageKind::PassedToCall => {
                let call = call
                    .as_deref()
                    .ok_or_else(|| "query_ambiguous:passed_to_call_missing_call".to_string())?;
                let arg = arg
                    .as_deref()
                    .or(param_name)
                    .ok_or_else(|| "query_ambiguous:passed_to_call_missing_arg".to_string())?;
                let body = compact_tokens(&function.body_tokens);
                let call = compact_tokens(call);
                let arg = compact_tokens(arg);
                if body.contains(&format!("{call}(")) && body.contains(&arg) {
                    Ok(())
                } else {
                    Err(format!("usage_missing:passed_to_call:{call}:{arg}"))
                }
            }
        },
    }
}

fn check_scalar_usage(
    value: &str,
    function: &FunctionView,
    param_name: Option<&str>,
) -> Result<(), String> {
    match value {
        "param_used" => {
            let param = param_name
                .ok_or_else(|| "param_unused:no_param_declared_for_param_used_query".to_string())?;
            if token_contains_ident(&function.body_tokens, param) {
                Ok(())
            } else {
                Err(format!("param_unused:{param}"))
            }
        }
        other if other.starts_with("contains:") => {
            let text = other.trim_start_matches("contains:");
            if compact_tokens(&function.body_tokens).contains(&compact_tokens(text)) {
                Ok(())
            } else {
                Err(format!("usage_missing:contains:{text}"))
            }
        }
        other => Err(format!("query_ambiguous:unknown_usage:{other}")),
    }
}

fn token_contains_ident(tokens: &str, ident: &str) -> bool {
    let pattern = format!(
        r"(^|[^A-Za-z0-9_]){}([^A-Za-z0-9_]|$)",
        regex::escape(ident)
    );
    Regex::new(&pattern)
        .map(|re| re.is_match(tokens))
        .unwrap_or(false)
}

fn compact_tokens(value: &str) -> String {
    value.chars().filter(|ch| !ch.is_whitespace()).collect()
}

fn normalize_type(value: &str) -> String {
    compact_tokens(value)
}

fn is_meaningful_name(name: &str) -> bool {
    let normalized = name.trim_start_matches('_');
    if normalized.len() < 3 {
        return false;
    }
    if !normalized.chars().any(|ch| ch.is_ascii_alphabetic()) {
        return false;
    }
    !matches!(
        normalized,
        "arg"
            | "args"
            | "bar"
            | "baz"
            | "data"
            | "foo"
            | "item"
            | "param"
            | "parameter"
            | "temp"
            | "thing"
            | "tmp"
            | "val"
            | "value"
    )
}

fn format_results(results: &[QueryResult]) -> String {
    let mut out = String::new();
    for result in results {
        let status = match result.status {
            QueryStatus::Pass => "PASS",
            QueryStatus::Fail => "FAIL",
            QueryStatus::Warn => "WARN",
        };
        out.push_str(&format!(
            "RUST_QUERY {status} id={} processor={} reason={}",
            result.id, result.processor, result.reason
        ));
        if let Some(score) = &result.score {
            out.push_str(&format!(" score={score}"));
        }
        if let Some(spec) = &result.spec {
            out.push_str(&format!(" spec={spec}"));
        }
        out.push('\n');
        if result.status == QueryStatus::Fail
            && let Some(spec) = &result.spec
        {
            out.push_str(&format!("@trace spec:{spec}\n"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query(processor: Processor, param: &str, usage: Option<UsageSpec>) -> RustQuery {
        RustQuery {
            id: "test.query@v1".to_string(),
            spec: Some("spec-traceability".to_string()),
            processor: Some(processor),
            file: PathBuf::from("unused.rs"),
            method: "launch".to_string(),
            param: Some(param.to_string()),
            type_: Some("bool".to_string()),
            usage,
            required: true,
            score: Some("rust_signature_match".to_string()),
            name_quality: Some(NameQualityPolicy::Required),
        }
    }

    fn check_source(source: &str, query: &RustQuery) -> Vec<QueryResult> {
        let functions = parse_functions(source).unwrap();
        let function = functions.iter().find(|f| f.name == query.method).unwrap();
        let param = query
            .param
            .as_deref()
            .and_then(|name| function.params.iter().find(|p| p.name == name));
        let mut results = Vec::new();
        if let Some(expected_type) = query.type_.as_deref() {
            let param = param.unwrap();
            if normalize_type(&param.type_tokens) != normalize_type(expected_type) {
                results.push(result(
                    query,
                    query.processor.unwrap(),
                    QueryStatus::Fail,
                    "wrong_type".to_string(),
                ));
                return results;
            }
        }
        if let Some(usage) = &query.usage
            && let Err(reason) = check_usage(usage, function, param.map(|p| p.name.as_str()))
        {
            results.push(result(
                query,
                query.processor.unwrap(),
                QueryStatus::Fail,
                reason,
            ));
            return results;
        }
        results.push(result(
            query,
            query.processor.unwrap(),
            QueryStatus::Pass,
            "matched".to_string(),
        ));
        results
    }

    #[test]
    fn syn_signature_accepts_required_param_and_type() {
        let source = r#"
            fn launch(debug: bool) -> Result<(), String> {
                if debug { eprintln!("debug"); }
                Ok(())
            }
        "#;
        let results = check_source(
            source,
            &query(
                Processor::Syn,
                "debug",
                Some(UsageSpec::Scalar("param_used".to_string())),
            ),
        );
        assert_eq!(results[0].status, QueryStatus::Pass);
    }

    #[test]
    fn missing_usage_fails_param_used_query() {
        let source = r#"
            fn launch(debug: bool) -> Result<(), String> {
                Ok(())
            }
        "#;
        let results = check_source(
            source,
            &query(
                Processor::Syn,
                "debug",
                Some(UsageSpec::Scalar("param_used".to_string())),
            ),
        );
        assert_eq!(results[0].status, QueryStatus::Fail);
        assert_eq!(results[0].reason, "param_unused:debug");
    }

    #[test]
    fn tree_sitter_processor_parses_rust_and_accepts_body_contains_query() {
        let source = r#"
            fn launch(debug: bool) -> Result<(), String> {
                let client = PodmanClient::new();
                client.run(debug)
            }
        "#;
        parse_with_tree_sitter(source).unwrap();
        let results = check_source(
            source,
            &query(
                Processor::TreeSitter,
                "debug",
                Some(UsageSpec::Detailed {
                    kind: UsageKind::Contains,
                    text: Some("PodmanClient::new()".to_string()),
                    call: None,
                    arg: None,
                }),
            ),
        );
        assert_eq!(results[0].status, QueryStatus::Pass);
    }

    #[test]
    fn meaningless_param_name_is_detected() {
        assert!(!is_meaningful_name("x"));
        assert!(!is_meaningful_name("param"));
        assert!(is_meaningful_name("project_path"));
    }
}
