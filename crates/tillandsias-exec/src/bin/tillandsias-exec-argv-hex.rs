//! Test helper (order 1553-q3wi): print each argv entry after the program name
//! as one line of lowercase hex over its raw bytes, so a caller can compare what
//! a NATIVE child received byte for byte (Windows: the Rust runtime parses the
//! command line with the CommandLineToArgvW / MSVC CRT rules).
fn main() {
    for arg in std::env::args_os().skip(1) {
        let hex: String = arg
            .into_encoded_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        println!("{hex}");
    }
}
