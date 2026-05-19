use std::path::Path;

use tillandsias_podman::{OperationKind, PodmanClient};

const DEFAULT_STOP_TIMEOUT_SECS: u32 = 10;
const DEFAULT_LOG_TAIL_LINES: usize = 40;

/// Typed command surface accepted by `tillandsias-podman-cli`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliCommand {
    Image(ImageCommand),
    Container(ContainerCommand),
    Network(NetworkCommand),
    Secret(SecretCommand),
    System(SystemCommand),
    Health(HealthCommand),
    Diagnostics(DiagnosticsCommand),
    Scenario(ScenarioCommand),
    RawPodman(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImageCommand {
    Exists {
        image: String,
    },
    Pull {
        image: String,
    },
    BuildFrom {
        containerfile: String,
        tag: String,
        context_dir: String,
        build_args: Vec<String>,
    },
    Load {
        tarball_path: String,
    },
    Remove {
        image: String,
    },
    Tag {
        source: String,
        target: String,
    },
    Inspect {
        image: String,
    },
    /// Compatibility lane for older Podman-shaped calls such as `image prune`.
    Raw(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContainerCommand {
    Run {
        args: Vec<String>,
    },
    List,
    Start {
        name: String,
    },
    Inspect {
        name: String,
    },
    Stop {
        name: String,
        timeout_secs: u32,
    },
    Kill {
        name: String,
        signal: Option<String>,
    },
    Remove {
        name: String,
    },
    Logs {
        name: String,
        lines: usize,
    },
    HostPort {
        name: String,
        container_port: u16,
    },
    /// Compatibility lanes for Podman-shaped forms with richer flags.
    RawContainer(Vec<String>),
    RawInspect(Vec<String>),
    RawLogs(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NetworkCommand {
    Exists {
        name: String,
    },
    CreateInternal {
        name: String,
    },
    Remove {
        name: String,
    },
    /// Compatibility lane for older Podman-shaped calls such as `network create --driver ...`.
    Raw(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretCommand {
    List,
    Inspect {
        name: String,
    },
    CreateFile {
        name: String,
        path: String,
    },
    Remove {
        name: String,
    },
    /// Secrets do not yet have richer library helpers; this preserves current invocations.
    Raw(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SystemCommand {
    Migrate,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthCommand {
    Wait { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiagnosticsCommand {
    Snapshot { name: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScenarioCommand {
    List,
    Show { name: String },
    Run { name: String },
}

/// Parse, execute, and return printable stdout for one CLI invocation.
pub async fn run(args: Vec<String>) -> Result<String, String> {
    let command = parse_command(&args)?;
    execute_command(&PodmanClient::new(), command).await
}

pub fn parse_command(args: &[String]) -> Result<CliCommand, String> {
    let Some(group) = args.first().map(String::as_str) else {
        return Err(usage());
    };

    match group {
        "image" => parse_image(args).map(CliCommand::Image),
        "container" => parse_container(args).map(CliCommand::Container),
        "network" => parse_network(args).map(CliCommand::Network),
        "secret" => parse_secret(args).map(CliCommand::Secret),
        "system" => parse_system(args).map(CliCommand::System),
        "health" => parse_health(args).map(CliCommand::Health),
        "diagnostics" => parse_diagnostics(args).map(CliCommand::Diagnostics),
        "scenario" => parse_scenario(args).map(CliCommand::Scenario),
        "raw" if args.len() >= 2 => Ok(CliCommand::RawPodman(args[1..].to_vec())),
        _ => Err(usage()),
    }
}

pub async fn execute_command(client: &PodmanClient, command: CliCommand) -> Result<String, String> {
    match command {
        CliCommand::Image(command) => execute_image(client, command).await,
        CliCommand::Container(command) => execute_container(client, command).await,
        CliCommand::Network(command) => execute_network(client, command).await,
        CliCommand::Secret(command) => execute_secret(client, command).await,
        CliCommand::System(command) => execute_system(client, command).await,
        CliCommand::Health(HealthCommand::Wait { name }) => client
            .wait_healthy(&name)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        CliCommand::Diagnostics(command) => execute_diagnostics(client, command).await,
        CliCommand::Scenario(command) => execute_scenario(client, command).await,
        CliCommand::RawPodman(argv) => execute_raw_podman(client, argv).await,
    }
}

fn parse_image(args: &[String]) -> Result<ImageCommand, String> {
    match args.get(1).map(String::as_str) {
        Some("exists") if args.len() == 3 => Ok(ImageCommand::Exists {
            image: args[2].clone(),
        }),
        Some("pull") if args.len() == 3 => Ok(ImageCommand::Pull {
            image: args[2].clone(),
        }),
        Some("build-from") if args.len() >= 5 => Ok(ImageCommand::BuildFrom {
            containerfile: args[2].clone(),
            tag: args[3].clone(),
            context_dir: args[4].clone(),
            build_args: args[5..].to_vec(),
        }),
        Some("load") if args.len() == 3 => Ok(ImageCommand::Load {
            tarball_path: args[2].clone(),
        }),
        Some("rm" | "remove") if args.len() == 3 => Ok(ImageCommand::Remove {
            image: args[2].clone(),
        }),
        Some("tag") if args.len() == 4 => Ok(ImageCommand::Tag {
            source: args[2].clone(),
            target: args[3].clone(),
        }),
        Some("inspect") if args.len() == 3 => Ok(ImageCommand::Inspect {
            image: args[2].clone(),
        }),
        Some(_) if args.len() >= 2 => Ok(ImageCommand::Raw(args.to_vec())),
        _ => Err(usage()),
    }
}

fn parse_container(args: &[String]) -> Result<ContainerCommand, String> {
    match args.get(1).map(String::as_str) {
        Some("run") if args.len() >= 3 => Ok(ContainerCommand::Run {
            args: args[2..].to_vec(),
        }),
        Some("list") if args.len() == 2 => Ok(ContainerCommand::List),
        Some("start") if args.len() == 3 => Ok(ContainerCommand::Start {
            name: args[2].clone(),
        }),
        Some("inspect") if args.len() == 3 => Ok(ContainerCommand::Inspect {
            name: args[2].clone(),
        }),
        Some("inspect") if args.len() >= 3 => Ok(ContainerCommand::RawInspect(args.to_vec())),
        Some("stop") => parse_container_stop(args),
        Some("kill") if args.len() == 3 || args.len() == 4 => Ok(ContainerCommand::Kill {
            name: args[2].clone(),
            signal: args.get(3).cloned(),
        }),
        Some("rm" | "remove") if args.len() == 3 => Ok(ContainerCommand::Remove {
            name: args[2].clone(),
        }),
        Some("rm") if args.len() >= 3 => Ok(ContainerCommand::RawContainer(args.to_vec())),
        Some("logs") => parse_container_logs(args),
        Some("host-port") if args.len() == 4 => Ok(ContainerCommand::HostPort {
            name: args[2].clone(),
            container_port: parse_u16(&args[3], "container port")?,
        }),
        _ => Err(usage()),
    }
}

fn parse_container_stop(args: &[String]) -> Result<ContainerCommand, String> {
    match args {
        [_, _, name] => Ok(ContainerCommand::Stop {
            name: name.clone(),
            timeout_secs: DEFAULT_STOP_TIMEOUT_SECS,
        }),
        [_, _, name, timeout] if timeout.parse::<u32>().is_ok() => Ok(ContainerCommand::Stop {
            name: name.clone(),
            timeout_secs: parse_u32(timeout, "stop timeout")?,
        }),
        [_, _, flag, timeout, name] if matches!(flag.as_str(), "-t" | "--timeout") => {
            Ok(ContainerCommand::Stop {
                name: name.clone(),
                timeout_secs: parse_u32(timeout, "stop timeout")?,
            })
        }
        _ if args.len() >= 3 => Ok(ContainerCommand::RawContainer(args.to_vec())),
        _ => Err(usage()),
    }
}

fn parse_container_logs(args: &[String]) -> Result<ContainerCommand, String> {
    match args {
        [_, _, name] => Ok(ContainerCommand::Logs {
            name: name.clone(),
            lines: DEFAULT_LOG_TAIL_LINES,
        }),
        [_, _, name, lines] if lines.parse::<usize>().is_ok() => Ok(ContainerCommand::Logs {
            name: name.clone(),
            lines: parse_usize(lines, "log line count")?,
        }),
        [_, _, flag, lines, name] if flag == "--tail" => Ok(ContainerCommand::Logs {
            name: name.clone(),
            lines: parse_usize(lines, "log line count")?,
        }),
        _ if args.len() >= 3 => Ok(ContainerCommand::RawLogs(args.to_vec())),
        _ => Err(usage()),
    }
}

fn parse_network(args: &[String]) -> Result<NetworkCommand, String> {
    match args.get(1).map(String::as_str) {
        Some("exists") if args.len() == 3 => Ok(NetworkCommand::Exists {
            name: args[2].clone(),
        }),
        Some("create-internal") if args.len() == 3 => Ok(NetworkCommand::CreateInternal {
            name: args[2].clone(),
        }),
        Some("rm" | "remove") if args.len() == 3 => Ok(NetworkCommand::Remove {
            name: args[2].clone(),
        }),
        Some(_) if args.len() >= 2 => Ok(NetworkCommand::Raw(args.to_vec())),
        _ => Err(usage()),
    }
}

fn parse_secret(args: &[String]) -> Result<SecretCommand, String> {
    match args.get(1).map(String::as_str) {
        Some("ls" | "list") if args.len() == 2 => Ok(SecretCommand::List),
        Some("inspect") if args.len() == 3 => Ok(SecretCommand::Inspect {
            name: args[2].clone(),
        }),
        Some("create-file") if args.len() == 4 => Ok(SecretCommand::CreateFile {
            name: args[2].clone(),
            path: args[3].clone(),
        }),
        Some("rm" | "remove") if args.len() == 3 => Ok(SecretCommand::Remove {
            name: args[2].clone(),
        }),
        Some(_) if args.len() >= 2 => Ok(SecretCommand::Raw(args.to_vec())),
        _ => Err(usage()),
    }
}

fn parse_system(args: &[String]) -> Result<SystemCommand, String> {
    match args {
        [_, verb] if verb == "migrate" => Ok(SystemCommand::Migrate),
        _ => Err(usage()),
    }
}

fn parse_health(args: &[String]) -> Result<HealthCommand, String> {
    match args {
        [_, verb, name] if verb == "wait" => Ok(HealthCommand::Wait { name: name.clone() }),
        _ => Err(usage()),
    }
}

fn parse_diagnostics(args: &[String]) -> Result<DiagnosticsCommand, String> {
    match args {
        [_, verb, name] if verb == "snapshot" => {
            Ok(DiagnosticsCommand::Snapshot { name: name.clone() })
        }
        _ => Err(usage()),
    }
}

fn parse_scenario(args: &[String]) -> Result<ScenarioCommand, String> {
    match args {
        [_, verb] if verb == "list" => Ok(ScenarioCommand::List),
        [_, verb, name] if verb == "show" => Ok(ScenarioCommand::Show { name: name.clone() }),
        [_, verb, name] if verb == "run" => Ok(ScenarioCommand::Run { name: name.clone() }),
        _ => Err(usage()),
    }
}

async fn execute_image(client: &PodmanClient, command: ImageCommand) -> Result<String, String> {
    match command {
        ImageCommand::Exists { image } => {
            bool_gate(client.image_exists(&image).await, "image", &image)
        }
        ImageCommand::Pull { image } => client
            .pull_image(&image)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ImageCommand::BuildFrom {
            containerfile,
            tag,
            context_dir,
            build_args,
        } => client
            .build_image(&containerfile, &tag, &context_dir, &build_args)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ImageCommand::Load { tarball_path } => client
            .load_image(&tarball_path)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ImageCommand::Remove { image } => client
            .image_rm(&image)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ImageCommand::Tag { source, target } => client
            .image_tag(&source, &target)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ImageCommand::Inspect { image } => client
            .image_inspect(&image)
            .await
            .map_err(|err| err.to_string()),
        ImageCommand::Raw(argv) => raw(client, OperationKind::Image, argv).await,
    }
}

async fn execute_container(
    client: &PodmanClient,
    command: ContainerCommand,
) -> Result<String, String> {
    match command {
        ContainerCommand::Run { args } => client
            .run_container(&args)
            .await
            .map(|id| format!("{id}\n"))
            .map_err(|err| err.to_string()),
        ContainerCommand::List => client.container_list().await.map_err(|err| err.to_string()),
        ContainerCommand::Start { name } => client
            .start_container(&name)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ContainerCommand::Inspect { name } => {
            let inspect = client
                .inspect_container(&name)
                .await
                .map_err(|err| err.to_string())?;
            Ok(format!(
                "{}\n",
                serde_json::json!({
                    "name": inspect.name,
                    "state": inspect.state,
                    "image": inspect.image,
                })
            ))
        }
        ContainerCommand::Stop { name, timeout_secs } => client
            .stop_container(&name, timeout_secs)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ContainerCommand::Kill { name, signal } => client
            .kill_container(&name, signal.as_deref())
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ContainerCommand::Remove { name } => client
            .remove_container(&name)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        ContainerCommand::Logs { name, lines } => client
            .log_tail(&name, lines)
            .await
            .map(|tail| lines_with_final_newline(tail.lines))
            .map_err(|err| err.to_string()),
        ContainerCommand::HostPort {
            name,
            container_port,
        } => match client
            .container_host_port(&name, container_port)
            .await
            .map_err(|err| err.to_string())?
        {
            Some(port) => Ok(format!("{port}\n")),
            None => Err(format!(
                "container `{name}` has no published TCP mapping for port {container_port}"
            )),
        },
        ContainerCommand::RawContainer(argv) => raw(client, OperationKind::Container, argv).await,
        ContainerCommand::RawInspect(argv) => raw(client, OperationKind::Inspect, argv).await,
        ContainerCommand::RawLogs(argv) => raw(client, OperationKind::Logs, argv).await,
    }
}

async fn execute_network(client: &PodmanClient, command: NetworkCommand) -> Result<String, String> {
    match command {
        NetworkCommand::Exists { name } => {
            bool_gate(client.network_exists(&name).await, "network", &name)
        }
        NetworkCommand::CreateInternal { name } => client
            .create_internal_network(&name)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        NetworkCommand::Remove { name } => client
            .remove_network(&name)
            .await
            .map(|_| String::new())
            .map_err(|err| err.to_string()),
        NetworkCommand::Raw(argv) => raw(client, OperationKind::Network, argv).await,
    }
}

async fn execute_secret(client: &PodmanClient, command: SecretCommand) -> Result<String, String> {
    let argv = match command {
        SecretCommand::List => vec!["secret".into(), "ls".into()],
        SecretCommand::Inspect { name } => vec!["secret".into(), "inspect".into(), name],
        SecretCommand::CreateFile { name, path } => vec![
            "secret".into(),
            "create".into(),
            "--driver=file".into(),
            name,
            path,
        ],
        SecretCommand::Remove { name } => vec!["secret".into(), "rm".into(), name],
        SecretCommand::Raw(argv) => argv,
    };
    raw(client, OperationKind::Secret, argv).await
}

async fn execute_system(client: &PodmanClient, command: SystemCommand) -> Result<String, String> {
    match command {
        SystemCommand::Migrate => {
            raw(
                client,
                OperationKind::Diagnostics,
                vec!["system".into(), "migrate".into()],
            )
            .await
        }
    }
}

async fn execute_raw_podman(client: &PodmanClient, argv: Vec<String>) -> Result<String, String> {
    let Some(head) = argv.first().map(String::as_str) else {
        return Err("raw podman argv is empty".to_string());
    };
    let operation = match head {
        "run" | "create" | "start" | "stop" | "kill" | "rm" | "remove" | "exec" | "ps"
        | "inspect" | "container" => OperationKind::Container,
        "image" | "build" | "pull" | "load" | "tag" | "rmi" | "image-rm" => OperationKind::Image,
        "network" => OperationKind::Network,
        "secret" => OperationKind::Secret,
        "wait" => OperationKind::Health,
        "system" => OperationKind::Diagnostics,
        "logs" => OperationKind::Logs,
        "info" | "version" | "mount" | "volume" => OperationKind::Diagnostics,
        _ => OperationKind::Diagnostics,
    };
    raw(client, operation, argv).await
}

async fn execute_diagnostics(
    client: &PodmanClient,
    command: DiagnosticsCommand,
) -> Result<String, String> {
    match command {
        DiagnosticsCommand::Snapshot { name } => Ok(format!(
            "{}\n",
            client.diagnostics_snapshot(&name).await.render_human()
        )),
    }
}

async fn raw(
    client: &PodmanClient,
    operation: OperationKind,
    argv: Vec<String>,
) -> Result<String, String> {
    client
        .execute(operation, &argv)
        .await
        .map(|output| output.stdout)
        .map_err(|err| err.to_string())
}

fn bool_gate(found: bool, noun: &str, name: &str) -> Result<String, String> {
    if found {
        Ok(String::new())
    } else {
        Err(format!("{noun} not found: {name}"))
    }
}

fn lines_with_final_newline(lines: Vec<String>) -> String {
    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ScenarioStep {
    RemoveNetwork { name: &'static str },
    CreateInternalNetwork { name: &'static str },
    DiagnosticsSnapshot { name: &'static str },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Scenario {
    name: &'static str,
    description: &'static str,
    steps: &'static [ScenarioStep],
}

const NETWORK_LIFECYCLE_SMOKE_STEPS: &[ScenarioStep] = &[
    ScenarioStep::RemoveNetwork {
        name: "tillandsias-cli-scenario-smoke",
    },
    ScenarioStep::CreateInternalNetwork {
        name: "tillandsias-cli-scenario-smoke",
    },
    ScenarioStep::RemoveNetwork {
        name: "tillandsias-cli-scenario-smoke",
    },
];

const PROXY_DIAGNOSTICS_STEPS: &[ScenarioStep] = &[ScenarioStep::DiagnosticsSnapshot {
    name: "tillandsias-proxy",
}];

/// Named fixtures live here rather than in YAML so every verification rung uses one Rust-owned flow.
const SCENARIOS: &[Scenario] = &[
    Scenario {
        name: "network-lifecycle-smoke",
        description: "create and tear down the dedicated CLI smoke-test network",
        steps: NETWORK_LIFECYCLE_SMOKE_STEPS,
    },
    Scenario {
        name: "proxy-diagnostics",
        description: "render a diagnostics snapshot for the shared proxy container",
        steps: PROXY_DIAGNOSTICS_STEPS,
    },
];

fn scenario_by_name(name: &str) -> Option<&'static Scenario> {
    SCENARIOS.iter().find(|scenario| scenario.name == name)
}

async fn execute_scenario(
    client: &PodmanClient,
    command: ScenarioCommand,
) -> Result<String, String> {
    match command {
        ScenarioCommand::List => Ok(SCENARIOS
            .iter()
            .map(|scenario| format!("{}\t{}", scenario.name, scenario.description))
            .collect::<Vec<_>>()
            .join("\n")
            + "\n"),
        ScenarioCommand::Show { name } => {
            let scenario = scenario_by_name(&name)
                .ok_or_else(|| format!("unknown scenario `{name}`; run `scenario list`"))?;
            Ok(render_scenario(scenario))
        }
        ScenarioCommand::Run { name } => {
            if let Some(scenario) = scenario_by_name(&name) {
                run_named_scenario(client, scenario).await
            } else if Path::new(&name).is_file() {
                // Compatibility with the original text-file scenario runner. New fixtures belong above.
                run_legacy_scenario_file(client, &name).await
            } else {
                Err(format!("unknown scenario `{name}`; run `scenario list`"))
            }
        }
    }
}

fn render_scenario(scenario: &Scenario) -> String {
    let mut out = vec![format!("{}\t{}", scenario.name, scenario.description)];
    out.extend(scenario.steps.iter().map(render_scenario_step));
    format!("{}\n", out.join("\n"))
}

fn render_scenario_step(step: &ScenarioStep) -> String {
    match step {
        ScenarioStep::RemoveNetwork { name } => format!("network rm {name}"),
        ScenarioStep::CreateInternalNetwork { name } => format!("network create-internal {name}"),
        ScenarioStep::DiagnosticsSnapshot { name } => format!("diagnostics snapshot {name}"),
    }
}

async fn run_named_scenario(client: &PodmanClient, scenario: &Scenario) -> Result<String, String> {
    let mut stdout = String::new();
    for step in scenario.steps {
        let step_output = match step {
            ScenarioStep::RemoveNetwork { name } => {
                execute_network(
                    client,
                    NetworkCommand::Remove {
                        name: (*name).into(),
                    },
                )
                .await
            }
            ScenarioStep::CreateInternalNetwork { name } => {
                execute_network(
                    client,
                    NetworkCommand::CreateInternal {
                        name: (*name).into(),
                    },
                )
                .await
            }
            ScenarioStep::DiagnosticsSnapshot { name } => {
                execute_diagnostics(
                    client,
                    DiagnosticsCommand::Snapshot {
                        name: (*name).into(),
                    },
                )
                .await
            }
        }
        .map_err(|err| {
            format!(
                "scenario `{}` failed at `{}`: {err}",
                scenario.name,
                render_scenario_step(step)
            )
        })?;
        stdout.push_str(&step_output);
    }
    Ok(stdout)
}

async fn run_legacy_scenario_file(client: &PodmanClient, path: &str) -> Result<String, String> {
    let text =
        std::fs::read_to_string(path).map_err(|err| format!("scenario read failed: {err}"))?;
    for (idx, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let argv = shell_words(line);
        let Some(head) = argv.first().map(String::as_str) else {
            continue;
        };
        let kind = match head {
            "image" => OperationKind::Image,
            "container" => OperationKind::Container,
            "network" => OperationKind::Network,
            "secret" => OperationKind::Secret,
            _ => {
                return Err(format!(
                    "scenario line {} has unsupported head `{head}`",
                    idx + 1
                ));
            }
        };
        client
            .execute(kind, &argv)
            .await
            .map_err(|err| format!("scenario line {} failed: {err}", idx + 1))?;
    }
    Ok(String::new())
}

fn shell_words(line: &str) -> Vec<String> {
    line.split_whitespace().map(ToOwned::to_owned).collect()
}

fn parse_u16(value: &str, label: &str) -> Result<u16, String> {
    value
        .parse()
        .map_err(|_| format!("invalid {label}: `{value}`"))
}

fn parse_u32(value: &str, label: &str) -> Result<u32, String> {
    value
        .parse()
        .map_err(|_| format!("invalid {label}: `{value}`"))
}

fn parse_usize(value: &str, label: &str) -> Result<usize, String> {
    value
        .parse()
        .map_err(|_| format!("invalid {label}: `{value}`"))
}

pub fn usage() -> String {
    "usage: tillandsias-podman-cli \
  image <exists|pull|inspect|tag|rm|load|build-from> ... \
| container <run|list|inspect|stop|kill|rm|logs|host-port> ... \
| container <start> ... \
| network <exists|create-internal|rm> ... \
| secret <list|inspect|create-file|rm> ... \
| system migrate \
| health wait <name> \
| diagnostics snapshot <name> \
| scenario <list|show|run> \
| raw <podman-argv> ..."
        .into()
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tillandsias_podman::FakeBackend;

    use super::*;

    fn args(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|part| (*part).to_string()).collect()
    }

    #[test]
    fn parses_stable_image_and_network_verbs() {
        assert_eq!(
            parse_command(&args(&[
                "image",
                "build-from",
                "Containerfile",
                "demo:v1",
                ".",
                "--no-cache"
            ]))
            .unwrap(),
            CliCommand::Image(ImageCommand::BuildFrom {
                containerfile: "Containerfile".into(),
                tag: "demo:v1".into(),
                context_dir: ".".into(),
                build_args: vec!["--no-cache".into()],
            })
        );
        assert_eq!(
            parse_command(&args(&["network", "create-internal", "tillandsias-test"])).unwrap(),
            CliCommand::Network(NetworkCommand::CreateInternal {
                name: "tillandsias-test".into(),
            })
        );
    }

    #[test]
    fn preserves_podman_shaped_raw_compatibility_where_needed() {
        assert_eq!(
            parse_command(&args(&["image", "prune", "-f"])).unwrap(),
            CliCommand::Image(ImageCommand::Raw(args(&["image", "prune", "-f"])))
        );
        assert_eq!(
            parse_command(&args(&["network", "create", "--driver", "bridge", "demo"])).unwrap(),
            CliCommand::Network(NetworkCommand::Raw(args(&[
                "network", "create", "--driver", "bridge", "demo"
            ])))
        );
    }

    #[test]
    fn accepts_legacy_and_stable_container_forms() {
        assert_eq!(
            parse_command(&args(&["container", "stop", "-t", "5", "demo"])).unwrap(),
            CliCommand::Container(ContainerCommand::Stop {
                name: "demo".into(),
                timeout_secs: 5,
            })
        );
        assert_eq!(
            parse_command(&args(&["container", "logs", "demo", "12"])).unwrap(),
            CliCommand::Container(ContainerCommand::Logs {
                name: "demo".into(),
                lines: 12,
            })
        );
        assert_eq!(
            parse_command(&args(&["container", "logs", "-f", "demo"])).unwrap(),
            CliCommand::Container(ContainerCommand::RawLogs(args(&[
                "container",
                "logs",
                "-f",
                "demo",
            ])))
        );
    }

    #[test]
    fn parses_secret_health_diagnostics_and_scenario_groups() {
        assert_eq!(
            parse_command(&args(&["secret", "create-file", "token", "/tmp/token"])).unwrap(),
            CliCommand::Secret(SecretCommand::CreateFile {
                name: "token".into(),
                path: "/tmp/token".into(),
            })
        );
        assert_eq!(
            parse_command(&args(&["health", "wait", "proxy"])).unwrap(),
            CliCommand::Health(HealthCommand::Wait {
                name: "proxy".into(),
            })
        );
        assert_eq!(
            parse_command(&args(&["diagnostics", "snapshot", "proxy"])).unwrap(),
            CliCommand::Diagnostics(DiagnosticsCommand::Snapshot {
                name: "proxy".into(),
            })
        );
        assert_eq!(
            parse_command(&args(&["scenario", "run", "proxy-diagnostics"])).unwrap(),
            CliCommand::Scenario(ScenarioCommand::Run {
                name: "proxy-diagnostics".into(),
            })
        );
        assert_eq!(
            parse_command(&args(&["raw", "run", "--rm", "alpine"])).unwrap(),
            CliCommand::RawPodman(args(&["run", "--rm", "alpine"]))
        );
    }

    #[test]
    fn named_scenarios_are_rust_registered_and_renderable() {
        let scenario = scenario_by_name("network-lifecycle-smoke").unwrap();
        assert_eq!(scenario.steps.len(), 3);
        assert!(render_scenario(scenario).contains("network create-internal"));
        assert!(scenario_by_name("not-a-scenario").is_none());
    }

    #[tokio::test]
    async fn named_scenario_runs_through_library_network_methods() {
        let backend = Arc::new(FakeBackend::default());
        let client = PodmanClient::with_backend(backend.clone());

        execute_command(
            &client,
            CliCommand::Scenario(ScenarioCommand::Run {
                name: "network-lifecycle-smoke".into(),
            }),
        )
        .await
        .unwrap();

        assert_eq!(
            backend.seen(),
            vec![
                (
                    OperationKind::Network,
                    args(&["network", "rm", "-f", "tillandsias-cli-scenario-smoke"]),
                ),
                (
                    OperationKind::Network,
                    args(&[
                        "network",
                        "create",
                        "tillandsias-cli-scenario-smoke",
                        "--internal",
                    ]),
                ),
                (
                    OperationKind::Network,
                    args(&["network", "rm", "-f", "tillandsias-cli-scenario-smoke"]),
                ),
            ]
        );
    }

    #[tokio::test]
    async fn typed_secret_create_file_uses_secret_operation_kind() {
        let backend = Arc::new(FakeBackend::default());
        let client = PodmanClient::with_backend(backend.clone());

        execute_command(
            &client,
            CliCommand::Secret(SecretCommand::CreateFile {
                name: "github-token".into(),
                path: "/tmp/token".into(),
            }),
        )
        .await
        .unwrap();

        assert_eq!(
            backend.seen(),
            vec![(
                OperationKind::Secret,
                args(&[
                    "secret",
                    "create",
                    "--driver=file",
                    "github-token",
                    "/tmp/token",
                ]),
            )]
        );
    }
}
