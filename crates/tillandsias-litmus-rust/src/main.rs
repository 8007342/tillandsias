fn main() {
    match tillandsias_litmus_rust::run_cli(std::env::args().skip(1).collect()) {
        Ok(output) => {
            if !output.is_empty() {
                print!("{output}");
            }
        }
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
