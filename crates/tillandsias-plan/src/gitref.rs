//! ORDER 801-g9nn — the DAG plumbing behind a citation's `commit` and the
//! envelope's `caller_relation`.
//!
//! WHAT THIS MODULE REFUSES TO DO. It does not invent a version number. Git is
//! a DAG with a PARTIAL order, so two concurrent branches are genuinely
//! unordered and no `vNNNN` can be derived from ancestry alone. Everything here
//! is therefore either an exact fact (a commit sha, a blob's bytes at a commit)
//! or a DERIVED relationship between two named commits ([`Relation`]). When a
//! fact cannot be established — no git, no repository, an object the caller has
//! never fetched — the answer is [`Relation::Unknown`] or `None`, never a
//! plausible guess. An expert that guessed here would be re-creating the exact
//! defect the order exists to remove: an answer that is true in one frame and
//! silently wrong in the reader's.
//!
//! WHY A SUBPROCESS. Ancestry needs the commit graph, which means inflating
//! objects out of loose files and packfiles. `git` is already a hard runtime
//! dependency of this project (the git-mirror service, the forge's checkout,
//! fifteen call sites in `tillandsias-headless`), so shelling out costs nothing
//! and hand-rolling a packfile reader would put zlib on the critical path of an
//! evidence check. Every call is read-only, and every failure is absorbed into
//! `None`.
//!
//! @trace spec:spec-traceability
//! @trace order:801-g9nn

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The honest verdict about how a caller's checkout is positioned relative to
/// the commit an answer was computed from.
///
/// The vocabulary is CLOSED and deliberately includes two "I cannot tell you"
/// values, because the two ways of not knowing need different actions from the
/// reader:
///
/// * [`Relation::Unfetched`] — the answer's commit is not in the caller's
///   object store at all. This is the case order 801-g9nn was written for: with
///   a mirror-backed index shared across concurrent harnesses (801-a2by), an
///   expert can legitimately answer from a commit the asking agent has never
///   fetched. Served bare, that citation is a line number into a file the agent
///   cannot open. Named, it is the most useful sentence the expert has: *this
///   moved under you — fetch.*
/// * [`Relation::Unknown`] — the comparison itself could not be made (no git,
///   no repository, an unresolvable HEAD). Nothing is claimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Relation {
    /// The caller's HEAD IS the answer's commit. Line numbers transfer exactly.
    Same,
    /// The caller's HEAD is an ancestor of the answer's commit: the answer was
    /// computed from the caller's FUTURE.
    Behind,
    /// The answer's commit is an ancestor of the caller's HEAD: the caller has
    /// moved on since the answer's frame.
    Ahead,
    /// Both commits are known and neither reaches the other. This is the case a
    /// Lamport clock cannot express and a version number would misreport.
    Diverged,
    /// The answer's commit is not present in the caller's object store.
    Unfetched,
    /// The comparison could not be made.
    Unknown,
}

impl Relation {
    /// The pinned token a consumer branches on. Stable across renderings.
    pub fn as_str(self) -> &'static str {
        match self {
            Relation::Same => "same",
            Relation::Behind => "behind",
            Relation::Ahead => "ahead",
            Relation::Diverged => "diverged",
            Relation::Unfetched => "unfetched",
            Relation::Unknown => "unknown",
        }
    }

    /// Parse the pinned token back. Used by the verifier when it re-derives a
    /// stamped relation and has to compare it with what it computed.
    pub fn parse(s: &str) -> Option<Relation> {
        Some(match s {
            "same" => Relation::Same,
            "behind" => Relation::Behind,
            "ahead" => Relation::Ahead,
            "diverged" => Relation::Diverged,
            "unfetched" => Relation::Unfetched,
            "unknown" => Relation::Unknown,
            _ => return None,
        })
    }

    /// Does this relation mean the caller may be reading DIFFERENT BYTES than
    /// the answer was built from? `same` is the only relation that does not;
    /// `unknown` counts as suspect on purpose — an unverified frame is not a
    /// matching frame.
    pub fn may_differ(self) -> bool {
        self != Relation::Same
    }
}

/// A read-only view of one git checkout. Every method returns `None` rather
/// than an error: this whole module sits on a diagnostic path, and a diagnostic
/// that can abort the answer it is annotating is worse than no diagnostic.
#[derive(Debug, Clone)]
pub struct GitView {
    root: PathBuf,
}

impl GitView {
    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Run `git -C <root> <args...>` and return stdout on success only.
    ///
    /// A non-zero status yields `None`, which is what makes every caller
    /// fail-soft by construction: `git` missing, `root` not a repository, and
    /// `object not found` all collapse to "cannot tell".
    fn run(&self, args: &[&str]) -> Option<String> {
        let out = Command::new("git")
            .arg("-C")
            .arg(&self.root)
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        String::from_utf8(out.stdout).ok()
    }

    /// The commit `HEAD` resolves to. `None` on an unborn branch, a
    /// non-repository, or no git.
    pub fn head(&self) -> Option<String> {
        let sha = self.run(&["rev-parse", "HEAD"])?.trim().to_string();
        (!sha.is_empty()).then_some(sha)
    }

    /// Is `rev` a commit this object store actually has?
    ///
    /// `cat-file -e <rev>^{commit}` is the narrow question. `rev-parse` alone
    /// would answer "yes" for a well-formed sha the store does not contain.
    pub fn has_commit(&self, rev: &str) -> bool {
        if !looks_like_sha(rev) {
            return false;
        }
        self.run(&["cat-file", "-e", &format!("{rev}^{{commit}}")])
            .is_some()
    }

    /// Is `ancestor` reachable from `descendant`? `None` when either object is
    /// absent, so "cannot tell" never collapses into "no".
    pub fn is_ancestor(&self, ancestor: &str, descendant: &str) -> Option<bool> {
        if !self.has_commit(ancestor) || !self.has_commit(descendant) {
            return None;
        }
        let out = Command::new("git")
            .arg("-C")
            .arg(&self.root)
            .args(["merge-base", "--is-ancestor", ancestor, descendant])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .ok()?;
        match out.code() {
            Some(0) => Some(true),
            Some(1) => Some(false),
            // 128 (and anything else) is "git could not answer", not "no".
            _ => None,
        }
    }

    /// The bytes of `path` as of `commit`. `None` when the commit is unfetched,
    /// the path did not exist there, or the blob is not valid UTF-8.
    pub fn file_at(&self, commit: &str, path: &str) -> Option<String> {
        if !looks_like_sha(commit) {
            return None;
        }
        // `--` and the `:` form keep a path that looks like a rev from being
        // read as one.
        self.run(&["show", &format!("{commit}:{path}")])
    }
}

/// Reject anything that is not a plain hex object name BEFORE it reaches the
/// command line. `freshness.source_commit` crosses a tool boundary as a string,
/// and this module is the only place that turns such a string into an argument
/// — a value like `--upload-pack=...` or `HEAD; rm -rf` must never get there.
/// It also filters the literal `unknown` this codebase writes for an
/// undeterminable commit, which is a hole and not a rev.
pub fn looks_like_sha(s: &str) -> bool {
    s.len() >= 7 && s.len() <= 64 && s.chars().all(|c| c.is_ascii_hexdigit())
}

/// Derive the relationship between a caller's HEAD and an answer's commit.
///
/// The order of the tests is the design. Equality is checked FIRST so a caller
/// sitting exactly on the answer's commit is `same` without touching the object
/// store; presence is checked SECOND so the shared-index case reports
/// `unfetched` rather than falling through to a `diverged` that git never
/// actually computed.
pub fn classify(
    view: &GitView,
    caller_head: Option<&str>,
    answer_commit: Option<&str>,
) -> Relation {
    let (Some(head), Some(answer)) = (caller_head, answer_commit) else {
        return Relation::Unknown;
    };
    if !looks_like_sha(head) || !looks_like_sha(answer) {
        return Relation::Unknown;
    }
    if head == answer {
        return Relation::Same;
    }
    if !view.has_commit(head) {
        return Relation::Unknown;
    }
    if !view.has_commit(answer) {
        return Relation::Unfetched;
    }
    // A short sha and its full form are the same commit; equality above only
    // catches the identical spelling, so confirm through the graph.
    match (
        view.is_ancestor(head, answer),
        view.is_ancestor(answer, head),
    ) {
        (Some(true), Some(true)) => Relation::Same,
        (Some(true), Some(false)) => Relation::Behind,
        (Some(false), Some(true)) => Relation::Ahead,
        (Some(false), Some(false)) => Relation::Diverged,
        _ => Relation::Unknown,
    }
}

/// A real, disposable git repository for tests.
///
/// REAL COMMITS, NOT A MOCK. Everything this module claims is a claim about
/// what `git` does — ancestry across a merge base, an object that is simply not
/// in the store, a short sha naming the same commit as a long one. A fake
/// `GitView` would only prove that the test author and the implementation agree
/// about git, which is the belief most likely to be wrong.
#[cfg(test)]
pub(crate) mod testrepo {
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    pub struct Repo {
        pub dir: PathBuf,
    }

    impl Drop for Repo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// A private directory per repo. Order 638-ehzi: two parallel tests sharing
    /// one fixture dir produced an intermittent failure that was dismissed as
    /// unexplained twice, so the name carries the pid AND a process-local
    /// counter AND the caller's tag.
    pub fn repo(tag: &str) -> Repo {
        let n = NEXT.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("tilland-801g9nn-{tag}-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create fixture dir");
        let r = Repo { dir };
        r.git(&["init", "-q", "-b", "main"]);
        r.git(&["config", "user.email", "litmus@example.invalid"]);
        r.git(&["config", "user.name", "litmus"]);
        r.git(&["config", "commit.gpgsign", "false"]);
        r
    }

    impl Repo {
        pub fn git(&self, args: &[&str]) -> String {
            let out = Command::new("git")
                .arg("-C")
                .arg(&self.dir)
                .args(args)
                .output()
                .unwrap_or_else(|e| panic!("git {args:?}: {e}"));
            assert!(
                out.status.success(),
                "git {args:?} failed: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }

        pub fn write(&self, rel: &str, body: &str) {
            let p = self.dir.join(rel);
            if let Some(parent) = p.parent() {
                std::fs::create_dir_all(parent).expect("mkdir");
            }
            std::fs::write(&p, body).expect("write fixture file");
        }

        pub fn commit(&self, message: &str) -> String {
            self.git(&["add", "-A"]);
            self.git(&["commit", "-q", "--no-verify", "-m", message]);
            self.git(&["rev-parse", "HEAD"])
        }

        pub fn checkout(&self, rev: &str) {
            self.git(&["checkout", "-q", rev]);
        }

        pub fn path(&self) -> &Path {
            &self.dir
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testrepo::repo;
    use super::*;

    #[test]
    fn sha_shape_rejects_arguments_and_holes() {
        assert!(looks_like_sha("0bba6525f280b1f7aa4ca15d7cceef8fed902bd2"));
        assert!(looks_like_sha("0bba652"));
        assert!(!looks_like_sha("0bba65"), "six hex chars is too ambiguous");
        assert!(!looks_like_sha("unknown"));
        assert!(!looks_like_sha("HEAD"));
        assert!(!looks_like_sha("--upload-pack=/bin/sh"));
        assert!(!looks_like_sha(""));
        assert!(!looks_like_sha(
            "0bba6525f280b1f7aa4ca15d7cceef8fed902bd2 --exec"
        ));
    }

    #[test]
    fn relation_tokens_round_trip() {
        for r in [
            Relation::Same,
            Relation::Behind,
            Relation::Ahead,
            Relation::Diverged,
            Relation::Unfetched,
            Relation::Unknown,
        ] {
            assert_eq!(Relation::parse(r.as_str()), Some(r), "{r:?}");
        }
        assert_eq!(Relation::parse("newer"), None);
    }

    /// The four verdicts, on one real DAG:
    ///
    /// ```text
    ///   a ── b ── c        (main)
    ///    \
    ///     └── x            (side)
    /// ```
    #[test]
    fn the_four_relations_are_derived_from_a_real_commit_dag() {
        let r = repo("dag");
        r.write("f.md", "one\n");
        let a = r.commit("a");
        r.write("f.md", "one\ntwo\n");
        let b = r.commit("b");
        r.write("f.md", "one\ntwo\nthree\n");
        let c = r.commit("c");
        r.git(&["checkout", "-q", "-b", "side", &a]);
        r.write("f.md", "one\nSIDE\n");
        let x = r.commit("x");

        let v = GitView::new(r.path());

        assert_eq!(classify(&v, Some(&c), Some(&c)), Relation::Same);
        assert_eq!(
            classify(&v, Some(&a), Some(&c)),
            Relation::Behind,
            "a reader on the base is BEHIND an answer computed at the tip"
        );
        assert_eq!(
            classify(&v, Some(&c), Some(&a)),
            Relation::Ahead,
            "a reader at the tip is AHEAD of an answer computed at the base"
        );
        assert_eq!(
            classify(&v, Some(&x), Some(&c)),
            Relation::Diverged,
            "two concurrent branches are unordered — this is the verdict a version number cannot express"
        );
        // The intermediate commit keeps `behind`/`ahead` from being an accident
        // of endpoints.
        assert_eq!(classify(&v, Some(&b), Some(&c)), Relation::Behind);
        assert_eq!(classify(&v, Some(&b), Some(&a)), Relation::Ahead);

        // A short sha names the same commit as its long form, and the graph —
        // not string equality — has to be what says so.
        let short_c: String = c.chars().take(8).collect();
        assert_eq!(classify(&v, Some(&short_c), Some(&c)), Relation::Same);
    }

    /// THE CASE THE ORDER WAS FILED FOR. With a mirror-backed index shared
    /// across harnesses, the expert can answer from a commit the asking agent
    /// has never fetched. That must be its own verdict: it is not `diverged`
    /// (git computed no such thing) and it is emphatically not `unknown`,
    /// because the reader can act on it — fetch.
    #[test]
    fn a_commit_the_reader_never_fetched_is_unfetched_not_diverged() {
        let mine = repo("unfetched-mine");
        mine.write("f.md", "mine\n");
        let my_head = mine.commit("mine");

        let theirs = repo("unfetched-theirs");
        theirs.write("f.md", "theirs\n");
        let their_head = theirs.commit("theirs");

        let v = GitView::new(mine.path());
        assert!(
            !v.has_commit(&their_head),
            "fixture precondition: the other repo's commit is genuinely absent"
        );
        assert_eq!(
            classify(&v, Some(&my_head), Some(&their_head)),
            Relation::Unfetched
        );
        // And the reverse direction from the other checkout, so the asymmetry
        // is not an artefact of which repo we asked.
        let v2 = GitView::new(theirs.path());
        assert_eq!(
            classify(&v2, Some(&their_head), Some(&my_head)),
            Relation::Unfetched
        );
    }

    #[test]
    fn file_at_reads_the_blob_at_a_commit_and_refuses_what_it_cannot() {
        let r = repo("blob");
        r.write("f.md", "first\n");
        let a = r.commit("a");
        r.write("f.md", "second\n");
        let b = r.commit("b");

        let v = GitView::new(r.path());
        assert_eq!(v.file_at(&a, "f.md").as_deref(), Some("first\n"));
        assert_eq!(v.file_at(&b, "f.md").as_deref(), Some("second\n"));
        assert_eq!(v.file_at(&a, "never-existed.md"), None);
        // Not a sha: refused before it can become an argument.
        assert_eq!(v.file_at("HEAD", "f.md"), None);
        assert_eq!(v.file_at("--output=/tmp/pwned", "f.md"), None);
    }

    #[test]
    fn is_ancestor_says_none_rather_than_no_for_an_absent_object() {
        let r = repo("anc");
        r.write("f.md", "x\n");
        let a = r.commit("a");
        let other = repo("anc-other");
        other.write("f.md", "y\n");
        let absent = other.commit("y");

        let v = GitView::new(r.path());
        assert_eq!(v.is_ancestor(&a, &a), Some(true));
        assert_eq!(
            v.is_ancestor(&absent, &a),
            None,
            "an object we do not have must not be reported as 'not an ancestor'"
        );
    }

    #[test]
    fn classify_without_inputs_is_unknown_never_same() {
        let view = GitView::new(Path::new("/nonexistent-checkout-801-g9nn"));
        assert_eq!(classify(&view, None, None), Relation::Unknown);
        assert_eq!(classify(&view, Some("abcdef1"), None), Relation::Unknown);
        assert_eq!(classify(&view, None, Some("abcdef1")), Relation::Unknown);
        // The literal hole this codebase writes must not be treated as a rev.
        assert_eq!(
            classify(&view, Some("unknown"), Some("unknown")),
            Relation::Unknown,
            "two holes are not a match"
        );
    }
}
