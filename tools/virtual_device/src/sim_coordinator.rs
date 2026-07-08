//! A pure-Rust coordinator driver that mirrors the message-routing core of the
//! app's `FfiCoordinator` poll loop (`frostsnapp/rust/src/coordinator.rs`), minus
//! everything that needs Flutter or persistence. It owns the same three pieces the
//! app does — a [`FrostCoordinator`] (the keygen/signing protocol), a
//! [`UsbSerialManager`] + its [`UsbSender`] (pure transport), and the active
//! [`KeyGen`] `UiProtocol` — and exposes one [`SimCoordinator::step`] that performs
//! the identical poll → route → drain sequence.
//!
//! # What this OMITS vs `FfiCoordinator` (intentional for the sim)
//! - **DB persistence**: `FfiCoordinator` wraps the coordinator/device-names/backup
//!   state in `Persisted<_>` and calls `staged_mutate` to write a sqlite WAL on every
//!   device message. We call `recv_device_message` / `finalize_keygen` directly — sim
//!   state is in-memory and discarded with the test.
//! - **`StreamSink`**: no Flutter, so `KeyGenState` goes to a plain in-memory
//!   [`Sink`] ([`StateCell`]) instead of an FFI stream.
//! - **`UiStack` breadth**: `FfiCoordinator` routes `ToUser` messages and
//!   `poll()`s a whole stack of `UiProtocol`s (signing, backup, recovery,
//!   verify-address, …). We drive exactly one protocol — `KeyGen` — which is all a
//!   1-of-1 keygen needs.
//! - **Recovery mode**: no `has_backups_that_need_to_be_consolidated` /
//!   `set_recovery_mode` handling.
//! - **Firmware-upgrade gating**: no `needs_firmware_upgrade` checks and no
//!   `run_firmware_upgrade` branch. This is deliberate and consistent with the sim
//!   guard: [`SimFirmware`](crate::SimFirmware) never advertises an upgradeable
//!   digest, so the manager never offers an upgrade and
//!   [`VirtualDevice::upgrades_offered`](crate::VirtualDevice::upgrades_offered)
//!   stays `0`.
//! - **`device_list` / `DeviceListUpdate`** bookkeeping and the cancel-on-abort
//!   (`clean_finished`) plumbing.
//!
//! # sim-4 convergence
//! When the app/FFI is wired into this harness, the sim and the app should converge
//! on a single coordinator driver rather than maintaining two copies of this routing
//! loop. The clean move is to lift the FFI-agnostic core of this routing
//! (poll_ports → recv_device_message → fan `CoordinatorSend` out over `UsbSender`,
//! drive `UiProtocol::poll`) into `frostsnap_coordinator` itself, leaving
//! `FfiCoordinator` to add only the db/`StreamSink`/`UiStack` layers on top.

use std::sync::{Arc, Mutex};

use frostsnap_comms::{CoordinatorSendBody, CoordinatorSendMessage, Destination, DeviceName};
use frostsnap_coordinator::{
    keygen::{KeyGen, KeyGenState},
    AppMessageBody, DeviceChange, Sink, UiProtocol, UsbSender, UsbSerialManager,
};
use frostsnap_core::{
    coordinator::{CoordinatorSend, FrostCoordinator},
    AccessStructureRef, DeviceId, KeygenId, SymmetricKey,
};

/// A `Sink<KeyGenState>` that keeps only the latest state in a shared cell. The
/// `Send + 'static` bound on [`Sink`] is why this is `Arc<Mutex<_>>` and not
/// `Rc<RefCell<_>>`.
#[derive(Clone, Default)]
pub struct StateCell(Arc<Mutex<Option<KeyGenState>>>);

impl StateCell {
    pub fn new() -> Self {
        Self::default()
    }

    /// The most recently emitted keygen state, if any.
    pub fn get(&self) -> Option<KeyGenState> {
        self.0.lock().unwrap().clone()
    }
}

impl Sink<KeyGenState> for StateCell {
    fn send(&self, state: KeyGenState) {
        *self.0.lock().unwrap() = Some(state);
    }
}

/// The collected output of one [`SimCoordinator::step`].
#[derive(Default)]
pub struct StepOutcome {
    /// Device ids that became `Registered` this step.
    pub registered: Vec<DeviceId>,
    /// `AppMessageBody::Misc` messages were received and ignored this step (the sim
    /// has no `UiStack` to route comms-misc into).
    pub ignored_misc: usize,
}

/// The Rust-level coordinator: protocol + transport + the active keygen UI protocol.
pub struct SimCoordinator {
    coordinator: FrostCoordinator,
    manager: UsbSerialManager,
    usb_sender: UsbSender,
    keygen: Option<KeyGen>,
    device_name: String,
}

impl SimCoordinator {
    /// Build a coordinator over the given transport manager. `device_name` is the
    /// name assigned to any device that asks for one during the handshake.
    pub fn new(manager: UsbSerialManager, device_name: impl Into<String>) -> Self {
        let usb_sender = manager.usb_sender();
        Self {
            coordinator: FrostCoordinator::new(),
            manager,
            usb_sender,
            keygen: None,
            device_name: device_name.into(),
        }
    }

    fn device_name(&self) -> DeviceName {
        self.device_name
            .clone()
            .try_into()
            .expect("valid sim device name")
    }

    pub fn coordinator_mut(&mut self) -> &mut FrostCoordinator {
        &mut self.coordinator
    }

    pub fn usb_sender(&self) -> &UsbSender {
        &self.usb_sender
    }

    /// Register a fresh `KeyGen` protocol as the active one and flush its first batch
    /// of outgoing (begin) messages to the device.
    pub fn set_keygen(&mut self, mut keygen: KeyGen) {
        keygen.emit_state();
        for message in keygen.poll() {
            self.usb_sender.send(message);
        }
        self.keygen = Some(keygen);
    }

    /// The id of the active keygen protocol.
    pub fn keygen_id(&self) -> Option<KeygenId> {
        self.keygen.as_ref().map(|keygen| keygen.keygen_id())
    }

    /// One poll cycle, mirroring the `FfiCoordinator` loop body
    /// (`frostsnapp/rust/src/coordinator.rs`):
    /// 1. drain `poll_ports()`, accepting names and collecting `AppMessage`s;
    /// 2. route each `AppMessageBody::Core` into `recv_device_message`, fanning
    ///    `ToDevice` out over `UsbSender` and `ToUser` into the keygen protocol;
    /// 3. drain the keygen protocol's outgoing messages over `UsbSender`.
    pub fn step(&mut self) -> StepOutcome {
        let mut outcome = StepOutcome::default();
        let mut app_messages = vec![];

        for change in self.manager.poll_ports() {
            match change {
                DeviceChange::Registered { id, .. } => outcome.registered.push(id),
                // Prompt the device to confirm its name: it shows the NewName screen
                // and waits for a hold-to-confirm. The device-side confirm sets the
                // pending name that keygen finalize requires (an unnamed device panics
                // on FinalizeKeyGen), so this real naming flow is load-bearing — not
                // the coordinator-side `accept_device_name` shortcut.
                DeviceChange::NeedsName { id } => {
                    self.usb_sender.finish_naming(id, self.device_name());
                }
                // The device confirmed its name (sent SetName). Record it
                // coordinator-side so the registration gate fires (mirrors
                // FfiCoordinator's NameChange -> accept_device_name).
                DeviceChange::NameChange { id, name } => {
                    self.manager.accept_device_name(id, name);
                }
                DeviceChange::AppMessage(app_message) => app_messages.push(app_message),
                _ => {}
            }
        }

        for app_message in app_messages {
            match app_message.body {
                AppMessageBody::Core(boxed) => {
                    match self
                        .coordinator
                        .recv_device_message(app_message.from, *boxed)
                    {
                        Ok(sends) => self.route_coordinator_sends(sends),
                        Err(e) => panic!("device message rejected by coordinator: {e}"),
                    }
                }
                AppMessageBody::Misc(_) => outcome.ignored_misc += 1,
            }
        }

        if let Some(keygen) = &mut self.keygen {
            for message in keygen.poll() {
                self.usb_sender.send(message);
            }
        }

        outcome
    }

    fn route_coordinator_sends(&mut self, sends: Vec<CoordinatorSend>) {
        for send in sends {
            match send {
                CoordinatorSend::ToDevice {
                    message,
                    destinations,
                } => {
                    self.usb_sender.send(CoordinatorSendMessage {
                        target_destinations: Destination::from(destinations),
                        message_body: CoordinatorSendBody::Core(message),
                    });
                }
                CoordinatorSend::ToUser(msg) => {
                    if let Some(keygen) = &mut self.keygen {
                        keygen.process_to_user_message(msg);
                    }
                }
            }
        }
    }

    /// Finalize the active keygen: write the new key, forward `FinishKeygen` to the
    /// device, and tell the keygen protocol it finished. Mirrors
    /// `FfiCoordinator::finalize_keygen` minus the db/backup-run side effects.
    pub fn finalize_keygen(
        &mut self,
        encryption_key: SymmetricKey,
        rng: &mut impl rand_core::RngCore,
    ) -> AccessStructureRef {
        let keygen_id = self.keygen_id().expect("no active keygen to finalize");
        let finalized = self
            .coordinator
            .finalize_keygen(keygen_id, encryption_key, rng)
            .expect("finalize_keygen");
        let access_structure_ref = finalized.access_structure_ref;
        self.usb_sender.send_from_core(finalized);
        self.keygen
            .as_mut()
            .expect("active keygen")
            .keygen_finalized(access_structure_ref);
        access_structure_ref
    }
}
