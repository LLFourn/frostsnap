use super::{
    coordinator::Coordinator, log::LogLevel, psbt_manager::PsbtManager, settings::Settings,
};
use crate::{
    coordinator::FfiCoordinator,
    frb_generated::{RustAutoOpaque, StreamSink},
};
use anyhow::{Context as _, Result};
use frostsnap_coordinator::{DesktopSerial, UsbSerialManager, ValidatedFirmwareBin};
use frostsnap_core::schnorr_fun::fun::{marker::EvenY, Point};
use std::{
    path::PathBuf,
    str::FromStr,
    sync::{Arc, Mutex},
};
use tracing::{event, Level};
use tracing_subscriber::filter::Targets;
use tracing_subscriber::{layer::SubscriberExt as _, util::SubscriberInitExt, Registry};

impl super::Api {
    pub fn turn_logging_on(&self, level: LogLevel, log_stream: StreamSink<String>) -> Result<()> {
        // Global default subscriber must only be set once.
        if crate::logger::set_dart_logger(log_stream) {
            let targets = Targets::new()
                .with_target("nusb", Level::ERROR /* nusb makes spurious warnings */)
                .with_target("bdk_electrum_streaming", Level::WARN)
                .with_default(Level::from(level));

            #[cfg(not(target_os = "android"))]
            {
                let fmt_layer = tracing_subscriber::fmt::layer().without_time().pretty();

                Registry::default()
                    .with(targets.clone())
                    .with(fmt_layer)
                    .with(crate::logger::dart_logger())
                    .try_init()?;
            }

            #[cfg(target_os = "android")]
            {
                use tracing_logcat::{LogcatMakeWriter, LogcatTag};
                use tracing_subscriber::{fmt::format::Format, layer::Layer};

                let writer = LogcatMakeWriter::new(LogcatTag::Fixed("frostsnap/rust".to_owned()))
                    .expect("logcat writer");

                let fmt_layer = tracing_subscriber::fmt::layer()
                    .event_format(Format::default().with_target(true).without_time().compact())
                    .with_writer(writer)
                    .with_ansi(false)
                    .with_filter(targets.clone());

                Registry::default()
                    .with(targets.clone())
                    .with(fmt_layer)
                    .with(crate::logger::dart_logger())
                    .try_init()?;
            }

            event!(Level::INFO, "Rust tracing initialised");
        }
        Ok(())
    }

    // Android-specific function that returns FfiSerial
    pub fn load_host_handles_serial(
        &self,
        app_dir: String,
    ) -> Result<(Coordinator, AppCtx, super::port::FfiSerial)> {
        use super::port::FfiSerial;
        let app_dir = PathBuf::from_str(&app_dir)?;
        let ffi_serial = FfiSerial::default();
        let mut usb_manager = UsbSerialManager::new(Box::new(ffi_serial.clone()));
        if let Some(firmware) = crate::FIRMWARE.map(ValidatedFirmwareBin::new).transpose()? {
            usb_manager = usb_manager.with_firmware_bin(firmware);
        }
        if let Some(key) = load_genuine_cert_key() {
            usb_manager = usb_manager.with_genuine_cert_key(key);
        }
        let (coord, app_state) = load_internal(app_dir, usb_manager)?;
        Ok((coord, app_state, ffi_serial))
    }

    // Desktop function using DesktopSerial
    pub fn load(&self, app_dir: String) -> anyhow::Result<(Coordinator, AppCtx)> {
        let app_dir = PathBuf::from_str(&app_dir)?;
        let mut usb_manager = UsbSerialManager::new(Box::new(DesktopSerial));
        if let Some(firmware) = crate::FIRMWARE.map(ValidatedFirmwareBin::new).transpose()? {
            usb_manager = usb_manager.with_firmware_bin(firmware);
        }
        if let Some(key) = load_genuine_cert_key() {
            usb_manager = usb_manager.with_genuine_cert_key(key);
        }
        load_internal(app_dir, usb_manager)
    }

    /// Build the real `Coordinator` bound to a host virtual device instead of real
    /// USB serial — for the simulator only (the sim Dart entrypoint, sim-5). The
    /// returned [`DevicePool`] owns the device thread; drop it to stop the device.
    ///
    /// Sim firmware is self-contained ([`super::sim::sim_firmware_bin`]): the manager's
    /// latest firmware and the device's announced digest both come from it, so the device
    /// reads as up-to-date/compatible (no upgrade is ever offered). No genuine cert key is
    /// wired in, so genuine-check is off (consistent with the sim guard). Production
    /// `load()`/`main.dart` never reach this.
    /// Debug/sim-only: bind the app to a host virtual device. Compiled
    /// unconditionally; only the `--dart-define=SIM` entrypoint calls it, so a normal
    /// build dead-code-eliminates the Dart branch and never reaches it. See `api::sim`.
    pub fn load_sim(
        &self,
        app_dir: String,
        seed: u64,
        device_count: u32,
    ) -> Result<(Coordinator, AppCtx, super::sim::DevicePool)> {
        use super::sim::{sim_firmware_bin, DevicePool, SimDevice, SimFrame};
        use frostsnap_virtual_device::{
            device_link, pipe, DeviceChannel, LinkGate, ParentLink, PipeByteIo, VirtualDevice,
            VirtualSerial,
        };

        let app_dir = PathBuf::from_str(&app_dir)?;
        let firmware = sim_firmware_bin();
        let count = device_count.max(1) as usize;

        // Wire the devices as a daisy chain (real hardware's topology): device 0 hangs off
        // the single coordinator USB port; every device below it hangs off the previous
        // device's downstream port. Each inter-device link shares one gate that is BOTH
        // device i's downstream-detect AND device i+1's plug control, so cutting a link
        // makes the real firmware tear the subtree off the bus (no sim disconnect logic).
        let mut upstream_ios: Vec<Option<PipeByteIo>> = (0..count).map(|_| None).collect();
        let mut downstream_ios: Vec<Option<PipeByteIo>> = (0..count).map(|_| None).collect();
        let mut downstream_gates: Vec<Option<LinkGate>> = (0..count).map(|_| None).collect();
        let mut parent_links: Vec<Option<ParentLink>> = (0..count).map(|_| None).collect();

        // device 0's upstream is the coordinator port; keep the host end for the serial.
        let (up0_io, host0) = pipe();
        upstream_ios[0] = Some(up0_io);
        for i in 0..count - 1 {
            let (parent_io, child_io, gate) = device_link();
            downstream_ios[i] = Some(parent_io); // device i's downstream
            upstream_ios[i + 1] = Some(child_io); // device i+1's upstream
            downstream_gates[i] = Some(gate.clone()); // device i's downstream-detect
            parent_links[i + 1] = Some(ParentLink::Cable(gate)); // device i+1's plug control
        }

        // Spawn each device thread on its wired links (distinct seed -> distinct id),
        // keeping a per-device frame sink. The tail device has a peerless downstream.
        let mut spawned = Vec::with_capacity(count);
        let mut frame_sinks = Vec::with_capacity(count);
        for i in 0..count {
            let frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>> = Arc::new(Mutex::new(None));
            let on_frame_sink = frames_sink.clone();
            let upstream_io = upstream_ios[i].take().expect("each device has an upstream");
            let downstream_io = downstream_ios[i]
                .take()
                .unwrap_or_else(PipeByteIo::disconnected);
            let downstream_present = downstream_gates[i].take();
            let dev = VirtualDevice::spawn_chained(
                seed.wrapping_add(i as u64),
                firmware.digest(),
                upstream_io,
                downstream_io,
                downstream_present,
                move |width, height, data| {
                    if let Some(sink) = &*on_frame_sink.lock().unwrap() {
                        let _ = sink.add(SimFrame {
                            width,
                            height,
                            data,
                        });
                    }
                },
            );
            frame_sinks.push(frames_sink);
            spawned.push(dev);
        }

        // The coordinator sees exactly ONE port (device 0); it learns devices 1..N from
        // the Announce messages the chain relays upstream.
        let virtual_serial = VirtualSerial::single("sim-device-0", host0);
        parent_links[0] = Some(ParentLink::Usb(virtual_serial.connection()));
        let usb_manager =
            UsbSerialManager::new(Box::new(virtual_serial)).with_firmware_bin(firmware);
        let (coord, app_state) = load_internal(app_dir.clone(), usb_manager)?;

        // One device-input channel + Dart handle per device. Each is numbered 1-based;
        // the channel binds `device-<number>.sock` and the handle carries its parent-link
        // plug control. Dropping the pool stops every channel + removes every socket file.
        let mut channels = Vec::with_capacity(count);
        let mut devices = Vec::with_capacity(count);
        for (i, (dev, frames_sink)) in spawned.iter().zip(frame_sinks).enumerate() {
            let number = (i + 1) as u32;
            let parent = parent_links[i]
                .take()
                .expect("every device has a parent link");
            let socket = app_dir.join(format!("device-{number}.sock"));
            channels.push(DeviceChannel::serve(
                socket,
                dev.touch.clone(),
                dev.framebuffer.clone(),
                parent.clone(),
                dev.device_id,
            )?);
            devices.push(SimDevice::new(
                number,
                dev.device_id,
                dev.touch.clone(),
                dev.framebuffer.clone(),
                frames_sink,
                parent,
            ));
        }

        let pool = DevicePool::new(spawned, channels, devices);

        Ok((coord, app_state, pool))
    }
}

#[cfg(genuine_cert_key)]
fn load_genuine_cert_key() -> Option<Point<EvenY>> {
    const HEX: &str = include_str!(concat!(env!("OUT_DIR"), "/genuine_cert_key.hex"));
    let bytes = frostsnap_core::hex::decode(HEX.trim()).ok()?;
    let array: [u8; 32] = bytes.try_into().ok()?;
    Point::<EvenY>::from_xonly_bytes(array)
}

#[cfg(not(genuine_cert_key))]
fn load_genuine_cert_key() -> Option<Point<EvenY>> {
    None
}

fn load_internal(
    app_dir: PathBuf,
    usb_serial_manager: UsbSerialManager,
) -> Result<(Coordinator, AppCtx)> {
    let db_file = app_dir.join("frostsnap.sqlite");
    event!(
        Level::INFO,
        path = db_file.display().to_string(),
        "initializing database"
    );
    let db = rusqlite::Connection::open(&db_file).with_context(|| {
        event!(
            Level::ERROR,
            path = db_file.display().to_string(),
            "failed to load database"
        );
        format!("failed to load database from {}", db_file.display())
    })?;
    let db = Arc::new(Mutex::new(db));

    let coordinator = FfiCoordinator::new(db.clone(), usb_serial_manager)?;
    let coordinator = Coordinator(coordinator);
    let app_state = AppCtx {
        settings: RustAutoOpaque::new(Settings::new(db.clone(), app_dir)?),
        psbt_manager: RustAutoOpaque::new(PsbtManager::new(db.clone())),
    };
    println!("loaded db");

    Ok((coordinator, app_state))
}

pub struct AppCtx {
    pub settings: RustAutoOpaque<Settings>,
    pub psbt_manager: RustAutoOpaque<PsbtManager>,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
    flutter_rust_bridge::setup_default_user_utils();
}
