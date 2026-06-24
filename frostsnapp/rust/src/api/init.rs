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
        use super::sim::{build_device, make_frame_sink, sim_firmware_bin, DevicePool};
        use frostsnap_virtual_device::{
            ByteChannel, ChainRouter, HostEnd, SlotSpec, VirtualSerial,
        };

        let app_dir = PathBuf::from_str(&app_dir)?;
        let firmware = sim_firmware_bin();
        let digest = firmware.digest();
        let count = device_count.max(1) as usize;

        // One coordinator port; the router splices it to the head and relays the chain, so
        // the coordinator sees exactly ONE port and learns the rest via the firmware relay.
        let coord_host = HostEnd {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        };
        let virtual_serial = VirtualSerial::single("sim-device-0", coord_host.clone());
        let port = virtual_serial.connection();
        let usb_manager =
            UsbSerialManager::new(Box::new(virtual_serial)).with_firmware_bin(firmware);
        let (coordinator, app_state) = load_internal(app_dir.clone(), usb_manager)?;

        // One power slot per device, each with its own frame sink. The slot owns what
        // survives a power-cycle (flash + screen/touch + links); the router boots them,
        // owns the chain order, and powers devices on/off as chain membership changes — so
        // any device can connect independently and the order is reconfigurable at runtime.
        let mut specs = Vec::with_capacity(count);
        let mut frame_sinks = Vec::with_capacity(count);
        for i in 0..count {
            let (frames_sink, on_frame) = make_frame_sink();
            specs.push(SlotSpec {
                seed: seed.wrapping_add(i as u64),
                digest,
                on_frame,
            });
            frame_sinks.push(frames_sink);
        }

        // The router owns the device slots; initial chain = all devices in number order.
        let router = Arc::new(ChainRouter::new(
            coord_host,
            port,
            specs,
            (0..count).collect(),
        ));

        // One device-input channel + Dart handle per device (numbered 1-based), each wired
        // to the slot's STABLE handles (so it keeps driving the device across power-cycles)
        // plus the shared router (so connect/disconnect edits the one chain config). The same
        // build path `DevicePool::add_device` uses for a runtime-added device.
        let mut channels = Vec::with_capacity(count);
        let mut devices = Vec::with_capacity(count);
        for (i, frames_sink) in frame_sinks.into_iter().enumerate() {
            let (channel, device) = build_device(&router, &app_dir, i, frames_sink)?;
            channels.push(channel);
            devices.push(device);
        }

        let pool = DevicePool::new(seed, app_dir, router, channels, devices);

        Ok((coordinator, app_state, pool))
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
