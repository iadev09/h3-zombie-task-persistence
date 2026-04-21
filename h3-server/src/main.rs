use std::{
    net::SocketAddr,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

use anyhow::{Context, Result};
use bytes::Bytes;
use h3::server;
use h3_quinn::Connection;
use http::{Method, Response, StatusCode};
use quinn::{Endpoint, ServerConfig, TransportConfig, crypto::rustls::QuicServerConfig};
use rcgen::generate_simple_self_signed;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::time::sleep;

static SUBSCRIBER_COUNT: AtomicUsize = AtomicUsize::new(0);
static TICK_COUNT: AtomicUsize = AtomicUsize::new(0);

const BIND_ADDR: &str = "127.0.0.1:4433";
const CERT_PATH: &str = "server_cert.der";
const IDLE_TIMEOUT_SECS: u64 = 10;
const TICK_INTERVAL_SECS: u64 = 1;
const KEEPALIVE_INTERVAL_SECS: u64 = 1;

#[tokio::main]
async fn main() -> Result<()> {
    let endpoint = make_server_endpoint(BIND_ADDR.parse().unwrap())?;

    println!("[Server] listening on https://{BIND_ADDR}");
    println!(
        "[Server] wrote certificate to {}",
        Path::new(CERT_PATH).display()
    );
    println!(
        "[Server] tick interval={}s keep alive interval={}s idle_timeout={}",
        TICK_INTERVAL_SECS, KEEPALIVE_INTERVAL_SECS, IDLE_TIMEOUT_SECS
    );

    loop {
        let Some(incoming) = endpoint.accept().await else {
            continue;
        };

        tokio::spawn(async move {
            match incoming.await {
                Ok(conn) => {
                    let remote = conn.remote_address();
                    println!("[Server] accepted QUIC connection from {remote}");

                    if let Err(error) = handle_connection(conn).await {
                        eprintln!("[Server] connection task ended with error: {error:#}");
                    }
                }
                Err(error) => {
                    eprintln!("[Server] failed to establish QUIC connection: {error}");
                }
            }
        });
    }
}

async fn handle_connection(conn: quinn::Connection) -> Result<()> {
    let mut h3_conn = server::builder()
        .build::<_, Bytes>(Connection::new(conn))
        .await
        .context("building h3 server connection")?;

    loop {
        match h3_conn.accept().await {
            Ok(Some(resolver)) => {
                tokio::spawn(async move {
                    match resolver.resolve_request().await {
                        Ok((request, stream)) => {
                            if request.method() == Method::GET && request.uri().path() == "/events"
                            {
                                if let Err(error) = stream_events(stream).await {
                                    eprintln!("[Server] /events handler failed: {error:#}");
                                }
                            } else {
                                let mut stream = stream;
                                let response = Response::builder()
                                    .status(StatusCode::NOT_FOUND)
                                    .body(())
                                    .unwrap();

                                if let Err(error) = stream.send_response(response).await {
                                    eprintln!("[Server] failed to send 404 response: {error}");
                                    return;
                                }

                                if let Err(error) = stream.finish().await {
                                    eprintln!("[Server] failed to finish 404 response: {error}");
                                }
                            }
                        }
                        Err(error) => {
                            eprintln!("[Server] failed to resolve request: {error}");
                        }
                    }
                });
            }
            Ok(None) => {
                println!("[Server] h3 connection closed cleanly");
                break;
            }
            Err(error) => {
                eprintln!("[Server] h3 accept loop ended with error: {error}");
                break;
            }
        }
    }

    Ok(())
}

async fn stream_events(
    mut stream: h3::server::RequestStream<h3_quinn::BidiStream<Bytes>, Bytes>,
) -> Result<()> {
    let _guard = SubscriberGuard;
    SUBSCRIBER_COUNT.fetch_add(1, Ordering::SeqCst);

    let response = Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/json")
        .body(())
        .unwrap();

    stream
        .send_response(response)
        .await
        .context("sending initial response")?;

    loop {
        sleep(Duration::from_secs(TICK_INTERVAL_SECS)).await;

        let subscribers = SUBSCRIBER_COUNT.load(Ordering::SeqCst);
        let tick = TICK_COUNT.fetch_add(1, Ordering::SeqCst) + 1;
        let payload = format!("{{\"tick\":{tick},\"subscribers\":{subscribers}}}\n");

        match stream.send_data(Bytes::from(payload)).await {
            Ok(()) => {}
            Err(error) => {
                eprintln!("[Server] subscriber stream send_data failed after tick {tick}: {error}");
                return Err(error.into());
            }
        }
    }
}

fn make_server_endpoint(bind_addr: SocketAddr) -> Result<Endpoint> {
    let cert = generate_simple_self_signed(vec!["localhost".into()])?;
    let cert_der = CertificateDer::from(cert.cert);
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(cert.key_pair.serialize_der()));

    std::fs::write(CERT_PATH, cert_der.as_ref()).context("writing server certificate")?;

    let mut transport = TransportConfig::default();
    transport
        .keep_alive_interval(Some(
            Duration::from_secs(KEEPALIVE_INTERVAL_SECS)
                .try_into()
                .context("invalid ping interval")?,
        ))
        .max_idle_timeout(Some(
            Duration::from_secs(IDLE_TIMEOUT_SECS)
                .try_into()
                .context("invalid idle timeout")?,
        ));

    let mut crypto = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert_der], key)
    .context("building rustls server config")?;
    crypto.max_early_data_size = u32::MAX;
    crypto.alpn_protocols = vec![b"h3".to_vec()];

    let mut server_config =
        ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(crypto)?));
    server_config.transport = Arc::new(transport);

    Endpoint::server(server_config, bind_addr).context("binding server endpoint")
}

struct SubscriberGuard;

impl Drop for SubscriberGuard {
    fn drop(&mut self) {
        SUBSCRIBER_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}
