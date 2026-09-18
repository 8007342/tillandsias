// @trace order:1252-r72q, spec:fail-loud-diagnosis
//
// bash_hazards.rs — a tree-sitter-bash lint for the four MEASURED composition
// hazards, ADVISORY TIER.
//
// WHY A PARSER AND NOT grep. shellcheck is absent on the hosts AND inside the
// tillandsias-builder toolbox (verified on macuahuitl when 1252-r72q was filed,
// and again on lenovinha), so a shellcheck gate would pass where it happens to
// be installed and skip silently everywhere else. tree-sitter-bash vendors into
// this crate, which ALREADY depends on tree-sitter 0.25 for the rust_queries
// layer, and needs nothing on the host.
//
// WHAT THE PARSER BUYS, measured over 669 scripts against the whole-file grep
// bounds this packet recorded (195/65/27/7, all FILE counts):
//
//     shape                    bound(files)   true files   true pipelines
//     pipefail + grep -q            195           166            545
//     trailing tail -1               65            52            161
//     negated-pipeline if            27            15             22
//     pgrep/pkill -f literal          7             3              4
//
// The units differ and that is the headline: 195 counted FILES, and a file
// holds several pipelines. 166/195 of the pipefail bound is real (85%), so the
// population is mostly genuine -- but the actionable count is 545 PIPELINES,
// which makes this packet's advisory-before-gating arithmetic stronger than it
// assumed, not weaker.
//
// Against grep's 24 line-matches for the negated shape the parser corrects in
// BOTH directions: 7 are grep FALSE POSITIVES (a herestring `<<<`, or a `|`
// inside a quoted regex -- no pipeline at all) and 5 are MULTI-LINE pipelines
// grep cannot see because the `|` sits on the next line.
//
// TWO BUGS THIS FILE ALREADY PAID FOR, both the silent-underreport shape:
//   1. `if ! a | b` parses as pipeline(negated_command(a), command(b)). The `!`
//      nests INSIDE the pipeline and wraps only the FIRST stage; it is not an
//      outer negated_command, which is what the shape's English description
//      suggests. Matching the outer form found ZERO.
//   2. Redirections wrap the condition in `redirected_statement`, so matching
//      `pipeline` directly found 2 where grep found 24. See `peel`.
// Both were caught by diffing against grep rather than by reading the grammar.
// A lint that silently reports almost nothing looks exactly like a clean tree.

use tree_sitter::{Node, Parser};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Shape {
    PipefailGrepQ,
    TrailingTail1,
    NegatedPipelineIf,
    PgrepFLiteral,
}

impl Shape {
    pub fn key(self) -> &'static str {
        match self {
            Shape::PipefailGrepQ => "pipefail-grep-q",
            Shape::TrailingTail1 => "trailing-tail-1",
            Shape::NegatedPipelineIf => "negated-pipeline-if",
            Shape::PgrepFLiteral => "pgrep-f-literal",
        }
    }
    pub fn all() -> [Shape; 4] {
        [
            Shape::PipefailGrepQ,
            Shape::TrailingTail1,
            Shape::NegatedPipelineIf,
            Shape::PgrepFLiteral,
        ]
    }
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub shape: Shape,
    pub line: usize,
    pub text: String,
}

fn text<'a>(n: Node, src: &'a [u8]) -> &'a str {
    n.utf8_text(src).unwrap_or("")
}

fn cmd_name<'a>(n: Node, src: &'a [u8]) -> Option<&'a str> {
    Some(text(n.child_by_field_name("name")?, src))
}

fn named_kids<'t>(n: Node<'t>) -> Vec<Node<'t>> {
    let mut c = n.walk();
    n.named_children(&mut c).collect()
}

fn cmd_args<'a>(n: Node, src: &'a [u8]) -> Vec<&'a str> {
    named_kids(n)
        .into_iter()
        .filter(|ch| ch.kind() != "command_name")
        .map(|ch| text(ch, src))
        .collect()
}

/// Peel `redirected_statement` wrappers. `cmd 2>/dev/null | grep ...` and
/// `... | grep ... >/dev/null` both wrap the interesting node, so a check that
/// matches `pipeline` directly sees nothing.
fn peel<'t>(mut n: Node<'t>) -> Node<'t> {
    loop {
        if n.kind() != "redirected_statement" {
            return n;
        }
        match n.child_by_field_name("body").or_else(|| n.named_child(0)) {
            Some(b) if b.id() != n.id() => n = b,
            _ => return n,
        }
    }
}

/// Does this `set` command enable pipefail? A mention inside a COMMENT can
/// never reach here -- a comment is its own node and is never a `command`.
/// That is the negative control this packet asks for, and the parser gives it
/// for free rather than by a stripping pass that can itself be wrong.
fn sets_pipefail(n: Node, src: &[u8]) -> bool {
    if cmd_name(n, src) != Some("set") {
        return false;
    }
    let args = cmd_args(n, src);
    args.iter().enumerate().any(|(i, a)| {
        let next_is_pipefail = args.get(i + 1).is_some_and(|v| *v == "pipefail");
        next_is_pipefail && a.starts_with('-') && !a.starts_with("--") && a.contains('o')
    })
}

fn enclosing_function(mut n: Node) -> Option<(usize, usize)> {
    while let Some(p) = n.parent() {
        if p.kind() == "function_definition" {
            return Some((p.start_byte(), p.end_byte()));
        }
        n = p;
    }
    None
}

fn walk(root: Node, f: &mut impl FnMut(Node)) {
    let mut stack = vec![root];
    while let Some(n) = stack.pop() {
        f(n);
        stack.extend(named_kids(n));
    }
}

fn pipefail_sites(root: Node, src: &[u8]) -> Vec<(usize, Option<(usize, usize)>)> {
    let mut out = Vec::new();
    walk(root, &mut |n| {
        if n.kind() == "command" && sets_pipefail(n, src) {
            out.push((n.start_byte(), enclosing_function(n)));
        }
    });
    out
}

/// Is `node` executed with pipefail on? STATED APPROXIMATION, because exact
/// scoping is undecidable -- `set -o pipefail` is a dynamic, global runtime
/// option and a function's callers are not known statically:
///   (a) a TOP-LEVEL enable earlier in byte order, or
///   (b) a TOP-LEVEL enable anywhere when `node` is inside a function, since
///       functions run after the file's prologue, or
///   (c) an enable earlier within the SAME enclosing function.
/// What this buys over grep: a file whose pipefail is set inside ONE function
/// does not put every other function's pipelines in scope.
fn in_pipefail_scope(node: Node, sites: &[(usize, Option<(usize, usize)>)]) -> bool {
    let inside = enclosing_function(node);
    sites.iter().any(|(off, site_fn)| match site_fn {
        None => *off < node.start_byte() || inside.is_some(),
        Some(fr) => Some(*fr) == inside && *off < node.start_byte(),
    })
}

fn pipeline_tail<'t>(p: Node<'t>) -> Option<Node<'t>> {
    named_kids(p)
        .into_iter()
        .map(peel)
        .rev()
        .find(|k| k.kind() == "command")
}

fn is_grep_q(n: Node, src: &[u8]) -> bool {
    if !matches!(
        cmd_name(n, src),
        Some("grep") | Some("egrep") | Some("fgrep") | Some("zgrep")
    ) {
        return false;
    }
    cmd_args(n, src).iter().any(|a| {
        *a == "--quiet"
            || *a == "--silent"
            || (a.starts_with('-') && !a.starts_with("--") && a.contains('q'))
    })
}

fn is_tail_1(n: Node, src: &[u8]) -> bool {
    if cmd_name(n, src) != Some("tail") {
        return false;
    }
    let args = cmd_args(n, src);
    args.iter().enumerate().any(|(i, a)| {
        *a == "-1" || *a == "-n1" || (*a == "-n" && args.get(i + 1).is_some_and(|v| *v == "1"))
    })
}

fn is_pgrep_f(n: Node, src: &[u8]) -> bool {
    if !matches!(cmd_name(n, src), Some("pgrep") | Some("pkill")) {
        return false;
    }
    let args = cmd_args(n, src);
    let has_f = args
        .iter()
        .any(|a| *a == "--full" || (a.starts_with('-') && !a.starts_with("--") && a.contains('f')));
    // A LITERAL, not merely a non-flag. `pgrep -f -- "$1"` matches a pattern
    // chosen at runtime; the hazard is a HARD-CODED pattern that can match an
    // unrelated process. Counting "$1" as a literal over-reports by exactly
    // that distinction.
    let has_literal = named_kids(n).into_iter().any(|ch| {
        if ch.kind() == "command_name" || text(ch, src).starts_with('-') {
            return false;
        }
        match ch.kind() {
            "word" | "raw_string" => true,
            "string" => named_kids(ch)
                .into_iter()
                .all(|g| g.kind() == "string_content"),
            _ => false,
        }
    });
    has_f && has_literal
}

fn first_line(n: Node, src: &[u8]) -> String {
    text(n, src).lines().next().unwrap_or("").trim().to_string()
}

pub fn scan(src: &[u8]) -> Vec<Finding> {
    let mut parser = Parser::new();
    if parser
        .set_language(&tree_sitter_bash::LANGUAGE.into())
        .is_err()
    {
        return Vec::new();
    }
    let Some(tree) = parser.parse(src, None) else {
        return Vec::new();
    };
    let root = tree.root_node();
    let sites = pipefail_sites(root, src);
    let mut out: Vec<Finding> = Vec::new();

    walk(root, &mut |n| {
        let line = n.start_position().row + 1;
        match n.kind() {
            "pipeline" => {
                if let Some(t) = pipeline_tail(n) {
                    if is_grep_q(t, src) && in_pipefail_scope(n, &sites) {
                        out.push(Finding { shape: Shape::PipefailGrepQ, line, text: first_line(n, src) });
                    }
                    if is_tail_1(t, src) {
                        out.push(Finding { shape: Shape::TrailingTail1, line, text: first_line(n, src) });
                    }
                }
            }
            "if_statement" | "elif_clause" => {
                if let Some(cond) = n.named_child(0).map(peel) {
                    let hit = match cond.kind() {
                        "pipeline" => {
                            let kids: Vec<Node> = named_kids(cond).into_iter().map(peel).collect();
                            kids.len() > 1 && kids.iter().any(|k| k.kind() == "negated_command")
                        }
                        "negated_command" => cond
                            .named_child(0)
                            .map(peel)
                            .is_some_and(|i| i.kind() == "pipeline"),
                        _ => false,
                    };
                    if hit {
                        out.push(Finding { shape: Shape::NegatedPipelineIf, line, text: first_line(cond, src) });
                    }
                }
            }
            "command" if is_pgrep_f(n, src) => {
                out.push(Finding { shape: Shape::PgrepFLiteral, line, text: first_line(n, src) });
            }
            _ => {}
        }
    });

    out.sort_by_key(|f| (f.line, f.shape.key()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shapes(src: &str) -> Vec<&'static str> {
        scan(src.as_bytes()).into_iter().map(|f| f.shape.key()).collect()
    }

    #[test]
    fn comment_only_pipefail_is_not_a_hit() {
        // THE NEGATIVE CONTROL this packet names: comment-blind source scans
        // are a repeat defect here (881-29me, 885-92iu, 1251-54p3's comment arm).
        let src = "#!/usr/bin/env bash\n# mentions pipefail in prose\nset -u\ncat f | grep -q x\n";
        assert!(shapes(src).is_empty(), "comment-only pipefail must not trigger");
    }

    #[test]
    fn real_pipefail_is_a_hit() {
        let src = "set -euo pipefail\ncat f | grep -q x\n";
        assert_eq!(shapes(src), vec!["pipefail-grep-q"]);
    }

    #[test]
    fn pipefail_scope_is_per_function_not_per_file() {
        // The discrimination grep cannot make: only the function that enables
        // pipefail puts its own pipeline in scope.
        let src = "set -u\nhere() { set -o pipefail; cat f | grep -q x; }\nelsewhere() { cat f | grep -q x; }\n";
        assert_eq!(shapes(src), vec!["pipefail-grep-q"]);
    }

    #[test]
    fn negation_nests_inside_the_pipeline() {
        // `!` wraps only the FIRST stage; matching an outer negated_command
        // found zero. Regression pin for bug 1 in this file's header.
        assert_eq!(shapes("if ! a | grep -q x; then :; fi\n"), vec!["negated-pipeline-if"]);
    }

    #[test]
    fn redirections_do_not_hide_the_pipeline() {
        // Regression pin for bug 2: found 2 where grep found 24.
        assert_eq!(
            shapes("if ! a 2>/dev/null | grep -q x; then :; fi\n"),
            vec!["negated-pipeline-if"]
        );
    }

    #[test]
    fn a_negated_single_command_is_not_a_pipeline() {
        assert!(shapes("if ! a; then :; fi\n").is_empty());
    }

    #[test]
    fn herestring_is_not_a_pipeline() {
        // One of the seven grep false positives: `<<<` is not a pipe, and a
        // `|` inside the quoted regex is not one either.
        assert!(shapes("if ! grep -qE 'a|b' <<<\"$x\"; then :; fi\n").is_empty());
    }

    #[test]
    fn pgrep_needs_a_literal_not_a_variable() {
        assert_eq!(shapes("pgrep -f 'ollama serve'\n"), vec!["pgrep-f-literal"]);
        assert!(shapes("pgrep -f -- \"$1\"\n").is_empty());
    }

    #[test]
    fn trailing_tail_one_in_its_spellings() {
        assert_eq!(shapes("a | tail -1\n"), vec!["trailing-tail-1"]);
        assert_eq!(shapes("a | tail -n 1\n"), vec!["trailing-tail-1"]);
    }
}
