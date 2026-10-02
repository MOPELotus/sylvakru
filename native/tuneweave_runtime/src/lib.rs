//! Linsen embedding adapter. TuneWeave provider and HTTP contracts remain upstream-owned.
//! Copyright 2026 MOPELotus. Licensed under Apache-2.0.
use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
};
use rand::{RngExt, distr::Alphanumeric};
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock, mpsc},
    thread,
};
use tokio::sync::oneshot;
use tuneweave_core::{
    AccountCredentialStore, FileAccountCredentialStore, Platform, ProviderRegistry,
};
use tuneweave_provider_bilibili::{BilibiliConfig, BilibiliProvider};
use tuneweave_provider_kugou::{KugouConfig, KugouProvider};
use tuneweave_provider_kuwo::{KuwoConfig, KuwoProvider};
use tuneweave_provider_migu::{MiguConfig, MiguProvider};
use tuneweave_provider_netease::{NeteaseConfig, NeteaseProvider};
use tuneweave_provider_qq::{QqConfig, QqProvider};
use tuneweave_provider_soda::{SodaConfig, SodaProvider};
use tuneweave_server::{AppState, build_router};

struct Running {
    stop: oneshot::Sender<()>,
    worker: thread::JoinHandle<()>,
    endpoint: String,
    token: String,
}
static INSTANCE: OnceLock<Mutex<Option<Running>>> = OnceLock::new();

async fn authorize(
    State(token): State<Arc<String>>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    if request
        .headers()
        .get("x-linsen-runtime-token")
        .and_then(|h| h.to_str().ok())
        != Some(token.as_str())
    {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(next.run(request).await)
}

fn registry(dir: &std::path::Path) -> Result<ProviderRegistry, String> {
    std::fs::create_dir_all(dir).map_err(|_| "cannot create runtime directory")?;
    let store: Arc<dyn AccountCredentialStore> = Arc::new(
        FileAccountCredentialStore::open(dir.join("accounts"))
            .map_err(|_| "cannot open credential store")?,
    );
    let mut providers = ProviderRegistry::new();
    providers
        .register_arc(Arc::new(
            NeteaseProvider::new(NeteaseConfig {
                credential_store: Some(store.clone()),
                ..Default::default()
            })
            .map_err(|_| "netease initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            QqProvider::new(QqConfig {
                credential_store: Some(store.clone()),
                device_path: Some(dir.join("qq-device.json")),
                ..Default::default()
            })
            .map_err(|_| "qq initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            BilibiliProvider::new(BilibiliConfig {
                credential_store: Some(store.clone()),
                ..Default::default()
            })
            .map_err(|_| "bilibili initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            KugouProvider::new(KugouConfig {
                credential_store: Some(store.clone()),
                device_path: Some(dir.join("kugou-device.json")),
                ..Default::default()
            })
            .map_err(|_| "kugou initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            KuwoProvider::new(KuwoConfig {
                credential_store: Some(store.clone()),
                ..Default::default()
            })
            .map_err(|_| "kuwo initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            MiguProvider::new(MiguConfig {
                credential_store: Some(store.clone()),
                device_path: Some(dir.join("migu-device.json")),
                ..Default::default()
            })
            .map_err(|_| "migu initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    providers
        .register_arc(Arc::new(
            SodaProvider::new(SodaConfig {
                credential_store: Some(store),
                device_path: Some(dir.join("soda-device.json")),
                ..Default::default()
            })
            .map_err(|_| "soda initialization failed")?,
        ))
        .map_err(|_| "duplicate provider")?;
    Ok(providers)
}

pub fn start(dir: PathBuf) -> Result<serde_json::Value, String> {
    let mut slot = INSTANCE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| "runtime lock unavailable")?;
    if let Some(running) = slot.as_ref() {
        return Ok(serde_json::json!({"endpoint":running.endpoint,"token":running.token}));
    }
    let token: String = rand::rng()
        .sample_iter(Alphanumeric)
        .take(48)
        .map(char::from)
        .collect();
    let thread_token = token.clone();
    let (ready_tx, ready_rx) = mpsc::sync_channel(1);
    let (stop_tx, stop_rx) = oneshot::channel();
    let worker = thread::spawn(move || {
        let result = (|| -> Result<_, String> {
            let providers = registry(&dir)?;
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .map_err(|_| "cannot create async runtime")?;
            Ok((providers, runtime))
        })();
        match result {
            Err(error) => { let _ = ready_tx.send(Err(error)); }
            Ok((providers, runtime)) => runtime.block_on(async move {
                let listener = match tokio::net::TcpListener::bind("127.0.0.1:0").await {
                    Ok(listener) => listener,
                    Err(_) => { let _ = ready_tx.send(Err("cannot bind loopback listener".into())); return; }
                };
                let endpoint = match listener.local_addr() { Ok(address) => format!("http://{address}"), Err(_) => { let _ = ready_tx.send(Err("cannot read listener address".into())); return; } };
                let state = AppState::new(providers, Platform::Netease);
                let app = build_router(state).layer(middleware::from_fn_with_state(Arc::new(thread_token), authorize));
                if ready_tx.send(Ok(endpoint)).is_err() { return; }
                use std::future::IntoFuture;
                let (graceful_tx, graceful_rx) = oneshot::channel::<()>();
                let server = axum::serve(listener, app).with_graceful_shutdown(async { let _ = graceful_rx.await; }).into_future();
                tokio::pin!(server);
                tokio::select! {
                    _ = &mut server => {},
                    _ = stop_rx => {
                        let _ = graceful_tx.send(());
                        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), &mut server).await;
                    }
                }
            }),
        }
    });
    let endpoint = match ready_rx.recv() {
        Ok(Ok(endpoint)) => endpoint,
        Ok(Err(error)) => {
            let _ = worker.join();
            return Err(error);
        }
        Err(_) => {
            let _ = worker.join();
            return Err("runtime exited during startup".into());
        }
    };
    *slot = Some(Running {
        stop: stop_tx,
        worker,
        endpoint: endpoint.clone(),
        token: token.clone(),
    });
    Ok(serde_json::json!({"endpoint":endpoint,"token":token}))
}

pub fn stop() {
    if let Ok(mut slot) = INSTANCE.get_or_init(|| Mutex::new(None)).lock() {
        if let Some(running) = slot.take() {
            let _ = running.stop.send(());
            let _ = running.worker.join();
        }
    }
}

/// Returns an allocated UTF-8 JSON object. Caller must release it with linsen_runtime_free.
/// SAFETY: directory must be a valid, NUL-terminated UTF-8 string for the duration of the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn linsen_runtime_start(directory: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if directory.is_null() {
            return Err("missing directory".to_owned());
        }
        let dir = unsafe { CStr::from_ptr(directory) }
            .to_str()
            .map_err(|_| "invalid directory encoding".to_owned())?;
        start(PathBuf::from(dir))
    });
    let value = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => serde_json::json!({"error":error}),
        Err(_) => serde_json::json!({"error":"runtime initialization panic"}),
    };
    CString::new(value.to_string())
        .expect("JSON cannot contain NUL")
        .into_raw()
}
#[unsafe(no_mangle)]
pub extern "C" fn linsen_runtime_stop() {
    let _ = std::panic::catch_unwind(stop);
}
/// SAFETY: value must be an outstanding pointer returned by linsen_runtime_start; release once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn linsen_runtime_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn runtime_is_idempotent_and_requires_token() {
        let dir = std::env::temp_dir().join(format!("linsen-runtime-test-{}", std::process::id()));
        let first = start(dir.clone()).unwrap();
        assert_eq!(start(dir.clone()).unwrap(), first);
        let address = first["endpoint"]
            .as_str()
            .unwrap()
            .trim_start_matches("http://");
        use std::io::{Read, Write};
        let mut connection = std::net::TcpStream::connect(address).unwrap();
        connection
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        connection
            .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        connection.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 401"));
        let mut connection = std::net::TcpStream::connect(address).unwrap();
        connection
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        write!(connection,"GET /healthz HTTP/1.1\r\nHost: localhost\r\nX-Linsen-Runtime-Token: {}\r\nConnection: close\r\n\r\n",first["token"].as_str().unwrap()).unwrap();
        response.clear();
        connection.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 200"));
        stop();
        stop();
        assert!(std::net::TcpStream::connect(address).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
