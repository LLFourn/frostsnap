//! The device-input control channel: a SIM-only unix-socket server that drives the
//! virtual device by hardware semantics (tap/hold/swipe, read screen, plug/unplug),
//! independent of Flutter. The Flutter tray is a human convenience; automation and the
//! out-of-process driver speak THIS channel — the device is a framebuffer + a
//! touchscreen, not a widget tree, so it gets its own channel.
//!
//! Protocol: one JSON request object per line, one JSON reply object per line.
//! ```text
//!   {"cmd":"tap","x":120,"y":215}                          -> {"ok":true}
//!   {"cmd":"hold","x":120,"y":215,"ms":3000}               -> {"ok":true}
//!   {"cmd":"swipe","x1":..,"y1":..,"x2":..,"y2":..,"ms":..} -> {"ok":true}
//!   {"cmd":"touch","x":..,"y":..,"lift_up":bool}            -> {"ok":true}   (raw)
//!   {"cmd":"set_connected","connected":bool}               -> {"ok":true}
//!   {"cmd":"is_connected"}                                 -> {"ok":true,"connected":bool}
//!   {"cmd":"device_id"}                                    -> {"ok":true,"device_id":"<hex>"}
//!   {"cmd":"screen","path":"/abs/out.png"}                 -> {"ok":true,"path":"..."}
//! ```
//! Anything malformed or unknown -> `{"ok":false,"error":"..."}`.
//!
//! `hold`/`swipe` block their connection's handler thread for real wall-clock, so each
//! connection is served on its own thread; the device runs concurrently and integrates
//! the elapsed clock.

use crate::display::SharedFramebuffer;
use crate::input::DeviceInput;
use crate::touch::TouchQueue;
use crate::virtual_serial::ParentLink;
use frostsnap_core::DeviceId;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// How often the accept loop wakes to check the stop flag while idle.
const ACCEPT_POLL: Duration = Duration::from_millis(20);

/// The Arc-backed device handles the channel drives — all cheap clones of the running
/// device's peripherals.
#[derive(Clone)]
struct Handles {
    touch: TouchQueue,
    framebuffer: SharedFramebuffer,
    connection: ParentLink,
    device_id: DeviceId,
}

/// A running device-input channel. Dropping it stops the accept loop and removes the
/// socket file, so a harness `tearDown` (or process exit) leaves no residue.
pub struct DeviceChannel {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    socket_path: PathBuf,
}

impl DeviceChannel {
    /// Serve the protocol on a unix socket at `socket_path`. The handles are clones of
    /// the running device's `TouchQueue` / `SharedFramebuffer` / `ParentLink` (its
    /// plug control) plus its id. A stale socket file at the path is removed first.
    pub fn serve(
        socket_path: PathBuf,
        touch: TouchQueue,
        framebuffer: SharedFramebuffer,
        connection: ParentLink,
        device_id: DeviceId,
    ) -> std::io::Result<Self> {
        let _ = std::fs::remove_file(&socket_path);
        let listener = UnixListener::bind(&socket_path)?;
        listener.set_nonblocking(true)?;

        let handles = Handles {
            touch,
            framebuffer,
            connection,
            device_id,
        };
        let stop = Arc::new(AtomicBool::new(false));
        let accept_stop = stop.clone();
        let join = thread::spawn(move || accept_loop(listener, accept_stop, handles));

        Ok(Self {
            stop,
            join: Some(join),
            socket_path,
        })
    }

    /// The socket path clients connect to.
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }
}

impl Drop for DeviceChannel {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

fn accept_loop(listener: UnixListener, stop: Arc<AtomicBool>, handles: Handles) {
    while !stop.load(Ordering::Relaxed) {
        match listener.accept() {
            Ok((stream, _)) => {
                let handles = handles.clone();
                // Handlers are detached: a client EOF ends one, and the channel (and
                // any blocked handler) dies with the process. Teardown is the accept
                // loop stopping + the socket file being removed, which leave no residue.
                thread::spawn(move || handle_conn(stream, handles));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL);
            }
            Err(_) => break,
        }
    }
}

fn handle_conn(stream: UnixStream, handles: Handles) {
    // The listener is non-blocking for accept-polling; the accepted stream must block
    // so `read_line` waits for the next command instead of spinning.
    if stream.set_nonblocking(false).is_err() {
        return;
    }
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    let mut writer = stream;
    let input = DeviceInput::new(handles.touch.clone());

    for line in BufReader::new(read_half).lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = dispatch(&line, &input, &handles);
        if writeln!(writer, "{reply}").is_err() || writer.flush().is_err() {
            break;
        }
    }
}

fn dispatch(line: &str, input: &DeviceInput, handles: &Handles) -> Value {
    let req: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(e) => return err(format!("invalid json: {e}")),
    };

    // Field extractors that fail the whole command with a clear message.
    let int = |k: &str| -> Result<i32, String> {
        req.get(k)
            .and_then(Value::as_i64)
            .map(|v| v as i32)
            .ok_or_else(|| format!("missing/invalid integer field `{k}`"))
    };
    let millis = |k: &str| -> Result<u64, String> {
        req.get(k)
            .and_then(Value::as_u64)
            .ok_or_else(|| format!("missing/invalid duration field `{k}`"))
    };
    let boolean = |k: &str| -> Result<bool, String> {
        req.get(k)
            .and_then(Value::as_bool)
            .ok_or_else(|| format!("missing/invalid bool field `{k}`"))
    };
    let string = |k: &str| -> Result<String, String> {
        req.get(k)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("missing/invalid string field `{k}`"))
    };

    let result: Result<Value, String> = (|| match req.get("cmd").and_then(Value::as_str) {
        Some("tap") => {
            input.tap(int("x")?, int("y")?);
            Ok(ok())
        }
        Some("hold") => {
            input.hold(int("x")?, int("y")?, Duration::from_millis(millis("ms")?));
            Ok(ok())
        }
        Some("swipe") => {
            input.swipe(
                int("x1")?,
                int("y1")?,
                int("x2")?,
                int("y2")?,
                Duration::from_millis(millis("ms")?),
            );
            Ok(ok())
        }
        Some("touch") => {
            input.raw(int("x")?, int("y")?, boolean("lift_up")?);
            Ok(ok())
        }
        Some("set_connected") => {
            handles.connection.set_connected(boolean("connected")?);
            Ok(ok())
        }
        Some("is_connected") => {
            Ok(json!({"ok": true, "connected": handles.connection.is_connected()}))
        }
        Some("device_id") => Ok(json!({"ok": true, "device_id": handles.device_id.to_string()})),
        Some("screen") => {
            let path = string("path")?;
            handles
                .framebuffer
                .save_png(&path)
                .map_err(|e| format!("save_png failed: {e}"))?;
            Ok(json!({"ok": true, "path": path}))
        }
        Some(other) => Err(format!("unknown cmd: {other}")),
        None => Err("missing `cmd`".to_string()),
    })();

    result.unwrap_or_else(err)
}

fn ok() -> Value {
    json!({"ok": true})
}

fn err(message: String) -> Value {
    json!({"ok": false, "error": message})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firmware::SimFirmware;
    use crate::VirtualDevice;
    use crate::VirtualSerial;

    /// Send one request line, read one reply line, parse it.
    fn req(reader: &mut impl BufRead, writer: &mut UnixStream, line: &str) -> Value {
        writeln!(writer, "{line}").unwrap();
        writer.flush().unwrap();
        let mut reply = String::new();
        reader.read_line(&mut reply).unwrap();
        serde_json::from_str(&reply).unwrap()
    }

    #[test]
    fn device_channel_round_trips_over_the_socket() {
        let spawned = VirtualDevice::spawn(11, SimFirmware::PLACEHOLDER_DIGEST, |_, _, _| {});
        let serial = VirtualSerial::single("sim-0", spawned.host.clone().unwrap());
        let connection = ParentLink::Usb(serial.connection());

        // A dedicated temp dir so the socket + screen PNG are cleaned up together.
        let dir = std::env::temp_dir().join("frostsnap-devchan-roundtrip");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let sock = dir.join("device.sock");

        let channel = DeviceChannel::serve(
            sock.clone(),
            spawned.touch.clone(),
            spawned.framebuffer.clone(),
            connection,
            spawned.device_id,
        )
        .unwrap();

        let mut writer = UnixStream::connect(&sock).unwrap();
        let mut reader = BufReader::new(writer.try_clone().unwrap());

        // Input commands just acknowledge (the events land on the TouchQueue).
        assert_eq!(
            req(&mut reader, &mut writer, r#"{"cmd":"tap","x":1,"y":2}"#)["ok"],
            json!(true)
        );
        assert_eq!(
            req(
                &mut reader,
                &mut writer,
                r#"{"cmd":"hold","x":1,"y":2,"ms":1}"#
            )["ok"],
            json!(true)
        );
        assert_eq!(
            req(
                &mut reader,
                &mut writer,
                r#"{"cmd":"swipe","x1":1,"y1":9,"x2":1,"y2":2,"ms":1}"#
            )["ok"],
            json!(true)
        );
        // raw touch primitive (a press; down/move/up are touch with lift_up false/false/true).
        assert_eq!(
            req(
                &mut reader,
                &mut writer,
                r#"{"cmd":"touch","x":3,"y":4,"lift_up":false}"#
            )["ok"],
            json!(true)
        );

        // device_id matches the spawned device.
        let id = req(&mut reader, &mut writer, r#"{"cmd":"device_id"}"#);
        assert_eq!(id["device_id"], json!(spawned.device_id.to_string()));

        // plug state round-trips.
        assert_eq!(
            req(
                &mut reader,
                &mut writer,
                r#"{"cmd":"set_connected","connected":false}"#
            )["ok"],
            json!(true)
        );
        let conn = req(&mut reader, &mut writer, r#"{"cmd":"is_connected"}"#);
        assert_eq!(conn["connected"], json!(false));

        // screen writes a PNG to the requested path.
        let png = dir.join("screen.png");
        let shot = req(
            &mut reader,
            &mut writer,
            &format!(r#"{{"cmd":"screen","path":"{}"}}"#, png.display()),
        );
        assert_eq!(shot["ok"], json!(true));
        assert!(png.exists() && std::fs::metadata(&png).unwrap().len() > 0);

        // unknown command is a clean error, not a hangup.
        let bad = req(&mut reader, &mut writer, r#"{"cmd":"nope"}"#);
        assert_eq!(bad["ok"], json!(false));

        // Dropping the channel removes the socket file (no residue).
        drop(writer);
        drop(reader);
        drop(channel);
        assert!(!sock.exists(), "socket file removed on drop");

        let _ = std::fs::remove_dir_all(&dir);
        drop(spawned);
    }
}
