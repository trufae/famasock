use anyhow::{Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
pub const ALPN: &[u8] = b"famasock/1";
pub const MAX_HEADER: usize = 8192;
pub const SETUP_TIMEOUT: Duration = Duration::from_secs(15);
/// Version byte + big endian u32 size + JSON. Only setup is framed, never TCP payload.
pub async fn write<T: Serialize>(w: &mut (impl AsyncWrite + Unpin), v: &T) -> Result<()> {
    let bytes = serde_json::to_vec(v)?;
    ensure!(bytes.len() <= MAX_HEADER, "header too large");
    w.write_u8(1).await?;
    w.write_u32(bytes.len() as u32).await?;
    w.write_all(&bytes).await?;
    w.flush().await?;
    Ok(())
}
pub async fn read<T: DeserializeOwned>(r: &mut (impl AsyncRead + Unpin)) -> Result<T> {
    ensure!(r.read_u8().await? == 1, "unsupported protocol version");
    let len = r.read_u32().await? as usize;
    ensure!(len <= MAX_HEADER, "header too large");
    let mut bytes = vec![0; len];
    r.read_exact(&mut bytes).await?;
    Ok(serde_json::from_slice(&bytes)?)
}
