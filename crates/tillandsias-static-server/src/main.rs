use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Component, Path, PathBuf};
use std::process;
use std::thread;

fn main() {
    let mut args = env::args().skip(1);
    let mut root: Option<PathBuf> = None;
    let mut port: Option<u16> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => root = args.next().map(PathBuf::from),
            "--port" => {
                port = args.next().and_then(|value| value.parse::<u16>().ok());
            }
            "--help" | "-h" => {
                eprintln!("Usage: tillandsias-static-server --root <dir> --port <port>");
                return;
            }
            other => {
                eprintln!("unknown argument: {other}");
                process::exit(2);
            }
        }
    }

    let root = root.unwrap_or_else(|| {
        eprintln!("missing --root");
        process::exit(2);
    });
    let port = port.unwrap_or_else(|| {
        eprintln!("missing --port");
        process::exit(2);
    });
    let root = fs::canonicalize(&root).unwrap_or_else(|err| {
        eprintln!("invalid root {}: {err}", root.display());
        process::exit(2);
    });

    let listener = TcpListener::bind(("127.0.0.1", port)).unwrap_or_else(|err| {
        eprintln!("failed to bind 127.0.0.1:{port}: {err}");
        process::exit(1);
    });
    eprintln!("serving {} on http://127.0.0.1:{port}", root.display());

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let root = root.clone();
                thread::spawn(move || {
                    if let Err(err) = handle_client(stream, &root) {
                        eprintln!("request failed: {err}");
                    }
                });
            }
            Err(err) => eprintln!("accept failed: {err}"),
        }
    }
}

fn handle_client(mut stream: TcpStream, root: &Path) -> std::io::Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");

    if method != "GET" && method != "HEAD" {
        write_response(
            &mut stream,
            405,
            "text/plain",
            b"method not allowed",
            method == "HEAD",
        )?;
        return Ok(());
    }

    let Some(path) = resolve_path(root, target) else {
        write_response(
            &mut stream,
            403,
            "text/plain",
            b"forbidden",
            method == "HEAD",
        )?;
        return Ok(());
    };

    let path = if path.is_dir() {
        path.join("index.html")
    } else {
        path
    };

    match fs::read(&path) {
        Ok(body) => {
            let mime = mime_for(path.extension());
            write_response(&mut stream, 200, mime, &body, method == "HEAD")?;
        }
        Err(_) => {
            write_response(
                &mut stream,
                404,
                "text/plain",
                b"not found",
                method == "HEAD",
            )?;
        }
    }

    Ok(())
}

fn resolve_path(root: &Path, target: &str) -> Option<PathBuf> {
    let path_part = target.split('?').next().unwrap_or("/");
    let decoded = percent_decode(path_part)?;
    let mut path = PathBuf::from(root);

    for component in Path::new(decoded.trim_start_matches('/')).components() {
        match component {
            Component::Normal(segment) => path.push(segment),
            Component::CurDir => {}
            _ => return None,
        }
    }

    let canonical_parent = if path.exists() {
        fs::canonicalize(&path).ok()?
    } else {
        fs::canonicalize(path.parent()?).ok()?
    };
    if !canonical_parent.starts_with(root) {
        return None;
    }

    Some(path)
}

fn percent_decode(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut idx = 0;

    while idx < bytes.len() {
        if bytes[idx] == b'%' {
            if idx + 2 >= bytes.len() {
                return None;
            }
            let hex = std::str::from_utf8(&bytes[idx + 1..idx + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            idx += 3;
        } else {
            out.push(bytes[idx]);
            idx += 1;
        }
    }

    String::from_utf8(out).ok()
}

fn write_response(
    stream: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
    head_only: bool,
) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "Error",
    };
    write!(
        stream,
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    if !head_only {
        stream.write_all(body)?;
    }
    Ok(())
}

fn mime_for(extension: Option<&OsStr>) -> &'static str {
    match extension.and_then(OsStr::to_str).unwrap_or("") {
        "css" => "text/css; charset=utf-8",
        "html" => "text/html; charset=utf-8",
        "js" => "application/javascript; charset=utf-8",
        "json" => "application/json; charset=utf-8",
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "txt" => "text/plain; charset=utf-8",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    }
}
