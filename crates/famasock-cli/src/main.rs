use anyhow::{Context, Result, ensure};
use clap::{Parser, Subcommand};
use famasock::{Node, control::Command, wire};
use serde_json::{Value, json};
use std::{
    net::{Ipv4Addr, SocketAddr},
    path::{Path, PathBuf},
};
use tokio::{
    net::{UnixListener, UnixStream},
    task::JoinSet,
};

#[derive(Parser)]
#[command(version, about = "Secure paired-device networking over Iroh")]
struct Cli {
    #[arg(long,global=true,default_value_os_t=default_dir())]
    state: PathBuf,
    #[command(subcommand)]
    command: Cmd,
}
#[derive(Subcommand)]
enum Cmd {
    Serve {
        #[arg(long, default_value = "computer")]
        name: String,
        #[arg(long, hide = true)]
        offline: bool,
    },
    /// Display a single-use QR and ask for approval when a device scans it.
    Pair {
        /// Accept an invitation instead of creating one. Prefer stdin to avoid shell history.
        #[arg(long)]
        accept: Option<String>,
    },
    Peers,
    Status,
    Pending,
    Approve {
        id: String,
        #[arg(long)]
        reject: bool,
    },
    Rename {
        peer: String,
        name: String,
    },
    Allow {
        peer: String,
        service: String,
        destination: String,
    },
    /// Replace the peer's entire inbound policy with the given JSON file.
    Policy {
        peer: String,
        file: PathBuf,
    },
    Revoke {
        peer: String,
    },
    Disconnect {
        peer: String,
    },
    Connect {
        peer: String,
    },
    /// E.g. forward home 2222:ssh (binds loopback).
    Forward {
        peer: String,
        rule: String,
    },
    /// E.g. reverse home 8080:127.0.0.1:3000 (both ends loopback).
    Reverse {
        peer: String,
        rule: String,
    },
    Socks {
        peer: String,
        #[arg(long, default_value = "127.0.0.1:1080")]
        listen: SocketAddr,
    },
    Stop {
        id: String,
    },
    Vpn {
        peer: String,
        #[arg(long, required = true)]
        route: Vec<String>,
        #[arg(long)]
        tun: String,
    },
    StopVpn {
        id: String,
    },
    Version,
}
fn default_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| ".".into()))
                .join(".local/state")
        })
        .join("famasock")
}
async fn rpc(path: &Path, command: &Command) -> Result<Value> {
    let mut socket = UnixStream::connect(path.join("control.sock"))
        .await
        .context("start `famasock serve` first (same --state)")?;
    wire::write_limit(&mut socket, command, wire::MAX_CONTROL).await?;
    let result: Value = tokio::time::timeout(
        std::time::Duration::from_secs(140),
        wire::read_limit(&mut socket, wire::MAX_CONTROL),
    )
    .await??;
    if let Some(e) = result.get("error").and_then(Value::as_str) {
        anyhow::bail!("{e}");
    }
    Ok(result["data"].clone())
}
async fn serve(path: &Path, name: &str, offline: bool) -> Result<()> {
    let node = Node::open(path, name, None, offline).await?;
    let sockpath = path.join("control.sock");
    if sockpath.exists() {
        std::fs::remove_file(&sockpath)?;
    }
    let listener = UnixListener::bind(&sockpath)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&sockpath, std::fs::Permissions::from_mode(0o600))?;
    println!(
        "Famasock server started\nIdentity: {}\nTransport: Iroh\nStatus: Listening",
        node.endpoint.id()
    );
    let mut clients = JoinSet::new();
    let mut events = node.subscribe();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => break,
            _ = terminate.recv() => break,
            Some(_) = clients.join_next(), if !clients.is_empty() => {},
            event = events.recv() => { if let Ok(e) = event { eprintln!("{e}"); } },
            accepted = listener.accept(), if clients.len() < 16 => {
                let (mut socket,_) = accepted?; let node = node.clone();
                clients.spawn(async move {
                    let command: Command = tokio::time::timeout(wire::SETUP_TIMEOUT,wire::read_limit(&mut socket, wire::MAX_CONTROL)).await??;
                    let result = match node.command(command).await { Ok(v) => json!({"data":v}), Err(e) => json!({"error":e.to_string()}) };
                    wire::write_limit(&mut socket,&result, wire::MAX_CONTROL).await?; Ok::<_,anyhow::Error>(())
                });
            }
        }
    }
    clients.abort_all();
    while clients.join_next().await.is_some() {}
    node.shutdown().await;
    std::fs::remove_file(sockpath)?;
    Ok(())
}
// A cancellable nonblocking terminal read: never leave a spawn_blocking stdin
// worker alive after Ctrl-C or after an invitation expires.
async fn terminal_line() -> Result<String> {
    use std::{io::Read, os::unix::fs::OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open("/dev/tty")
        .context("approval requires a terminal; use famasock approve from another terminal")?;
    let fd = tokio::io::unix::AsyncFd::new(file)?;
    let mut bytes = Vec::new();
    loop {
        let mut ready = fd.readable().await?;
        let mut chunk = [0; 256];
        match ready.try_io(|fd| fd.get_ref().read(&mut chunk)) {
            Ok(Ok(0)) => anyhow::bail!("terminal closed"),
            Ok(Ok(n)) => {
                bytes.extend_from_slice(&chunk[..n]);
                ensure!(bytes.len() <= 256, "answer too long");
                if bytes.contains(&b'\n') {
                    return Ok(String::from_utf8(bytes)?);
                }
            }
            Ok(Err(e)) => return Err(e.into()),
            Err(_) => {}
        }
    }
}
async fn pair(path: &Path, accept: Option<String>) -> Result<()> {
    if let Some(uri) = accept {
        let uri = if uri == "-" {
            let mut s = String::new();
            std::io::stdin().read_line(&mut s)?;
            s.trim().into()
        } else {
            uri
        };
        let v = rpc(
            path,
            &Command::Pair {
                uri,
                device: std::env::consts::OS.into(),
            },
        )
        .await?;
        println!("Paired: {v}");
        return Ok(());
    }
    let invitation = rpc(path, &Command::Invite).await?;
    let uri = invitation["uri"]
        .as_str()
        .context("missing invitation URI")?;
    let code = qrcode::QrCode::new(uri)?;
    println!(
        "Scan this QR code using Famasock for iOS:\n{}\n{uri}\nWaiting for pairing request…",
        code.render::<qrcode::render::unicode::Dense1x2>()
            .quiet_zone(true)
            .build()
    );
    let id = invitation["id"].as_str().context("missing ID")?.to_string();
    // Local control status only; networking and iOS use pushed events. A simple CLI
    // query avoids an additional long-lived admin protocol.
    let result = async {
        loop {
            let pending = rpc(path, &Command::Pending).await?;
            if let Some(p) = pending
                .as_array()
                .and_then(|v| v.iter().find(|p| p["id"] == id))
            {
                println!(
                    "Device: {}\nIdentity: {}\nApprove pairing? [y/N]",
                    p["name"], p["peer"]
                );
                let answer = terminal_line().await?;
                rpc(
                    path,
                    &Command::Approve {
                        id: id.clone(),
                        accept: answer.trim().eq_ignore_ascii_case("y"),
                    },
                )
                .await?;
                return Ok::<_, anyhow::Error>(());
            }
            tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        }
    };
    let result = tokio::select! { r = tokio::time::timeout(std::time::Duration::from_secs(300),result) => r.unwrap_or_else(|e| Err(e.into())), _ = tokio::signal::ctrl_c() => Ok(()) };
    let _ = rpc(path, &Command::CancelInvite { id }).await;
    result
}
#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let command = match cli.command {
        Cmd::Serve { name, offline } => return serve(&cli.state, &name, offline).await,
        Cmd::Pair { accept } => return pair(&cli.state, accept).await,
        Cmd::Version => {
            println!("famasock {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Cmd::Status | Cmd::Peers => Command::Status,
        Cmd::Pending => Command::Pending,
        Cmd::Approve { id, reject } => Command::Approve {
            id,
            accept: !reject,
        },
        Cmd::Rename { peer, name } => Command::Rename { peer, name },
        Cmd::Allow {
            peer,
            service,
            destination,
        } => Command::Allow {
            peer,
            service,
            destination,
        },
        Cmd::Policy { peer, file } => Command::Policy {
            peer,
            policy: serde_json::from_slice(&std::fs::read(file)?)?,
        },
        Cmd::Revoke { peer } => Command::Revoke { peer },
        Cmd::Disconnect { peer } => Command::Disconnect { peer },
        Cmd::Connect { peer } => Command::Services { peer },
        Cmd::Stop { id } => Command::Stop { id },
        Cmd::StopVpn { id } => Command::StopVpn { id },
        Cmd::Forward { peer, rule } => {
            let (port, service) = rule.split_once(':').context("expected port:service")?;
            Command::Forward {
                peer,
                listen: SocketAddr::from((Ipv4Addr::LOCALHOST, port.parse::<u16>()?)),
                service: service.into(),
            }
        }
        Cmd::Reverse { peer, rule } => {
            let (port, target) = rule
                .split_once(':')
                .context("expected port:127.0.0.1:port")?;
            Command::Reverse {
                peer,
                port: port.parse()?,
                target: target.parse()?,
            }
        }
        Cmd::Socks { peer, listen } => Command::Socks { peer, listen },
        Cmd::Vpn { peer, route, tun } => {
            ensure!(!route.is_empty(), "specify routes");
            Command::Vpn {
                peer,
                routes: route
                    .iter()
                    .map(|r| r.parse())
                    .collect::<std::result::Result<_, _>>()?,
                tun,
            }
        }
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&rpc(&cli.state, &command).await?)?
    );
    Ok(())
}
