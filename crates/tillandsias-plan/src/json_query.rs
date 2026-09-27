//! ORDER 1375-rn9b — a jq-subset query engine over `serde_json::Value`.
//!
//! WHY: 277 bare jq call sites read JSON in gate scripts, and jq is absent on
//! macOS and Windows hosts and dynamically linked everywhere else. Every host
//! that runs a gate already has this binary. 87% of those sites use only path
//! extraction and iterate+select (buckets A and B of the design,
//! plan/issues/lua-runtime-host-dependency-replacement-design-2026-09-26.md),
//! and that subset is what this module answers, byte-identical to jq.
//!
//! WHAT IT IS NOT: a jq. Object construction, arithmetic, string
//! interpolation, `@formats`, `join`, `test`, `reduce`, `if`, bindings and
//! slices are refused with `QueryError::Unsupported` at PARSE time, so a
//! caller learns the filter is out of the subset before any input is read.
//! Those live in Lua tables (1375-btuf), not here.
//!
//! THE SURFACE (agreed with 1375-btuf, yoga, 2026-09-26): `parse` once,
//! `eval` many; `eval` returns every result as a value, and rendering (`-r`,
//! `-c`, the `-e` exit codes) belongs to the CLI verb, so the Lua side gets
//! values rather than text. `QueryError`'s Display text starts with its kind
//! token (`parse:`, `unsupported:`, `runtime:`) so callers can match on it.
//!
//! SEMANTICS FOLLOW jq, including the awkward parts: a missing key is `null`
//! (not empty); `null | .a` is `null`; `a // b` swallows errors in `a`;
//! `(f)?` keeps the outputs `f` produced before it failed; binary operators
//! take the RIGHT operand as the outer loop; `==` compares numbers by value
//! (`1 == 1.0`); ordering is null < false < true < numbers < strings <
//! arrays < objects.

use serde_json::Value;
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fmt;

/// A parsed filter. Opaque: build it with [`parse`], run it with [`eval`].
#[derive(Debug, Clone)]
pub struct Filter {
    ast: Ast,
}

impl Filter {
    /// The `$name`s the filter references, so a caller can refuse an unbound
    /// one before evaluating (jq refuses it at compile time, exit 3).
    pub fn variables(&self) -> Vec<String> {
        let mut out = Vec::new();
        self.ast.collect_vars(&mut out);
        out.sort();
        out.dedup();
        out
    }
}

#[derive(Debug)]
pub enum QueryError {
    /// Bad syntax, at a byte offset into the filter.
    Parse { at: usize, msg: String },
    /// Valid jq, outside the supported subset.
    Unsupported { construct: String },
    /// An error while evaluating (e.g. indexing a number).
    Runtime(String),
}

impl fmt::Display for QueryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            QueryError::Parse { at, msg } => write!(f, "parse:{at}: {msg}"),
            QueryError::Unsupported { construct } => write!(f, "unsupported:{construct}"),
            QueryError::Runtime(msg) => write!(f, "runtime: {msg}"),
        }
    }
}

impl std::error::Error for QueryError {}

/// Evaluation options. `args` binds `$name` (`--arg k v` binds a string,
/// `--argjson k v` a parsed value).
#[derive(Debug, Default, Clone)]
pub struct Opts {
    pub args: BTreeMap<String, Value>,
}

/// Parse a filter, refusing anything outside the subset.
pub fn parse(src: &str) -> Result<Filter, QueryError> {
    let tokens = lex(src)?;
    let mut p = Parser {
        toks: tokens,
        pos: 0,
        len: src.len(),
    };
    let ast = p.pipe()?;
    if let Some(t) = p.peek() {
        return Err(QueryError::Parse {
            at: t.at,
            msg: format!("unexpected {}", t.kind.describe()),
        });
    }
    Ok(Filter { ast })
}

/// Evaluate a filter over one input, returning every result in order.
///
/// A runtime error is returned as `Err`; results produced before it are lost
/// to this caller (use [`eval_partial`] to keep them, as the CLI does to
/// print what jq would have printed before the error).
pub fn eval(input: &Value, f: &Filter, o: &Opts) -> Result<Vec<Value>, QueryError> {
    let mut out = Vec::new();
    eval_partial(input, f, o, &mut out)?;
    Ok(out)
}

/// As [`eval`], but results produced before an error stay in `out`.
pub fn eval_partial(
    input: &Value,
    f: &Filter,
    o: &Opts,
    out: &mut Vec<Value>,
) -> Result<(), QueryError> {
    run(&f.ast, input, o, out)
}

// ---------------------------------------------------------------- lexer ----

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Dot,
    DotDot,
    Field(String),
    Ident(String),
    Var(String),
    Str(String),
    Num(f64),
    Pipe,
    Comma,
    Alt,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    LParen,
    RParen,
    LBrack,
    RBrack,
    Question,
}

impl Tok {
    fn describe(&self) -> String {
        match self {
            Tok::Dot => "'.'".into(),
            Tok::DotDot => "'..'".into(),
            Tok::Field(s) => format!("field .{s}"),
            Tok::Ident(s) => format!("'{s}'"),
            Tok::Var(s) => format!("${s}"),
            Tok::Str(_) => "string".into(),
            Tok::Num(_) => "number".into(),
            Tok::Pipe => "'|'".into(),
            Tok::Comma => "','".into(),
            Tok::Alt => "'//'".into(),
            Tok::Eq => "'=='".into(),
            Tok::Ne => "'!='".into(),
            Tok::Lt => "'<'".into(),
            Tok::Le => "'<='".into(),
            Tok::Gt => "'>'".into(),
            Tok::Ge => "'>='".into(),
            Tok::LParen => "'('".into(),
            Tok::RParen => "')'".into(),
            Tok::LBrack => "'['".into(),
            Tok::RBrack => "']'".into(),
            Tok::Question => "'?'".into(),
        }
    }
}

#[derive(Debug, Clone)]
struct Token {
    kind: Tok,
    at: usize,
}

fn unsupported(construct: impl Into<String>) -> QueryError {
    QueryError::Unsupported {
        construct: construct.into(),
    }
}

fn is_ident_start(c: char) -> bool {
    c.is_ascii_alphabetic() || c == '_'
}

fn is_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn lex(src: &str) -> Result<Vec<Token>, QueryError> {
    let chars: Vec<(usize, char)> = src.char_indices().collect();
    let mut i = 0;
    let mut out = Vec::new();
    let at_of = |i: usize| chars.get(i).map_or(src.len(), |c| c.0);
    while i < chars.len() {
        let (at, c) = chars[i];
        let next = chars.get(i + 1).map(|c| c.1);
        match c {
            ' ' | '\t' | '\n' | '\r' => i += 1,
            '#' => return Err(unsupported("comment")),
            '.' => {
                if next == Some('.') {
                    out.push(Token {
                        kind: Tok::DotDot,
                        at,
                    });
                    i += 2;
                } else if next.is_some_and(is_ident_start) {
                    let mut j = i + 1;
                    while j < chars.len() && is_ident_char(chars[j].1) {
                        j += 1;
                    }
                    let name: String = chars[i + 1..j].iter().map(|c| c.1).collect();
                    out.push(Token {
                        kind: Tok::Field(name),
                        at,
                    });
                    i = j;
                } else {
                    out.push(Token { kind: Tok::Dot, at });
                    i += 1;
                }
            }
            '$' => {
                if !next.is_some_and(is_ident_start) {
                    return Err(QueryError::Parse {
                        at,
                        msg: "expected a variable name after '$'".into(),
                    });
                }
                let mut j = i + 1;
                while j < chars.len() && is_ident_char(chars[j].1) {
                    j += 1;
                }
                let name: String = chars[i + 1..j].iter().map(|c| c.1).collect();
                if name == "__loc__" {
                    return Err(unsupported("$__loc__"));
                }
                out.push(Token {
                    kind: Tok::Var(name),
                    at,
                });
                i = j;
            }
            '"' => {
                let mut s = String::new();
                let mut j = i + 1;
                loop {
                    let Some(&(_, ch)) = chars.get(j) else {
                        return Err(QueryError::Parse {
                            at,
                            msg: "unterminated string".into(),
                        });
                    };
                    match ch {
                        '"' => break,
                        '\\' => {
                            let Some(&(_, e)) = chars.get(j + 1) else {
                                return Err(QueryError::Parse {
                                    at,
                                    msg: "unterminated escape".into(),
                                });
                            };
                            match e {
                                '"' => s.push('"'),
                                '\\' => s.push('\\'),
                                '/' => s.push('/'),
                                'b' => s.push('\u{8}'),
                                'f' => s.push('\u{c}'),
                                'n' => s.push('\n'),
                                'r' => s.push('\r'),
                                't' => s.push('\t'),
                                'u' => {
                                    let hex: String =
                                        chars.iter().skip(j + 2).take(4).map(|c| c.1).collect();
                                    let code = u32::from_str_radix(&hex, 16).map_err(|_| {
                                        QueryError::Parse {
                                            at: at_of(j),
                                            msg: "bad \\u escape".into(),
                                        }
                                    })?;
                                    let Some(ch) = char::from_u32(code) else {
                                        return Err(unsupported("surrogate \\u escape"));
                                    };
                                    s.push(ch);
                                    j += 4;
                                }
                                '(' => return Err(unsupported("string interpolation")),
                                _ => {
                                    return Err(QueryError::Parse {
                                        at: at_of(j),
                                        msg: format!("bad escape \\{e}"),
                                    });
                                }
                            }
                            j += 2;
                        }
                        _ => {
                            s.push(ch);
                            j += 1;
                        }
                    }
                }
                out.push(Token {
                    kind: Tok::Str(s),
                    at,
                });
                i = j + 1;
            }
            '0'..='9' => {
                let mut j = i;
                while j < chars.len() && (chars[j].1.is_ascii_digit() || chars[j].1 == '.') {
                    j += 1;
                }
                if j < chars.len() && (chars[j].1 == 'e' || chars[j].1 == 'E') {
                    j += 1;
                    if j < chars.len() && (chars[j].1 == '+' || chars[j].1 == '-') {
                        j += 1;
                    }
                    while j < chars.len() && chars[j].1.is_ascii_digit() {
                        j += 1;
                    }
                }
                let text: String = chars[i..j].iter().map(|c| c.1).collect();
                let n: f64 = text.parse().map_err(|_| QueryError::Parse {
                    at,
                    msg: format!("bad number {text}"),
                })?;
                out.push(Token {
                    kind: Tok::Num(n),
                    at,
                });
                i = j;
            }
            '|' => {
                if next == Some('=') {
                    return Err(unsupported("update-assignment"));
                }
                out.push(Token {
                    kind: Tok::Pipe,
                    at,
                });
                i += 1;
            }
            ',' => {
                out.push(Token {
                    kind: Tok::Comma,
                    at,
                });
                i += 1;
            }
            '/' => {
                if next == Some('/') {
                    if chars.get(i + 2).map(|c| c.1) == Some('=') {
                        return Err(unsupported("alternative-assignment"));
                    }
                    out.push(Token { kind: Tok::Alt, at });
                    i += 2;
                } else {
                    return Err(unsupported("arithmetic"));
                }
            }
            '=' => {
                if next == Some('=') {
                    out.push(Token { kind: Tok::Eq, at });
                    i += 2;
                } else {
                    return Err(unsupported("assignment"));
                }
            }
            '!' => {
                if next == Some('=') {
                    out.push(Token { kind: Tok::Ne, at });
                    i += 2;
                } else {
                    return Err(QueryError::Parse {
                        at,
                        msg: "unexpected '!'".into(),
                    });
                }
            }
            '<' => {
                if next == Some('=') {
                    out.push(Token { kind: Tok::Le, at });
                    i += 2;
                } else {
                    out.push(Token { kind: Tok::Lt, at });
                    i += 1;
                }
            }
            '>' => {
                if next == Some('=') {
                    out.push(Token { kind: Tok::Ge, at });
                    i += 2;
                } else {
                    out.push(Token { kind: Tok::Gt, at });
                    i += 1;
                }
            }
            '(' => {
                out.push(Token {
                    kind: Tok::LParen,
                    at,
                });
                i += 1;
            }
            ')' => {
                out.push(Token {
                    kind: Tok::RParen,
                    at,
                });
                i += 1;
            }
            '[' => {
                out.push(Token {
                    kind: Tok::LBrack,
                    at,
                });
                i += 1;
            }
            ']' => {
                out.push(Token {
                    kind: Tok::RBrack,
                    at,
                });
                i += 1;
            }
            '?' => {
                if next == Some('/') && chars.get(i + 2).map(|c| c.1) == Some('/') {
                    return Err(unsupported("destructuring-alternative"));
                }
                out.push(Token {
                    kind: Tok::Question,
                    at,
                });
                i += 1;
            }
            '{' | '}' => return Err(unsupported("object construction")),
            '+' | '*' | '%' => return Err(unsupported("arithmetic")),
            '-' => {
                if next.is_some_and(|c| c.is_ascii_digit()) {
                    // A negative literal: lex the number, negate it. Binary
                    // minus is arithmetic and refused below by the parser
                    // seeing a number where an operator should be.
                    let prev_is_operand = matches!(
                        out.last().map(|t: &Token| &t.kind),
                        Some(
                            Tok::Dot
                                | Tok::Field(_)
                                | Tok::Ident(_)
                                | Tok::Var(_)
                                | Tok::Str(_)
                                | Tok::Num(_)
                                | Tok::RParen
                                | Tok::RBrack
                                | Tok::Question
                        )
                    );
                    if prev_is_operand {
                        return Err(unsupported("arithmetic"));
                    }
                    let mut j = i + 1;
                    while j < chars.len() && (chars[j].1.is_ascii_digit() || chars[j].1 == '.') {
                        j += 1;
                    }
                    let text: String = chars[i..j].iter().map(|c| c.1).collect();
                    let n: f64 = text.parse().map_err(|_| QueryError::Parse {
                        at,
                        msg: format!("bad number {text}"),
                    })?;
                    out.push(Token {
                        kind: Tok::Num(n),
                        at,
                    });
                    i = j;
                } else {
                    return Err(unsupported("arithmetic"));
                }
            }
            '@' => return Err(unsupported("@format")),
            ':' => return Err(unsupported("slice")),
            ';' => return Err(unsupported("multi-argument call")),
            c if is_ident_start(c) => {
                let mut j = i;
                while j < chars.len() && (is_ident_char(chars[j].1) || chars[j].1 == ':') {
                    if chars[j].1 == ':' {
                        return Err(unsupported("module path"));
                    }
                    j += 1;
                }
                let name: String = chars[i..j].iter().map(|c| c.1).collect();
                out.push(Token {
                    kind: Tok::Ident(name),
                    at,
                });
                i = j;
            }
            other => {
                return Err(QueryError::Parse {
                    at,
                    msg: format!("unexpected character {other:?}"),
                });
            }
        }
    }
    Ok(out)
}

// ---------------------------------------------------------------- parser ---

#[derive(Debug, Clone, Copy, PartialEq)]
enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Debug, Clone)]
enum Ast {
    Identity,
    Literal(Value),
    Var(String),
    /// `target[key]`, key evaluated against the path's input.
    Index(Box<Ast>, Box<Ast>),
    Iterate(Box<Ast>),
    Try(Box<Ast>),
    Pipe(Box<Ast>, Box<Ast>),
    Comma(Box<Ast>, Box<Ast>),
    Alt(Box<Ast>, Box<Ast>),
    And(Box<Ast>, Box<Ast>),
    Or(Box<Ast>, Box<Ast>),
    Cmp(CmpOp, Box<Ast>, Box<Ast>),
    Collect(Option<Box<Ast>>),
    Call(Builtin, Option<Box<Ast>>),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Builtin {
    Select,
    Has,
    Length,
    Keys,
    KeysUnsorted,
    Type,
    Not,
    Empty,
    AsciiDowncase,
    ToString,
}

impl Ast {
    fn collect_vars(&self, out: &mut Vec<String>) {
        match self {
            Ast::Var(n) => out.push(n.clone()),
            Ast::Identity | Ast::Literal(_) => {}
            Ast::Iterate(a) | Ast::Try(a) => a.collect_vars(out),
            Ast::Collect(a) | Ast::Call(_, a) => {
                if let Some(a) = a {
                    a.collect_vars(out);
                }
            }
            Ast::Index(a, b)
            | Ast::Pipe(a, b)
            | Ast::Comma(a, b)
            | Ast::Alt(a, b)
            | Ast::And(a, b)
            | Ast::Or(a, b)
            | Ast::Cmp(_, a, b) => {
                a.collect_vars(out);
                b.collect_vars(out);
            }
        }
    }
}

struct Parser {
    toks: Vec<Token>,
    pos: usize,
    len: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.pos)
    }

    fn peek_kind(&self) -> Option<&Tok> {
        self.peek().map(|t| &t.kind)
    }

    fn at(&self) -> usize {
        self.peek().map_or(self.len, |t| t.at)
    }

    fn bump(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.pos).map(|t| t.kind.clone());
        self.pos += 1;
        t
    }

    fn expect(&mut self, want: Tok) -> Result<(), QueryError> {
        match self.peek_kind() {
            Some(k) if *k == want => {
                self.pos += 1;
                Ok(())
            }
            Some(k) => Err(QueryError::Parse {
                at: self.at(),
                msg: format!("expected {}, found {}", want.describe(), k.describe()),
            }),
            None => Err(QueryError::Parse {
                at: self.len,
                msg: format!("expected {}", want.describe()),
            }),
        }
    }

    // pipe := comma ('|' pipe)?
    fn pipe(&mut self) -> Result<Ast, QueryError> {
        if let Some(Tok::Ident(k)) = self.peek_kind()
            && k == "def"
        {
            return Err(unsupported("def"));
        }
        let lhs = self.comma()?;
        if let Some(Tok::Ident(k)) = self.peek_kind()
            && k == "as"
        {
            return Err(unsupported("variable binding"));
        }
        if self.peek_kind() == Some(&Tok::Pipe) {
            self.pos += 1;
            let rhs = self.pipe()?;
            return Ok(Ast::Pipe(Box::new(lhs), Box::new(rhs)));
        }
        Ok(lhs)
    }

    // comma := alt (',' alt)*
    fn comma(&mut self) -> Result<Ast, QueryError> {
        let mut lhs = self.alt()?;
        while self.peek_kind() == Some(&Tok::Comma) {
            self.pos += 1;
            let rhs = self.alt()?;
            lhs = Ast::Comma(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    // alt := or ('//' alt)?   (right-associative, as in jq)
    fn alt(&mut self) -> Result<Ast, QueryError> {
        let lhs = self.or()?;
        if self.peek_kind() == Some(&Tok::Alt) {
            self.pos += 1;
            let rhs = self.alt()?;
            return Ok(Ast::Alt(Box::new(lhs), Box::new(rhs)));
        }
        Ok(lhs)
    }

    fn or(&mut self) -> Result<Ast, QueryError> {
        let mut lhs = self.and()?;
        while matches!(self.peek_kind(), Some(Tok::Ident(k)) if k == "or") {
            self.pos += 1;
            let rhs = self.and()?;
            lhs = Ast::Or(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    fn and(&mut self) -> Result<Ast, QueryError> {
        let mut lhs = self.cmp()?;
        while matches!(self.peek_kind(), Some(Tok::Ident(k)) if k == "and") {
            self.pos += 1;
            let rhs = self.cmp()?;
            lhs = Ast::And(Box::new(lhs), Box::new(rhs));
        }
        Ok(lhs)
    }

    // cmp := postfix (op postfix)?   (non-associative, as in jq)
    fn cmp(&mut self) -> Result<Ast, QueryError> {
        let lhs = self.postfix()?;
        let op = match self.peek_kind() {
            Some(Tok::Eq) => CmpOp::Eq,
            Some(Tok::Ne) => CmpOp::Ne,
            Some(Tok::Lt) => CmpOp::Lt,
            Some(Tok::Le) => CmpOp::Le,
            Some(Tok::Gt) => CmpOp::Gt,
            Some(Tok::Ge) => CmpOp::Ge,
            _ => return Ok(lhs),
        };
        self.pos += 1;
        let rhs = self.postfix()?;
        if matches!(
            self.peek_kind(),
            Some(Tok::Eq | Tok::Ne | Tok::Lt | Tok::Le | Tok::Gt | Tok::Ge)
        ) {
            return Err(QueryError::Parse {
                at: self.at(),
                msg: "comparison operators do not chain".into(),
            });
        }
        Ok(Ast::Cmp(op, Box::new(lhs), Box::new(rhs)))
    }

    fn postfix(&mut self) -> Result<Ast, QueryError> {
        let mut term = self.term()?;
        loop {
            match self.peek_kind() {
                Some(Tok::Field(name)) => {
                    let name = name.clone();
                    self.pos += 1;
                    term = Ast::Index(Box::new(term), Box::new(Ast::Literal(Value::String(name))));
                }
                Some(Tok::Dot) => {
                    // `.[...]` or `."key"` after a term.
                    match self.toks.get(self.pos + 1).map(|t| &t.kind) {
                        Some(Tok::Str(s)) => {
                            let s = s.clone();
                            self.pos += 2;
                            term = Ast::Index(
                                Box::new(term),
                                Box::new(Ast::Literal(Value::String(s))),
                            );
                        }
                        Some(Tok::LBrack) => {
                            self.pos += 1;
                            term = self.bracket(term)?;
                        }
                        _ => {
                            return Err(QueryError::Parse {
                                at: self.at(),
                                msg: "unexpected '.'".into(),
                            });
                        }
                    }
                }
                Some(Tok::LBrack) => term = self.bracket(term)?,
                Some(Tok::Question) => {
                    self.pos += 1;
                    term = Ast::Try(Box::new(term));
                }
                _ => return Ok(term),
            }
        }
    }

    // After a term, at '[': `[]` iterates, `[e]` indexes.
    fn bracket(&mut self, target: Ast) -> Result<Ast, QueryError> {
        self.expect(Tok::LBrack)?;
        if self.peek_kind() == Some(&Tok::RBrack) {
            self.pos += 1;
            return Ok(Ast::Iterate(Box::new(target)));
        }
        let key = self.pipe()?;
        self.expect(Tok::RBrack)?;
        Ok(Ast::Index(Box::new(target), Box::new(key)))
    }

    fn term(&mut self) -> Result<Ast, QueryError> {
        let at = self.at();
        let Some(tok) = self.bump() else {
            return Err(QueryError::Parse {
                at: self.len,
                msg: "unexpected end of filter".into(),
            });
        };
        match tok {
            Tok::Dot => match self.peek_kind() {
                Some(Tok::Str(s)) => {
                    let s = s.clone();
                    self.pos += 1;
                    Ok(Ast::Index(
                        Box::new(Ast::Identity),
                        Box::new(Ast::Literal(Value::String(s))),
                    ))
                }
                Some(Tok::LBrack) => self.bracket(Ast::Identity),
                _ => Ok(Ast::Identity),
            },
            Tok::DotDot => Err(unsupported("recursive descent (..)")),
            Tok::Field(name) => Ok(Ast::Index(
                Box::new(Ast::Identity),
                Box::new(Ast::Literal(Value::String(name))),
            )),
            Tok::Var(name) => Ok(Ast::Var(name)),
            Tok::Str(s) => Ok(Ast::Literal(Value::String(s))),
            Tok::Num(n) => Ok(Ast::Literal(number(n))),
            Tok::LParen => {
                let inner = self.pipe()?;
                self.expect(Tok::RParen)?;
                Ok(inner)
            }
            Tok::LBrack => {
                if self.peek_kind() == Some(&Tok::RBrack) {
                    self.pos += 1;
                    return Ok(Ast::Collect(None));
                }
                let inner = self.pipe()?;
                self.expect(Tok::RBrack)?;
                Ok(Ast::Collect(Some(Box::new(inner))))
            }
            Tok::Ident(name) => self.call(&name, at),
            other => Err(QueryError::Parse {
                at,
                msg: format!("unexpected {}", other.describe()),
            }),
        }
    }

    fn call(&mut self, name: &str, at: usize) -> Result<Ast, QueryError> {
        match name {
            "true" => return Ok(Ast::Literal(Value::Bool(true))),
            "false" => return Ok(Ast::Literal(Value::Bool(false))),
            "null" => return Ok(Ast::Literal(Value::Null)),
            "if" | "then" | "elif" | "else" | "end" => return Err(unsupported("if")),
            "reduce" | "foreach" | "try" | "catch" | "label" | "import" | "include" | "def" => {
                return Err(unsupported(name));
            }
            "and" | "or" | "as" => {
                return Err(QueryError::Parse {
                    at,
                    msg: format!("unexpected '{name}'"),
                });
            }
            _ => {}
        }
        let has_arg = self.peek_kind() == Some(&Tok::LParen);
        let arg = if has_arg {
            self.pos += 1;
            let a = self.pipe()?;
            if self.peek_kind() != Some(&Tok::RParen) {
                return Err(unsupported(format!("{name} with more than one argument")));
            }
            self.pos += 1;
            Some(Box::new(a))
        } else {
            None
        };
        let builtin = match (name, arg.is_some()) {
            ("select", true) => Builtin::Select,
            ("has", true) => Builtin::Has,
            ("length", false) => Builtin::Length,
            ("keys", false) => Builtin::Keys,
            ("keys_unsorted", false) => Builtin::KeysUnsorted,
            ("type", false) => Builtin::Type,
            ("not", false) => Builtin::Not,
            ("empty", false) => Builtin::Empty,
            ("ascii_downcase", false) => Builtin::AsciiDowncase,
            ("tostring", false) => Builtin::ToString,
            (n, a) => return Err(unsupported(format!("{n}/{}", usize::from(a)))),
        };
        Ok(Ast::Call(builtin, arg))
    }
}

/// jq has one number type; keep integers integral so `1` prints as `1`.
fn number(n: f64) -> Value {
    if n.fract() == 0.0 && n.abs() < 9.007_199_254_740_992e15 {
        Value::from(n as i64)
    } else {
        serde_json::Number::from_f64(n).map_or(Value::Null, Value::Number)
    }
}

// ------------------------------------------------------------- evaluator ---

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn truthy(v: &Value) -> bool {
    !matches!(v, Value::Null | Value::Bool(false))
}

/// A short rendering of a value for error text, as jq does.
fn describe(v: &Value) -> String {
    let s = serde_json::to_string(v).unwrap_or_default();
    if s.len() > 11 {
        format!(
            "{} ({}...)",
            type_name(v),
            &s[..s.char_indices().nth(10).map_or(s.len(), |c| c.0)]
        )
    } else {
        format!("{} ({s})", type_name(v))
    }
}

fn type_rank(v: &Value) -> u8 {
    match v {
        Value::Null => 0,
        Value::Bool(false) => 1,
        Value::Bool(true) => 2,
        Value::Number(_) => 3,
        Value::String(_) => 4,
        Value::Array(_) => 5,
        Value::Object(_) => 6,
    }
}

/// jq's total order over values.
pub fn compare(a: &Value, b: &Value) -> Ordering {
    let (ra, rb) = (type_rank(a), type_rank(b));
    if ra != rb {
        return ra.cmp(&rb);
    }
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (
                x.as_f64().unwrap_or(f64::NAN),
                y.as_f64().unwrap_or(f64::NAN),
            );
            x.partial_cmp(&y).unwrap_or(Ordering::Equal)
        }
        (Value::String(x), Value::String(y)) => x.cmp(y),
        (Value::Array(x), Value::Array(y)) => {
            for (p, q) in x.iter().zip(y.iter()) {
                let o = compare(p, q);
                if o != Ordering::Equal {
                    return o;
                }
            }
            x.len().cmp(&y.len())
        }
        (Value::Object(x), Value::Object(y)) => {
            let mut kx: Vec<&String> = x.keys().collect();
            let mut ky: Vec<&String> = y.keys().collect();
            kx.sort();
            ky.sort();
            let o = kx.cmp(&ky);
            if o != Ordering::Equal {
                return o;
            }
            for k in kx {
                let o = compare(&x[k], &y[k]);
                if o != Ordering::Equal {
                    return o;
                }
            }
            Ordering::Equal
        }
        _ => Ordering::Equal,
    }
}

fn index(t: &Value, k: &Value) -> Result<Value, QueryError> {
    match (t, k) {
        (Value::Null, Value::String(_) | Value::Number(_) | Value::Null) => Ok(Value::Null),
        (Value::Object(m), Value::String(s)) => Ok(m.get(s).cloned().unwrap_or(Value::Null)),
        (Value::Array(a), Value::Number(n)) => {
            let Some(f) = n.as_f64() else {
                return Ok(Value::Null);
            };
            let mut i = f.floor() as i64;
            if i < 0 {
                i += a.len() as i64;
            }
            if i < 0 {
                return Ok(Value::Null);
            }
            Ok(a.get(i as usize).cloned().unwrap_or(Value::Null))
        }
        (Value::Object(_), _) => Err(QueryError::Runtime(format!(
            "Cannot index object with {}",
            type_name(k)
        ))),
        (Value::Array(_), Value::String(s)) => Err(QueryError::Runtime(format!(
            "Cannot index array with \"{s}\""
        ))),
        (_, Value::String(s)) => Err(QueryError::Runtime(format!(
            "Cannot index {} with \"{s}\"",
            type_name(t)
        ))),
        _ => Err(QueryError::Runtime(format!(
            "Cannot index {} with {}",
            type_name(t),
            type_name(k)
        ))),
    }
}

fn run(ast: &Ast, input: &Value, o: &Opts, out: &mut Vec<Value>) -> Result<(), QueryError> {
    match ast {
        Ast::Identity => out.push(input.clone()),
        Ast::Literal(v) => out.push(v.clone()),
        Ast::Var(name) => match o.args.get(name) {
            Some(v) => out.push(v.clone()),
            None => return Err(QueryError::Runtime(format!("${name} is not defined"))),
        },
        Ast::Index(target, key) => {
            let mut ts = Vec::new();
            let terr = run(target, input, o, &mut ts);
            for t in &ts {
                let mut ks = Vec::new();
                run(key, input, o, &mut ks)?;
                for k in &ks {
                    out.push(index(t, k)?);
                }
            }
            terr?;
        }
        Ast::Iterate(target) => {
            let mut ts = Vec::new();
            let terr = run(target, input, o, &mut ts);
            for t in &ts {
                match t {
                    Value::Array(a) => out.extend(a.iter().cloned()),
                    Value::Object(m) => out.extend(m.values().cloned()),
                    other => {
                        return Err(QueryError::Runtime(format!(
                            "Cannot iterate over {}",
                            describe_iter(other)
                        )));
                    }
                }
            }
            terr?;
        }
        Ast::Try(inner) => {
            let _ = run(inner, input, o, out);
        }
        Ast::Pipe(lhs, rhs) => {
            let mut ls = Vec::new();
            let lerr = run(lhs, input, o, &mut ls);
            for l in &ls {
                run(rhs, l, o, out)?;
            }
            lerr?;
        }
        Ast::Comma(a, b) => {
            run(a, input, o, out)?;
            run(b, input, o, out)?;
        }
        Ast::Alt(a, b) => {
            let mut xs = Vec::new();
            let _ = run(a, input, o, &mut xs);
            let kept: Vec<Value> = xs.into_iter().filter(truthy).collect();
            if kept.is_empty() {
                run(b, input, o, out)?;
            } else {
                out.extend(kept);
            }
        }
        Ast::And(a, b) | Ast::Or(a, b) => {
            let is_and = matches!(ast, Ast::And(..));
            let mut xs = Vec::new();
            let xerr = run(a, input, o, &mut xs);
            for x in &xs {
                let t = truthy(x);
                if is_and && !t {
                    out.push(Value::Bool(false));
                } else if !is_and && t {
                    out.push(Value::Bool(true));
                } else {
                    let mut ys = Vec::new();
                    run(b, input, o, &mut ys)?;
                    out.extend(ys.iter().map(|y| Value::Bool(truthy(y))));
                }
            }
            xerr?;
        }
        Ast::Cmp(op, a, b) => {
            let mut bs = Vec::new();
            let berr = run(b, input, o, &mut bs);
            for bv in &bs {
                let mut as_ = Vec::new();
                run(a, input, o, &mut as_)?;
                for av in &as_ {
                    let ord = compare(av, bv);
                    let r = match op {
                        CmpOp::Eq => ord == Ordering::Equal,
                        CmpOp::Ne => ord != Ordering::Equal,
                        CmpOp::Lt => ord == Ordering::Less,
                        CmpOp::Le => ord != Ordering::Greater,
                        CmpOp::Gt => ord == Ordering::Greater,
                        CmpOp::Ge => ord != Ordering::Less,
                    };
                    out.push(Value::Bool(r));
                }
            }
            berr?;
        }
        Ast::Collect(inner) => {
            let mut xs = Vec::new();
            if let Some(inner) = inner {
                run(inner, input, o, &mut xs)?;
            }
            out.push(Value::Array(xs));
        }
        Ast::Call(b, arg) => call(*b, arg.as_deref(), input, o, out)?,
    }
    Ok(())
}

fn describe_iter(v: &Value) -> String {
    match v {
        Value::Null => "null".into(),
        other => describe(other),
    }
}

fn call(
    b: Builtin,
    arg: Option<&Ast>,
    input: &Value,
    o: &Opts,
    out: &mut Vec<Value>,
) -> Result<(), QueryError> {
    match b {
        Builtin::Select => {
            let mut xs = Vec::new();
            let err = run(arg.expect("select has an argument"), input, o, &mut xs);
            for x in &xs {
                if truthy(x) {
                    out.push(input.clone());
                }
            }
            err?;
        }
        Builtin::Has => {
            let mut ks = Vec::new();
            run(arg.expect("has has an argument"), input, o, &mut ks)?;
            for k in &ks {
                let r = match (input, k) {
                    (Value::Object(m), Value::String(s)) => m.contains_key(s),
                    (Value::Array(a), Value::Number(n)) => n
                        .as_f64()
                        .is_some_and(|f| f >= 0.0 && (f as usize) < a.len()),
                    _ => {
                        return Err(QueryError::Runtime(format!(
                            "Cannot check whether {} has a {} key",
                            type_name(input),
                            type_name(k)
                        )));
                    }
                };
                out.push(Value::Bool(r));
            }
        }
        Builtin::Length => out.push(match input {
            Value::Null => Value::from(0),
            Value::Bool(_) => {
                return Err(QueryError::Runtime(format!(
                    "{} has no length",
                    describe(input)
                )));
            }
            Value::Number(n) => number(n.as_f64().unwrap_or(0.0).abs()),
            Value::String(s) => Value::from(s.chars().count()),
            Value::Array(a) => Value::from(a.len()),
            Value::Object(m) => Value::from(m.len()),
        }),
        Builtin::Keys | Builtin::KeysUnsorted => out.push(match input {
            Value::Object(m) => {
                let mut ks: Vec<String> = m.keys().cloned().collect();
                if b == Builtin::Keys {
                    ks.sort();
                }
                Value::Array(ks.into_iter().map(Value::String).collect())
            }
            Value::Array(a) => Value::Array((0..a.len()).map(Value::from).collect()),
            other => {
                return Err(QueryError::Runtime(format!(
                    "{} has no keys",
                    describe(other)
                )));
            }
        }),
        Builtin::Type => out.push(Value::String(type_name(input).into())),
        Builtin::Not => out.push(Value::Bool(!truthy(input))),
        Builtin::Empty => {}
        Builtin::AsciiDowncase => match input {
            Value::String(s) => out.push(Value::String(s.to_ascii_lowercase())),
            other => {
                return Err(QueryError::Runtime(format!(
                    "{} cannot be ascii_downcased",
                    describe(other)
                )));
            }
        },
        Builtin::ToString => out.push(match input {
            Value::String(s) => Value::String(s.clone()),
            other => Value::String(serde_json::to_string(other).unwrap_or_default()),
        }),
    }
    Ok(())
}

// --------------------------------------------------------------- render ----

/// Render one result the way jq prints it: pretty (2-space) unless `compact`,
/// a string raw under `raw`. No trailing newline. jq escapes DEL (U+007F),
/// which serde_json does not, so that one byte is patched here.
pub fn render(v: &Value, raw: bool, compact: bool) -> String {
    if raw && let Value::String(s) = v {
        return s.clone();
    }
    let s = if compact {
        serde_json::to_string(v)
    } else {
        serde_json::to_string_pretty(v)
    }
    .unwrap_or_default();
    if s.contains('\u{7f}') {
        s.replace('\u{7f}', "\\u007f")
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn q(filter: &str, input: Value) -> Vec<Value> {
        eval(&input, &parse(filter).expect("parse"), &Opts::default()).expect("eval")
    }

    #[test]
    fn paths_and_missing_keys_follow_jq() {
        let doc = json!({"a": {"b": [10, 20, 30]}, "n": null});
        assert_eq!(q(".a.b[1]", doc.clone()), vec![json!(20)]);
        assert_eq!(q(".a.b[-1]", doc.clone()), vec![json!(30)]);
        assert_eq!(q(".a.b[9]", doc.clone()), vec![Value::Null]);
        assert_eq!(q(".missing", doc.clone()), vec![Value::Null]);
        assert_eq!(q(".n.deeper", doc.clone()), vec![Value::Null]);
        assert_eq!(q(".[\"a\"].b | length", doc), vec![json!(3)]);
    }

    #[test]
    fn iterate_select_and_alternative() {
        let doc = json!([{"k": "v", "z": 1}, {"k": "w", "z": 2}, {"z": 3}]);
        assert_eq!(
            q(".[] | select(.k == \"v\") | .z", doc.clone()),
            vec![json!(1)]
        );
        assert_eq!(
            q(".[] | select(.k != \"v\") | .z", doc.clone()),
            vec![json!(2), json!(3)]
        );
        assert_eq!(
            q("[.[] | .k // \"none\"]", doc.clone()),
            vec![json!(["v", "w", "none"])]
        );
        assert_eq!(q(".[2].k // empty", doc), Vec::<Value>::new());
    }

    #[test]
    fn try_keeps_outputs_before_the_error() {
        let doc = json!([{"x": 1}, 5, {"x": 2}]);
        assert_eq!(q("(.[] | .x)?", doc.clone()), vec![json!(1)]);
        assert!(eval(&doc, &parse(".[] | .x").expect("parse"), &Opts::default()).is_err());
    }

    #[test]
    fn numbers_compare_by_value_and_types_order_like_jq() {
        assert_eq!(q("1 == 1.0", Value::Null), vec![json!(true)]);
        assert_eq!(q("null < false", Value::Null), vec![json!(true)]);
        assert_eq!(q("\"a\" < [1]", Value::Null), vec![json!(true)]);
        assert_eq!(q("[1,2] < [1,3]", Value::Null), vec![json!(true)]);
    }

    #[test]
    fn right_operand_is_the_outer_loop() {
        assert_eq!(
            q("[(1,2) == (1,2)]", Value::Null),
            vec![json!([true, false, false, true])]
        );
    }

    #[test]
    fn out_of_subset_is_unsupported_not_a_parse_error() {
        for f in [
            "{a: .b}",
            ".a + 1",
            "@tsv",
            "join(\",\")",
            ". as $x | $x",
            "..",
            ".[1:2]",
            "\"\\(.a)\"",
        ] {
            match parse(f) {
                Err(QueryError::Unsupported { .. }) => {}
                other => panic!("{f}: expected Unsupported, got {other:?}"),
            }
        }
        assert!(matches!(parse(".a |"), Err(QueryError::Parse { .. })));
    }

    #[test]
    fn error_text_leads_with_its_kind() {
        assert!(
            parse("{")
                .unwrap_err()
                .to_string()
                .starts_with("unsupported:")
        );
        assert!(parse(".a |").unwrap_err().to_string().starts_with("parse:"));
        let e = eval(&json!(5), &parse(".a").expect("parse"), &Opts::default()).unwrap_err();
        assert!(e.to_string().starts_with("runtime: "));
    }

    #[test]
    fn variables_are_reported_and_bound() {
        let f = parse("select(.path == $p) | .text").expect("parse");
        assert_eq!(f.variables(), vec!["p".to_string()]);
        let mut o = Opts::default();
        o.args.insert("p".into(), json!("x"));
        let r = eval(&json!({"path": "x", "text": "t"}), &f, &o).expect("eval");
        assert_eq!(r, vec![json!("t")]);
    }

    #[test]
    fn keys_sort_and_render_matches_jq_layout() {
        assert_eq!(q("keys", json!({"b": 1, "a": 2})), vec![json!(["a", "b"])]);
        assert_eq!(
            render(&json!({"a": [1, 2], "b": {}}), false, false),
            "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {}\n}"
        );
        assert_eq!(render(&json!("x"), true, false), "x");
        assert_eq!(render(&json!("\u{7f}"), false, true), "\"\\u007f\"");
    }
}
