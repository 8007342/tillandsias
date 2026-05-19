#[tokio::main]
async fn main() {
    match tillandsias_podman_cli::run(std::env::args().skip(1).collect()).await {
        Ok(stdout) => print!("{stdout}"),
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
