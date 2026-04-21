use std::{path::Path, sync::Arc};

use anyhow::{Context, Result};
use bytes::{Buf, Bytes};
use h3::client;
use h3_quinn::Connection;
use http::Request;
use quinn::{ClientConfig, Endpoint, VarInt, crypto::rustls::QuicClientConfig};
use rustls::pki_types::CertificateDer;
use tokio::signal::unix::{SignalKind, signal};

const SERVER_ADDR: &str = "127.0.0.1:4433";
const CERT_PATH: &str = "server_cert.der";

#[tokio::main]
async fn main() -> Result<()> {
    let endpoint = make_client_endpoint()?;
    let connecting = endpoint
        .connect(SERVER_ADDR.parse().unwrap(), "localhost")
        .context("creating client connection")?;
    let quinn_conn = connecting.await.context("establishing client connection")?;
    let close_conn = quinn_conn.clone();

    let (mut driver, mut sender) = client::builder()
        .build::<_, _, Bytes>(Connection::new(quinn_conn))
        .await
        .context("building h3 client")?;

    let driver_task = tokio::spawn(async move {
        let error = driver.wait_idle().await;
        eprintln!("[Client] h3 driver closed: {error}");
    });

    let mut stream = sender
        .send_request(
            Request::get(format!("https://localhost:{}/events", 4433))
                .body(())
                .unwrap(),
        )
        .await
        .context("sending /events request")?;

    stream.finish().await.context("finishing request body")?;

    let response = stream.recv_response().await.context("receiving response")?;
    println!("[Client] response status={}", response.status());

    let mut index = 1usize;

    let mut terminate_signal =
        signal(SignalKind::terminate()).expect("Failed to create terminate signal handler");

    loop {
        tokio::select! {
            recv = stream.recv_data() => {
                let Some(mut chunk) = recv.context("receiving tick data")? else {
                    println!("[Client] stream ended");
                    break;
                };

                let payload = chunk.copy_to_bytes(chunk.remaining());
                print!("[Client] tick {index}: {}", String::from_utf8_lossy(&payload));
                index += 1;
            }
            _ = tokio::signal::ctrl_c() => {
                println!("[Client] received SIGTERM, emulating ABRUPT exit (without sending ApplicationClose(0x100)");
                std::process::exit(1);
            }

         _ = terminate_signal.recv() => {
                println!("[Client] received SIGTERM, sending ApplicationClose(0x100)");
                close_conn.close(VarInt::from_u32(0x100), b"connection close");
                break
            }
        }
    }

    let _ = driver_task.await;
    Ok(())
}

fn make_client_endpoint() -> Result<Endpoint> {
    let cert_bytes =
        std::fs::read(Path::new(CERT_PATH)).context("reading server certificate from disk")?;
    let mut roots = rustls::RootCertStore::empty();
    roots
        .add(CertificateDer::from(cert_bytes))
        .context("adding self-signed server certificate to root store")?;

    let mut crypto = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_root_certificates(roots)
    .with_no_client_auth();
    crypto.enable_early_data = true;
    crypto.alpn_protocols = vec![b"h3".to_vec()];

    let client_config = ClientConfig::new(Arc::new(QuicClientConfig::try_from(crypto)?));
    let mut endpoint =
        Endpoint::client("[::]:0".parse().unwrap()).context("binding client endpoint")?;
    endpoint.set_default_client_config(client_config);
    Ok(endpoint)
}
