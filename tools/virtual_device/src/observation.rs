//! `SimObservation`: the sim's read-only eyes on a device's ACTIVE screen.
//!
//! `FrostyUi` is `!Send` and lives inside the device thread, so UI state can't
//! be inspected from outside. Instead the thread's `ObservedUi` publishes
//! PLAIN DATA into this `Arc` — the same crossing pattern as
//! [`SharedFramebuffer`](crate::SharedFramebuffer). Nothing UI-typed crosses
//! the boundary, and values follow the active screen: replaced when the active
//! widget changes (`set_workflow` / `go_to_default`) with the lock held across
//! the widget change itself (a reader can never see a new value describe a
//! screen that isn't active yet, or vice versa), refreshed after each `poll`,
//! cleared on reset / power-off. `set_default_workflow` only stores a future
//! return destination, so it publishes nothing.
//!
//! Backup-entry COMPLETION is an explicit, generation-keyed outcome — never
//! inferred from the screen going away. Active-screen absence is lifecycle
//! (cancel, reset, power-off all clear it); acceptance is the device's
//! `EnteredShareBackup` event, recorded by `ObservedUi` before the loop tears
//! the screen down. Each time an entry screen becomes active a new generation
//! starts, so an instrument can tell ITS run's outcome from a later run's.
//!
//! Reads are privileged sim instrumentation (the whole backup text regardless
//! of which display page is visible), not a claim about pixels.

use crate::backup_typist::EntryView;
use embedded_graphics::primitives::Rectangle;
use std::sync::{Arc, Mutex};

/// Backup-entry progress published from the device thread: the typist's
/// [`EntryView`] plus completion flags, the keyboard area (the geometry offset
/// instruments need), and the entry run this progress belongs to.
#[derive(Debug, Clone, PartialEq)]
pub struct EntryProgress {
    pub view: EntryView,
    pub finished: bool,
    pub invalid: bool,
    /// The widgets have caught up with `view` (no deferred surface swap, no
    /// tap fade playing). `view` leads the on-screen surface: a driver acting
    /// on an unsettled snapshot can have its drag dropped by the outgoing
    /// surface and its tap land on the incoming one at stale coordinates.
    pub settled: bool,
    pub keyboard_rect: Rectangle,
    pub generation: u64,
}

/// How an entry run ended. `Accepted` is terminal (the device emitted
/// `EnteredShareBackup`); `Invalid` is a bad checksum, which the on-screen
/// user could still edit away — so `Accepted` may supersede it, never the
/// reverse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryOutcome {
    Accepted,
    Invalid,
}

/// One locked read of the display state: the active display generation, the
/// text if a display screen is active, and the generation whose on-device
/// confirm (`BackupRecorded`) has fired (recorded outcomes survive clears).
#[derive(Debug, Clone, PartialEq)]
pub struct DisplaySnapshot {
    pub generation: u64,
    pub displayed: Option<String>,
    pub recorded: Option<u64>,
}

#[derive(Default)]
struct State {
    displayed_backup: Option<String>,
    entry_progress: Option<EntryProgress>,
    /// Bumped each time an entry screen becomes active.
    entry_generation: u64,
    /// The latest recorded `(generation, outcome)`. Survives clears — an
    /// instrument reads its run's outcome after the screen is gone.
    entry_outcome: Option<(u64, EntryOutcome)>,
    /// Bumped each time a display-backup screen becomes active.
    display_generation: u64,
    /// The display run whose on-device confirm fired (`BackupRecorded`).
    /// Survives clears, like entry outcomes.
    display_recorded: Option<u64>,
}

/// Thread-safe, sim-owned observation of one device's active screen. Cheap to
/// clone — clones share the state, so the handle stays live across the
/// device's power cycles (the slot hands the same one to every boot).
#[derive(Clone, Default)]
pub struct SimObservation(Arc<Mutex<State>>);

impl SimObservation {
    pub fn new() -> Self {
        Self::default()
    }

    /// The full text of the backup currently being DISPLAYED (the
    /// pen-and-paper analog), if the device is on the display-backup screen.
    pub fn displayed_backup(&self) -> Option<String> {
        self.0.lock().unwrap().displayed_backup.clone()
    }

    /// Live progress of the backup ENTRY screen, if the device is on it.
    pub fn entry_progress(&self) -> Option<EntryProgress> {
        self.0.lock().unwrap().entry_progress.clone()
    }

    /// The recorded outcome of entry run `generation`, if it has one.
    pub fn entry_outcome(&self, generation: u64) -> Option<EntryOutcome> {
        let state = self.0.lock().unwrap();
        state
            .entry_outcome
            .filter(|(gen, _)| *gen == generation)
            .map(|(_, outcome)| outcome)
    }

    /// The active widget is changing: run `apply` (the actual widget change)
    /// UNDER the lock, then publish what the new screen shows in the same
    /// critical section — readers see the old observation until the new
    /// screen is really active, and the new observation from then on.
    /// `new_entry_run` starts a fresh entry generation; a `Some`
    /// `displayed_backup` starts a fresh display generation.
    pub(crate) fn replace_active_screen(
        &self,
        displayed_backup: Option<String>,
        new_entry_run: bool,
        apply: impl FnOnce(),
    ) {
        let mut state = self.0.lock().unwrap();
        apply();
        if displayed_backup.is_some() {
            state.display_generation += 1;
        }
        state.displayed_backup = displayed_backup;
        state.entry_progress = None;
        if new_entry_run {
            state.entry_generation += 1;
        }
    }

    /// ONE coherent snapshot of the display state — a recorder's transition
    /// decisions must never combine independently sampled fields (an outcome
    /// landing between two reads would misclassify an accepted run as
    /// canceled).
    pub fn display_snapshot(&self) -> DisplaySnapshot {
        let state = self.0.lock().unwrap();
        DisplaySnapshot {
            generation: state.display_generation,
            displayed: state.displayed_backup.clone(),
            recorded: state.display_recorded,
        }
    }

    /// Record the CURRENT display run's confirm (`BackupRecorded` observed).
    pub(crate) fn record_display_confirmed(&self) {
        let mut state = self.0.lock().unwrap();
        state.display_recorded = Some(state.display_generation);
    }

    /// The generation the NEXT sampled progress belongs to.
    pub(crate) fn entry_generation(&self) -> u64 {
        self.0.lock().unwrap().entry_generation
    }

    /// Record how the CURRENT entry run ended. `Accepted` supersedes
    /// `Invalid` (an on-screen edit can fix a bad checksum); nothing
    /// supersedes `Accepted`.
    pub(crate) fn record_entry_outcome(&self, outcome: EntryOutcome) {
        let mut state = self.0.lock().unwrap();
        let generation = state.entry_generation;
        match state.entry_outcome {
            Some((gen, EntryOutcome::Accepted)) if gen == generation => {}
            _ => state.entry_outcome = Some((generation, outcome)),
        }
    }

    /// Refresh entry progress after a device `poll` (None whenever the entry
    /// screen isn't the active widget).
    pub(crate) fn set_entry_progress(&self, progress: Option<EntryProgress>) {
        self.0.lock().unwrap().entry_progress = progress;
    }

    /// Device reset / power-off: the screen is gone, so is the active-screen
    /// observation. Recorded outcomes survive (they are history, not screen
    /// state).
    pub(crate) fn clear(&self) {
        let mut state = self.0.lock().unwrap();
        state.displayed_backup = None;
        state.entry_progress = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The replacement is atomic from a reader's perspective: while the widget
    // change (`apply`) is mid-flight a reader cannot pass through, and once
    // it completes the reader sees the newly published value. Staged (the
    // widget change blocks on a channel inside the critical section) so the
    // assertion cannot race the next replacement.
    #[test]
    fn active_screen_replacement_is_atomic_with_the_widget_change() {
        use std::sync::mpsc;
        use std::time::Duration;

        let obs = SimObservation::new();
        obs.replace_active_screen(Some("old".into()), false, || {});

        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (applying_tx, applying_rx) = mpsc::channel::<()>();
        let writer = {
            let obs = obs.clone();
            std::thread::spawn(move || {
                obs.replace_active_screen(Some("new".into()), false, || {
                    applying_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                });
            })
        };
        // The widget change is now in progress, holding the observation lock.
        applying_rx.recv().unwrap();

        let (read_tx, read_rx) = mpsc::channel::<Option<String>>();
        let reader = {
            let obs = obs.clone();
            std::thread::spawn(move || read_tx.send(obs.displayed_backup()).unwrap())
        };
        assert!(
            read_rx.recv_timeout(Duration::from_millis(200)).is_err(),
            "a reader passed through the replacement critical section"
        );

        release_tx.send(()).unwrap();
        let seen = read_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("reader completes once the replacement finishes");
        assert_eq!(
            seen.as_deref(),
            Some("new"),
            "a read ordered after the widget change sees the published value"
        );
        writer.join().unwrap();
        reader.join().unwrap();
    }

    #[test]
    fn outcomes_are_generation_keyed_and_accepted_is_final() {
        let obs = SimObservation::new();
        obs.replace_active_screen(None, true, || {});
        let gen1 = obs.entry_generation();
        obs.record_entry_outcome(EntryOutcome::Invalid);
        assert_eq!(obs.entry_outcome(gen1), Some(EntryOutcome::Invalid));
        // An on-screen edit can still fix it: Accepted supersedes Invalid…
        obs.record_entry_outcome(EntryOutcome::Accepted);
        assert_eq!(obs.entry_outcome(gen1), Some(EntryOutcome::Accepted));
        // …but nothing supersedes Accepted.
        obs.record_entry_outcome(EntryOutcome::Invalid);
        assert_eq!(obs.entry_outcome(gen1), Some(EntryOutcome::Accepted));

        // A new run gets a new generation; the old outcome isn't its.
        obs.replace_active_screen(None, true, || {});
        let gen2 = obs.entry_generation();
        assert_ne!(gen1, gen2);
        assert_eq!(obs.entry_outcome(gen2), None);
        // Clears drop screen state but keep recorded history.
        obs.clear();
        assert_eq!(obs.entry_outcome(gen1), Some(EntryOutcome::Accepted));
    }
}
