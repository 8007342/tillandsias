//! The live activity line while the GitHub device login polls (order 1420-2pav).
//!
//! THE DEFECT. After the QR, the poll script printed one `.` per poll to an
//! inherited stdout, so a user waiting on their phone saw a slowly growing row
//! of dots with no sense of how long they had. The code's lifetime
//! (`expires_in`, usually 900 s) was known and never shown.
//!
//! WHAT THIS DOES. The poll's stdout is now piped through [`DevicePollView`]:
//! - a `.` at the start of a line is a poll tick, redrawn in place as ONE
//!   line: a bar of the time REMAINING (a real fraction of `expires_in`, never
//!   an animation no event earned) and an `mm:ss` countdown;
//! - every other line (errors, the Vault save, the success line) passes
//!   through unchanged, after the activity line is cleared;
//! - the script's existing `[tillandsias] Authorization successful!` line
//!   turns leaf green: the "full green on grant" the row asks for.
//!
//! NO NEW WORDS. The activity line is a bar and digits; the only coloured text
//! is a line the script already prints. spec:tray-ux gates user-facing
//! wording on operator approval, and this slice needs none.
//!
//! PLAIN TIER (`NO_COLOR`, `CI`, `TERM=dumb`, non-TTY stdout): output passes
//! through byte for byte, dots included, exactly as before this change.
//!
//! @trace order:1420-2pav

use tillandsias_progress_tty::{Tier, palette, render_bar};

/// The success line the poll script prints on grant (see `device_poll_script`).
const GRANTED_LINE: &str = "[tillandsias] Authorization successful!";

const BAR_WIDTH: usize = 24;

pub struct DevicePollView {
    tier: Tier,
    expires_in: u64,
    /// Bytes of the current non-tick line, held until its newline.
    line: Vec<u8>,
    /// Whether the activity line is on screen and must be cleared first.
    activity_shown: bool,
}

impl DevicePollView {
    pub fn new(tier: Tier, expires_in: u64) -> Self {
        Self {
            tier,
            expires_in,
            line: Vec::new(),
            activity_shown: false,
        }
    }

    /// The activity line for `elapsed` seconds into the code's lifetime.
    fn activity(&self, elapsed: u64) -> String {
        let left = self.expires_in.saturating_sub(elapsed);
        let fraction = if self.expires_in == 0 {
            0.0
        } else {
            left as f64 / self.expires_in as f64
        };
        format!(
            "\r\x1b[2K  {} {:02}:{:02}",
            render_bar(fraction, BAR_WIDTH, self.tier),
            left / 60,
            left % 60
        )
    }

    fn clear(&mut self, out: &mut Vec<u8>) {
        if self.activity_shown {
            out.extend_from_slice(b"\r\x1b[2K");
            self.activity_shown = false;
        }
    }

    fn flush_line(&mut self, out: &mut Vec<u8>) {
        self.clear(out);
        let text = String::from_utf8_lossy(&self.line).into_owned();
        if text.trim_end() == GRANTED_LINE {
            let c = palette::LEAF;
            let sgr = match self.tier {
                Tier::TrueColor => format!("\x1b[38;2;{};{};{}m", c.rgb.0, c.rgb.1, c.rgb.2),
                _ => format!("\x1b[38;5;{}m", c.xterm256),
            };
            out.extend_from_slice(format!("{sgr}{}\x1b[0m\n", text.trim_end()).as_bytes());
        } else {
            out.extend_from_slice(&self.line);
            out.push(b'\n');
        }
        self.line.clear();
    }

    /// Feed one chunk of the poll's stdout at `elapsed` seconds; returns the
    /// bytes to write to the terminal.
    pub fn feed(&mut self, chunk: &[u8], elapsed: u64) -> Vec<u8> {
        if self.tier == Tier::Plain {
            return chunk.to_vec();
        }
        let mut out = Vec::new();
        for &b in chunk {
            match b {
                b'.' if self.line.is_empty() => {
                    out.extend_from_slice(self.activity(elapsed).as_bytes());
                    self.activity_shown = true;
                }
                b'\n' => {
                    if self.line.is_empty() {
                        // A bare newline (the script's `printf '\n…'`) only
                        // ends the dot row; the activity line absorbs it.
                        continue;
                    }
                    self.flush_line(&mut out);
                }
                _ => self.line.push(b),
            }
        }
        out
    }

    /// Anything still buffered when the poll exits (a last line with no newline).
    pub fn finish(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        if self.tier == Tier::Plain {
            return out;
        }
        if !self.line.is_empty() {
            self.flush_line(&mut out);
        } else if self.activity_shown {
            self.clear(&mut out);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(b: &[u8]) -> String {
        String::from_utf8_lossy(b).into_owned()
    }

    #[test]
    fn plain_tier_is_byte_for_byte_unchanged() {
        let mut v = DevicePollView::new(Tier::Plain, 900);
        let input = b"...\n[tillandsias] Authorization successful!\n";
        assert_eq!(v.feed(input, 5), input.to_vec());
        assert!(v.finish().is_empty());
    }

    #[test]
    fn a_tick_redraws_one_line_with_the_real_time_left() {
        let mut v = DevicePollView::new(Tier::Ansi256, 900);
        let out = s(&v.feed(b".", 60));
        assert!(out.starts_with("\r\x1b[2K  "), "{out:?}");
        assert!(out.ends_with(" 14:00"), "900s - 60s = 14:00: {out:?}");
        let later = s(&v.feed(b".", 895));
        assert!(later.ends_with(" 00:05"), "{later:?}");
        let past = s(&v.feed(b".", 2000));
        assert!(past.ends_with(" 00:00"), "never negative: {past:?}");
        assert!(!out.contains('.'), "the dot itself is not echoed");
    }

    #[test]
    fn the_granted_line_turns_green_and_clears_the_activity_line() {
        let mut v = DevicePollView::new(Tier::TrueColor, 900);
        v.feed(b"..", 10);
        let out = s(&v.feed(b"\n[tillandsias] Authorization successful!\n", 12));
        assert_eq!(
            out,
            "\r\x1b[2K\x1b[38;2;79;138;91m[tillandsias] Authorization successful!\x1b[0m\n"
        );
    }

    #[test]
    fn other_lines_pass_through_unchanged_even_split_across_chunks() {
        let mut v = DevicePollView::new(Tier::Ansi256, 900);
        v.feed(b".", 1);
        let mut out = v.feed(b"\nLogin timed ", 2);
        out.extend(v.feed(b"out waiting for authorization.\n", 3));
        assert_eq!(
            s(&out),
            "\r\x1b[2KLogin timed out waiting for authorization.\n",
            "a trailing '.' inside a line is text, not a tick"
        );
    }

    #[test]
    fn finish_flushes_a_last_line_without_newline() {
        let mut v = DevicePollView::new(Tier::Ansi256, 900);
        v.feed(b".", 1);
        v.feed(b"partial", 2);
        assert_eq!(s(&v.finish()), "\r\x1b[2Kpartial\n");
    }

    /// No new user-facing words: the activity line is bar cells, spaces,
    /// digits and a colon, plus escape sequences.
    #[test]
    fn the_activity_line_carries_no_words() {
        let v = DevicePollView::new(Tier::TrueColor, 900);
        let line = v.activity(123);
        let visible = strip_sgr(&line);
        assert!(
            visible.ends_with("12:57"),
            "900s - 123s = 777s = 12:57: {visible:?}"
        );
        assert!(!visible.chars().any(char::is_alphabetic), "{visible:?}");
    }

    fn strip_sgr(s: &str) -> String {
        let mut out = String::new();
        let mut chars = s.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\x1b' {
                for d in chars.by_ref() {
                    if d.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }
}
