//! Mechanical paper-backup entry: types `#N WORD1 … WORD25` on the REAL
//! `EnterShareScreen` as touches — numeric keyboard for the share index,
//! BIP39-constrained alphabetic keyboard (clamped-endpoint scrolling for the
//! deep rows), word-selector tap to complete each word. Targets are parsed
//! LEXICALLY only: checksum validity is judged by the on-screen model after
//! the touches land, so a checksum-invalid word set is deliberately typeable
//! (that's how the invalid path gets exercised).
//!
//! Every key position comes from the widgets' own geometry contracts
//! (`letter_point` / `key_point` / `word_point`) — no layout math lives here.

use embedded_graphics::{draw_target::DrawTarget, geometry::Point, pixelcolor::Rgb565};
use frost_backup::{bip39_words, share_backup::ShareBackup, NUM_WORDS};
use frostsnap_widgets::backup::{
    AlphabeticKeyboard, EnterShareScreen, MainViewState, NumericKeyboard, ViewState, WordSelector,
};
use frostsnap_widgets::{DynWidget, Instant, SuperDrawTarget, Widget};

/// A lexically-valid entry target: digits for the share index, exactly
/// [`NUM_WORDS`] words that each exist on the BIP39 list (the keyboards cannot
/// type anything else). Deliberately NOT a [`ShareBackup`] — constructing one
/// would validate the checksum before any touch.
#[derive(Debug, Clone)]
pub struct BackupTarget {
    pub index: String,
    pub words: [&'static str; NUM_WORDS],
}

impl BackupTarget {
    /// Parse the canonical text form (`ShareBackup`'s `Display`):
    /// `#3 WORD1 … WORD25`, case-insensitive, any whitespace between words.
    pub fn parse(text: &str) -> Result<Self, TypistError> {
        let mut parts = text.split_whitespace();
        let index_part = parts.next().ok_or_else(|| parse_err("empty target"))?;
        let index = index_part
            .strip_prefix('#')
            .ok_or_else(|| parse_err("share index must start with '#'"))?;
        if index.is_empty() || !index.chars().all(|c| c.is_ascii_digit()) {
            return Err(parse_err(&format!(
                "share index must be digits, got \"#{index}\""
            )));
        }
        let mut words = [""; NUM_WORDS];
        for (i, slot) in words.iter_mut().enumerate() {
            let word = parts
                .next()
                .ok_or_else(|| parse_err(&format!("expected {NUM_WORDS} words, got {i}")))?;
            let upper = word.to_ascii_uppercase();
            let idx = bip39_words::BIP39_WORDS
                .binary_search(&upper.as_str())
                .map_err(|_| parse_err(&format!("\"{word}\" is not a BIP39 word")))?;
            *slot = bip39_words::BIP39_WORDS[idx];
        }
        if let Some(extra) = parts.next() {
            return Err(parse_err(&format!(
                "expected {NUM_WORDS} words, got more (\"{extra}\"…)"
            )));
        }
        Ok(Self {
            index: index.to_string(),
            words,
        })
    }
}

fn parse_err(msg: &str) -> TypistError {
    TypistError::Parse(msg.to_string())
}

#[derive(Debug)]
pub enum TypistError {
    Parse(String),
    /// The screen resolved the full word set to a checksum-invalid backup.
    InvalidChecksum,
    /// A tap stopped making progress (state named for diagnosis).
    Stuck(String),
    /// The screen's state disagrees with the target (desync or wrong screen).
    UnexpectedState(String),
}

impl core::fmt::Display for TypistError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            TypistError::Parse(m) => write!(f, "backup target parse error: {m}"),
            TypistError::InvalidChecksum => {
                write!(f, "entered words resolved to an invalid checksum")
            }
            TypistError::Stuck(m) => write!(f, "backup typing stuck: {m}"),
            TypistError::UnexpectedState(m) => write!(f, "unexpected entry state: {m}"),
        }
    }
}

impl std::error::Error for TypistError {}

/// Where the alphabetic keyboard must be scrolled for a letter's row to be
/// visible; clamped endpoints so the position is exact without tracking state.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ScrollAnchor {
    Top,
    Bottom,
}

/// One planned interaction, in SCREEN coordinates.
#[derive(Debug, Clone, PartialEq)]
pub struct EntryStep {
    /// Clamp-scroll the alphabetic keyboard first (letter taps only).
    pub scroll: Option<ScrollAnchor>,
    pub tap: Point,
    /// What this step MEANS ("letter 'Z'", "word \"ZOO\""), for the failure
    /// trail: an invalid checksum surfaces 24 rows after the divergent input,
    /// so the trail is the only record of what was actually aimed at.
    pub label: String,
}

/// Plain-data view of entry progress — everything the typist needs to decide
/// the next touch. Convertible from the widget's [`ViewState`] on the same
/// thread, and publishable across the device-thread boundary (no UI types).
#[derive(Debug, Clone, PartialEq)]
pub struct EntryView {
    pub row: usize,
    pub cursor: usize,
    pub mode: EntryMode,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EntryMode {
    Index { current: String },
    Word,
    Select { current: String },
    Done,
}

impl EntryView {
    pub fn from_view_state(vs: &ViewState) -> Self {
        let mode = match &vs.main_view {
            MainViewState::EnterShareIndex { current } => EntryMode::Index {
                current: current.clone(),
            },
            MainViewState::EnterWord { .. } => EntryMode::Word,
            MainViewState::WordSelect { current, .. } => EntryMode::Select {
                current: current.clone(),
            },
            MainViewState::AllWordsEntered { .. } => EntryMode::Done,
        };
        Self {
            row: vs.row,
            cursor: vs.cursor_pos,
            mode,
        }
    }
}

/// Decide the next touch from the screen's OWN view of its state. Pure: all
/// geometry comes from the widgets' contracts, all sequencing from the real
/// `BackupModel`'s reported progress (the selector's word list is
/// reconstructed with the same `words_with_prefix` the model itself uses).
pub fn next_step(
    view: &EntryView,
    target: &BackupTarget,
    keyboard_rect: embedded_graphics::primitives::Rectangle,
) -> Result<Option<EntryStep>, TypistError> {
    let origin = keyboard_rect.top_left;
    match &view.mode {
        EntryMode::Index { current } => {
            let mut numeric = NumericKeyboard::new();
            numeric.set_bottom_buttons_enabled(true);
            numeric.set_constraints(keyboard_rect.size);
            let key = if *current == target.index {
                '✓'
            } else if let Some(next) = target.index.strip_prefix(current.as_str()) {
                next.chars().next().expect("strip_prefix of shorter string")
            } else {
                return Err(TypistError::UnexpectedState(format!(
                    "share index shows \"{current}\", typing \"{}\"",
                    target.index
                )));
            };
            let p = numeric.key_point(key).ok_or_else(|| {
                TypistError::Stuck(format!("numeric keyboard has no '{key}' key"))
            })?;
            Ok(Some(EntryStep {
                scroll: None,
                tap: p + origin,
                label: format!("index key '{key}' (current \"{current}\")"),
            }))
        }
        EntryMode::Word => {
            let word = target_word(view.row, target)?;
            let typed = view.cursor;
            let letter = word.chars().nth(typed).ok_or_else(|| {
                TypistError::UnexpectedState(format!(
                    "word row {} already has {typed} chars but target \"{word}\" is done",
                    view.row
                ))
            })?;
            // Rows 0–3 (A–P) are reachable scrolled to the top; deeper rows
            // only at the bottom clamp.
            let letter_row = (letter as u32 - 'A' as u32) / 4;
            let (anchor, scroll) = if letter_row < 4 {
                (ScrollAnchor::Top, 0)
            } else {
                (
                    ScrollAnchor::Bottom,
                    AlphabeticKeyboard::content_height() as i32 - keyboard_rect.size.height as i32,
                )
            };
            let p = AlphabeticKeyboard::letter_point(letter, scroll)
                .ok_or_else(|| TypistError::Stuck(format!("no key for '{letter}'")))?;
            Ok(Some(EntryStep {
                scroll: Some(anchor),
                tap: p + origin,
                label: format!("letter '{letter}' of \"{word}\" ({anchor:?})"),
            }))
        }
        EntryMode::Select { current } => {
            let word = target_word(view.row, target)?;
            let possible_words = bip39_words::words_with_prefix(current);
            if !possible_words.contains(&word) {
                return Err(TypistError::UnexpectedState(format!(
                    "selector for \"{current}\" offers {possible_words:?}, target \"{word}\""
                )));
            }
            let mut selector = WordSelector::new(possible_words, current);
            selector.set_constraints(keyboard_rect.size);
            let p = selector
                .word_point(word)
                .ok_or_else(|| TypistError::Stuck(format!("no button for \"{word}\"")))?;
            Ok(Some(EntryStep {
                scroll: None,
                tap: p + origin,
                label: format!("word \"{word}\" from {possible_words:?} (current \"{current}\")"),
            }))
        }
        EntryMode::Done => Ok(None),
    }
}

fn target_word(row: usize, target: &BackupTarget) -> Result<&'static str, TypistError> {
    target
        .words
        .get(row.checked_sub(1).ok_or_else(|| {
            TypistError::UnexpectedState("entering a word while on the share-index row".into())
        })?)
        .copied()
        .ok_or_else(|| TypistError::UnexpectedState(format!("word row {row} out of range")))
}

/// Drive [`EnterShareScreen`] directly (host, same thread): the widget-level
/// harness behind the round-trip tests. The screen paces itself — taps are
/// ignored during fade-outs and the selector's appearance grace — so this
/// loop is closed on the screen's own state, retrying a bounded number of
/// times before declaring itself stuck.
pub fn type_into_screen<D: DrawTarget<Color = Rgb565>>(
    screen: &mut EnterShareScreen,
    target: &BackupTarget,
    display: &mut SuperDrawTarget<D, Rgb565>,
) -> Result<ShareBackup, TypistError> {
    // 25 ms per draw mirrors the device's display refresh cadence.
    const TICK_MS: u64 = 25;
    /// Draws to wait for one tap to visibly land (covers the ≤400 ms selector
    /// grace and the ~100 ms fade) before retrying it.
    const SETTLE_DRAWS: usize = 24;
    const ATTEMPTS: usize = 5;

    let mut now = 0u64;
    let mut draw = |screen: &mut EnterShareScreen, now: &mut u64| {
        *now += TICK_MS;
        let _ = screen.draw(display, Instant::from_millis(*now));
    };

    draw(screen, &mut now);
    // Generous overall budget: ~130 taps for a full backup, bounded per-tap.
    for _ in 0..NUM_WORDS * 64 {
        if screen.is_finished() {
            return screen
                .get_backup()
                .ok_or_else(|| TypistError::UnexpectedState("finished without a backup".into()));
        }
        if screen.is_invalid() {
            return Err(TypistError::InvalidChecksum);
        }
        // The view leads the widgets (deferred surface swap + tap fades);
        // acting unsettled can drop the drag on the outgoing surface and land
        // the tap on the incoming one at stale coordinates. Same gate as
        // `type_on_device`, driven here by our own draws.
        if !screen.is_settled() {
            draw(screen, &mut now);
            continue;
        }
        let view = EntryView::from_view_state(&screen.view_state());
        let Some(step) = next_step(&view, target, screen.keyboard_rect())? else {
            // AllWordsEntered: let the success delay (or invalid resolution) play out.
            draw(screen, &mut now);
            continue;
        };

        let before = view.clone();
        let mut landed = false;
        for _ in 0..ATTEMPTS {
            if let Some(anchor) = step.scroll {
                // Clamped-endpoint scroll: one oversized drag erases any
                // accumulated scroll state (same call shape touch_handler
                // uses for gesture-tagged drags).
                let (from, to) = match anchor {
                    ScrollAnchor::Top => (0u32, 1000u32),
                    ScrollAnchor::Bottom => (1000u32, 0u32),
                };
                screen.handle_vertical_drag(None, from, false);
                screen.handle_vertical_drag(Some(from), to, true);
                draw(screen, &mut now);
            }
            screen.handle_touch(step.tap, Instant::from_millis(now), false);
            draw(screen, &mut now);
            screen.handle_touch(step.tap, Instant::from_millis(now), true);
            for _ in 0..SETTLE_DRAWS {
                draw(screen, &mut now);
                if EntryView::from_view_state(&screen.view_state()) != before
                    || screen.is_finished()
                    || screen.is_invalid()
                {
                    landed = true;
                    break;
                }
            }
            if landed {
                break;
            }
        }
        if !landed {
            return Err(TypistError::Stuck(format!(
                "tap at {:?} (row {}, cursor {}) made no progress after {ATTEMPTS} attempts",
                step.tap, view.row, view.cursor
            )));
        }
    }
    Err(TypistError::Stuck(
        "typing budget exhausted before the screen finished".into(),
    ))
}

/// Drive a RUNNING device's entry screen through its touch queue, closed on
/// the [`EntryProgress`](crate::EntryProgress) its thread publishes — the
/// device-path twin of [`type_into_screen`]. Real wall-clock: taps and clamp
/// swipes go through the same `touch_handler` a finger does, and each key
/// waits until the published progress visibly advances before the next.
/// Returns once the screen reports finished (the success screen); the
/// device's own `EnteredShareBackup` protocol event follows from there.
pub fn type_on_device(
    input: &crate::DeviceInput,
    observation: &crate::SimObservation,
    target: &BackupTarget,
    timeout: std::time::Duration,
) -> Result<(), TypistError> {
    // The trail prints only on failure (cargo test surfaces captured output
    // for failing tests alone), because the symptom lands 24 rows after the
    // divergent input: an invalid checksum without the trail says nothing
    // about WHICH row went wrong or what was aimed at it.
    let mut trail: Vec<String> = Vec::new();
    let result = type_on_device_traced(input, observation, target, timeout, &mut trail);
    if let Err(e) = &result {
        eprintln!("typist steps before failure ({e}):");
        for line in &trail {
            eprintln!("  {line}");
        }
    }
    result
}

fn type_on_device_traced(
    input: &crate::DeviceInput,
    observation: &crate::SimObservation,
    target: &BackupTarget,
    timeout: std::time::Duration,
    trail: &mut Vec<String>,
) -> Result<(), TypistError> {
    use crate::observation::EntryOutcome;
    use std::time::{Duration, Instant as WallInstant};
    const POLL: Duration = Duration::from_millis(25);
    /// Per-tap settle budget: covers the ≤400 ms selector grace, fades, and
    /// the device thread's own poll cadence.
    const SETTLE: Duration = Duration::from_millis(1500);
    const ATTEMPTS: usize = 5;

    let deadline = WallInstant::now() + timeout;
    // Wait for the entry screen, and capture WHICH entry run we are typing
    // into: completion is judged ONLY by that generation's recorded outcome
    // (the device's own EnteredShareBackup event / invalid resolution) —
    // never by the screen going away, which is mere lifecycle (cancel, reset,
    // and power-off all clear the active screen without accepting anything).
    let generation = {
        let until = WallInstant::now() + SETTLE;
        loop {
            if let Some(p) = observation.entry_progress() {
                break p.generation;
            }
            if WallInstant::now() > until {
                return Err(TypistError::UnexpectedState(
                    "device is not on the backup entry screen".into(),
                ));
            }
            std::thread::sleep(POLL);
        }
    };
    let outcome = |generation: u64| -> Option<Result<(), TypistError>> {
        match observation.entry_outcome(generation)? {
            EntryOutcome::Accepted => Some(Ok(())),
            EntryOutcome::Invalid => Some(Err(TypistError::InvalidChecksum)),
        }
    };

    loop {
        if WallInstant::now() > deadline {
            return Err(TypistError::Stuck(format!(
                "timed out after {timeout:?}; progress: {:?}",
                observation.entry_progress()
            )));
        }
        if let Some(result) = outcome(generation) {
            return result;
        }
        let p = match observation.entry_progress() {
            Some(p) if p.generation == generation => p,
            Some(p) => {
                return Err(TypistError::UnexpectedState(format!(
                    "a different entry run (generation {} vs ours {generation}) took the screen",
                    p.generation
                )));
            }
            None => {
                // Screen gone with no outcome recorded for our run: give the
                // outcome a moment (it is written before the screen clears,
                // but our poll may interleave), then report the truth.
                let until = WallInstant::now() + SETTLE;
                loop {
                    if let Some(result) = outcome(generation) {
                        return result;
                    }
                    if WallInstant::now() > until {
                        return Err(TypistError::UnexpectedState(
                            "entry screen went away without an outcome (canceled or reset?)".into(),
                        ));
                    }
                    std::thread::sleep(POLL);
                }
            }
        };
        // The published view LEADS the widgets: the model updates at lift-up,
        // but the surface swap (word selector in/out) is deferred until the
        // tap fade finishes AND the device thread draws — on its own
        // schedule, which a loaded machine can stall arbitrarily. Acting on
        // an unsettled snapshot is the desync: the outgoing surface drops the
        // clamp swipe, the incoming one then takes the tap at stale
        // coordinates — a valid-but-wrong key the checksum only exposes 24
        // rows later. No typist-side sleep can cover a stalled device thread,
        // so every action gates on the widget-published settled signal.
        if !p.settled {
            std::thread::sleep(POLL);
            continue;
        }
        let Some(step) = next_step(&p.view, target, p.keyboard_rect)? else {
            // AllWordsEntered: the success delay (or invalid resolution) is playing out.
            std::thread::sleep(POLL);
            continue;
        };

        let before = p.view.clone();
        let mut landed = false;
        'attempts: for attempt in 0..ATTEMPTS {
            if attempt > 0 {
                // A retry races the previous tap still materialising — its
                // events undrained, or the surface mid-swap. Re-act only from
                // a settled snapshot that still matches the step's premise;
                // any other state (landed after all, lifecycle, or never
                // settling) goes back to the outer loop to classify.
                let until = WallInstant::now() + SETTLE;
                let premise_holds = loop {
                    match observation.entry_progress() {
                        Some(now)
                            if now.generation == generation
                                && !now.finished
                                && !now.invalid
                                && now.view == before =>
                        {
                            if now.settled {
                                break true;
                            }
                        }
                        _ => break false,
                    }
                    if WallInstant::now() > until {
                        break false;
                    }
                    std::thread::sleep(POLL);
                };
                if !premise_holds {
                    landed = true;
                    break 'attempts;
                }
            }
            if std::env::var_os("TYPIST_DEBUG").is_some() {
                eprintln!(
                    "attempt {attempt}: step {step:?} view {:?} progress {:?}",
                    before,
                    observation.entry_progress()
                );
            }
            if let Some(anchor) = step.scroll {
                // Clamped-endpoint scroll: a swipe taller than the whole
                // scroll range pins the keyboard to a known end.
                let (y1, y2) = match anchor {
                    ScrollAnchor::Top => (75, 265),
                    ScrollAnchor::Bottom => (265, 75),
                };
                input.swipe(120, y1, 120, y2, Duration::from_millis(80));
            }
            input.tap(step.tap.x, step.tap.y);
            let until = WallInstant::now() + SETTLE;
            while WallInstant::now() < until {
                std::thread::sleep(POLL);
                match observation.entry_progress() {
                    Some(now) if now.view != before || now.finished || now.invalid => {
                        landed = true;
                        break 'attempts;
                    }
                    Some(_) => {
                        // Unchanged screen — but the run may have resolved
                        // (outcome recording and progress sampling interleave).
                        if outcome(generation).is_some() {
                            landed = true;
                            break 'attempts;
                        }
                    }
                    // The entry screen left entirely — terminal lifecycle
                    // (accepted, canceled, reset). The outer loop classifies
                    // it from the recorded outcome; retrying taps into
                    // whatever screen is up now would be typing blind.
                    None => {
                        landed = true;
                        break 'attempts;
                    }
                }
            }
        }
        if !landed {
            return Err(TypistError::Stuck(format!(
                "tap at {:?} (row {}, cursor {}) made no progress after {ATTEMPTS} attempts",
                step.tap, before.row, before.cursor
            )));
        }
        trail.push(format!(
            "row {} cursor {}: {} @ ({},{})",
            before.row, before.cursor, step.label, step.tap.x, step.tap.y
        ));
    }
}

/// The "write it down" half of the paper cycle in ONE call: wait for the
/// device's display-backup screen, capture its full text (the privileged
/// pen-and-paper read), then drive the REAL paged display — page-advance
/// swipes and the final hold-to-confirm, all widget-owned geometry — until
/// the device's own `BackupRecorded` event is observed for THIS display run.
/// Holds on non-final pages are inert, so no page count is assumed. The
/// captured text feeds [`type_on_device`] for the entry half.
///
/// A bounded, generation-scoped state machine: every transition decision
/// reads ONE [`DisplaySnapshot`](crate::observation::DisplaySnapshot) —
/// this run's recorded outcome means success even after the screen has
/// cleared; the run still being the active display means keep driving;
/// anything else (screen gone, or another display run replacing this one
/// directly) is lifecycle, reported as [`TypistError::UnexpectedState`].
/// Exceeding `timeout` at any point is a [`TypistError::Stuck`].
pub fn record_on_device(
    input: &crate::DeviceInput,
    observation: &crate::SimObservation,
    timeout: std::time::Duration,
) -> Result<String, TypistError> {
    use std::time::{Duration, Instant as WallInstant};
    const POLL: Duration = Duration::from_millis(25);
    /// Between page swipes: lets the slide transition finish so the next
    /// swipe registers on the new page.
    const PAGE_SETTLE: Duration = Duration::from_millis(400);

    let deadline = WallInstant::now() + timeout;
    // The snapshot's displayed text pins its generation (both published in
    // one atomic replacement).
    let (text, generation) = loop {
        let s = observation.display_snapshot();
        if let Some(text) = s.displayed {
            break (text, s.generation);
        }
        if WallInstant::now() > deadline {
            return Err(TypistError::Stuck(
                "timed out waiting for the device to display a backup".into(),
            ));
        }
        std::thread::sleep(POLL);
    };

    loop {
        let s = observation.display_snapshot();
        if s.recorded == Some(generation) {
            // The device's own BackupRecorded fired for OUR run — success,
            // even if the screen has since been cleared.
            return Ok(text);
        }
        match &s.displayed {
            Some(_) if s.generation == generation => {} // still ours: keep driving
            _ => {
                // Gone, or another display run took the screen without an
                // intermediate None — lifecycle, never success.
                return Err(TypistError::UnexpectedState(format!(
                    "display run {generation} ended without the device confirming \
                     (canceled, reset, powered off, or replaced by run {})",
                    s.generation
                )));
            }
        }
        if WallInstant::now() > deadline {
            return Err(TypistError::Stuck(format!(
                "display never confirmed within {timeout:?}"
            )));
        }
        input.backup_display_next();
        std::thread::sleep(PAGE_SETTLE);
        input.backup_display_confirm();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use embedded_graphics::geometry::Size;
    use frost_backup::bip39_words::{words_with_prefix, ValidLetters};
    use frostsnap_core::schnorr_fun::fun::Scalar;
    use frostsnap_widgets::vec_framebuffer::VecFramebuffer;
    use frostsnap_widgets::{palette::PALETTE, Key};
    use rand_chacha::ChaCha20Rng;
    use rand_core::SeedableRng;

    const SCREEN: Size = Size::new(240, 280);
    /// The keyboard area `EnterShareScreen` gives its keyboards on a 240×280
    /// screen (below the 60 px input preview).
    const KEYBOARD: Size = Size::new(240, 220);

    fn display() -> SuperDrawTarget<VecFramebuffer<Rgb565>, Rgb565> {
        SuperDrawTarget::new(
            VecFramebuffer::new(SCREEN.width as usize, SCREEN.height as usize),
            PALETTE.background,
        )
    }

    // Each geometry contract is pinned to its widget's REAL hit-testing: a
    // press at the claimed point must yield the claimed key.

    #[test]
    fn alphabetic_letter_points_hit_their_keys() {
        for idx in 0..26u8 {
            let letter = (b'A' + idx) as char;
            let mut kb = AlphabeticKeyboard::new();
            kb.set_valid_keys(ValidLetters::all_valid());
            kb.set_constraints(KEYBOARD);
            let deep = (idx as u32 / 4) >= 4;
            let scroll = if deep {
                // Clamped-endpoint drag: oversized delta pins scroll to max.
                kb.handle_vertical_drag(None, 1000, false);
                kb.handle_vertical_drag(Some(1000), 0, true);
                AlphabeticKeyboard::content_height() as i32 - KEYBOARD.height as i32
            } else {
                0
            };
            let p = AlphabeticKeyboard::letter_point(letter, scroll).unwrap();
            let touch = kb.handle_touch(p, Instant::from_millis(0), false);
            assert_eq!(
                touch.map(|t| t.key),
                Some(Key::Keyboard(letter)),
                "letter {letter} at {p:?} (scroll {scroll})"
            );
        }
    }

    #[test]
    fn numeric_key_points_hit_their_keys() {
        let mut kb = NumericKeyboard::new();
        kb.set_bottom_buttons_enabled(true);
        kb.set_constraints(KEYBOARD);
        for key in "0123456789✓".chars() {
            let p = kb.key_point(key).unwrap();
            let touch = kb.handle_touch(p, Instant::from_millis(0), false);
            assert_eq!(
                touch.map(|t| t.key),
                Some(Key::Keyboard(key)),
                "key {key} at {p:?}"
            );
        }
    }

    #[test]
    fn word_selector_points_hit_their_buttons() {
        let words = words_with_prefix("CAB");
        assert!((1..=8).contains(&words.len()), "prefix fits the selector");
        let mut selector = WordSelector::new(words, "CAB");
        selector.set_constraints(KEYBOARD);
        // The public handle_touch is gated on having drawn + a grace period.
        let mut d = display();
        let _ = selector.draw(&mut d, Instant::from_millis(0));
        for &word in words {
            let p = selector.word_point(word).unwrap();
            let touch = selector.handle_touch(p, Instant::from_millis(1000), false);
            assert_eq!(
                touch.map(|t| t.key),
                Some(Key::WordSelector(word)),
                "word {word} at {p:?}"
            );
        }
    }

    // The recorder's generation-scoped state machine, driven against a
    // synthetically published observation (the crate's own publish side); the
    // e2e covers the real-display happy path. One snapshot per transition:
    // outcome beats lifecycle, and only THIS run's outcome counts.
    #[test]
    fn recorder_success_survives_the_screen_clearing() {
        use crate::{DeviceInput, SimObservation, TouchQueue};
        use std::time::Duration;
        let obs = SimObservation::new();
        obs.replace_active_screen(Some("#1 PAPER A".into()), false, || {});
        let recorder = {
            let obs = obs.clone();
            std::thread::spawn(move || {
                record_on_device(
                    &DeviceInput::new(TouchQueue::new()),
                    &obs,
                    Duration::from_secs(30),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(300));
        // The device accepts, then the loop tears the screen down — the
        // recorded outcome must still win over the disappearance.
        obs.record_display_confirmed();
        obs.clear();
        assert_eq!(recorder.join().unwrap().unwrap(), "#1 PAPER A");
    }

    #[test]
    fn recorder_clear_without_outcome_is_not_success() {
        use crate::{DeviceInput, SimObservation, TouchQueue};
        use std::time::Duration;
        let obs = SimObservation::new();
        obs.replace_active_screen(Some("#1 PAPER B".into()), false, || {});
        let recorder = {
            let obs = obs.clone();
            std::thread::spawn(move || {
                record_on_device(
                    &DeviceInput::new(TouchQueue::new()),
                    &obs,
                    Duration::from_secs(30),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(300));
        obs.clear(); // cancel / reset / power-off
        match recorder.join().unwrap() {
            Err(TypistError::UnexpectedState(_)) => {}
            other => panic!("clear without outcome must error, got {other:?}"),
        }
    }

    #[test]
    fn recorder_direct_replacement_by_another_run_is_not_success() {
        use crate::{DeviceInput, SimObservation, TouchQueue};
        use std::time::Duration;
        let obs = SimObservation::new();
        obs.replace_active_screen(Some("#1 PAPER C".into()), false, || {});
        let recorder = {
            let obs = obs.clone();
            std::thread::spawn(move || {
                record_on_device(
                    &DeviceInput::new(TouchQueue::new()),
                    &obs,
                    Duration::from_secs(30),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(300));
        // Another display run takes the screen with no None in between.
        obs.replace_active_screen(Some("#2 PAPER D".into()), false, || {});
        match recorder.join().unwrap() {
            Err(TypistError::UnexpectedState(_)) => {}
            other => panic!("direct replacement must error, got {other:?}"),
        }
    }

    #[test]
    fn recorder_stale_outcome_cannot_satisfy_a_newer_run() {
        use crate::{DeviceInput, SimObservation, TouchQueue};
        use std::time::Duration;
        let obs = SimObservation::new();
        // Run N records an outcome…
        obs.replace_active_screen(Some("#1 PAPER E".into()), false, || {});
        obs.record_display_confirmed();
        // …then run N+1 takes the screen; the recorder captures N+1.
        obs.replace_active_screen(Some("#2 PAPER F".into()), false, || {});
        let recorder = {
            let obs = obs.clone();
            std::thread::spawn(move || {
                record_on_device(
                    &DeviceInput::new(TouchQueue::new()),
                    &obs,
                    Duration::from_secs(30),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(300));
        obs.clear();
        match recorder.join().unwrap() {
            Err(TypistError::UnexpectedState(_)) => {}
            other => panic!("run N's outcome must not satisfy run N+1, got {other:?}"),
        }
    }

    #[test]
    fn recorder_bounds_its_initial_wait() {
        use crate::{DeviceInput, SimObservation, TouchQueue};
        use std::time::Duration;
        match record_on_device(
            &DeviceInput::new(TouchQueue::new()),
            &SimObservation::new(),
            Duration::from_millis(200),
        ) {
            Err(TypistError::Stuck(_)) => {}
            other => panic!("no display must time out, got {other:?}"),
        }
    }

    // The display-driving geometry contracts, pinned to the real widgets: the
    // probed confirm point really confirms (press + hold-time of draws), and
    // the exported swipe really advances a page.
    #[test]
    fn backup_display_geometry_contracts_hold() {
        use frostsnap_widgets::backup::BackupDisplay;

        let mut d = display();
        let mut bd = BackupDisplay::new([0u16; 25], 1);
        bd.set_constraints(SCREEN);
        let _ = bd.draw(&mut d, Instant::from_millis(0));

        assert_eq!(bd.current_page(), 0);
        let (from, to) = BackupDisplay::page_advance_swipe(SCREEN);
        // The same chained drag shape touch_handler produces for a SlideUp.
        bd.handle_vertical_drag(None, from.y as u32, false);
        bd.handle_vertical_drag(Some(from.y as u32), to.y as u32, true);
        let _ = bd.draw(&mut d, Instant::from_millis(25));
        assert_eq!(bd.current_page(), 1, "exported swipe advances a page");

        let p = BackupDisplay::confirm_point(SCREEN).expect("confirm point");
        // Drive a fresh display to the LAST page and confirm at the probed
        // point: press, then draws spanning the hold time.
        let mut bd = BackupDisplay::new([0u16; 25], 1);
        bd.set_constraints(SCREEN);
        let mut now = 0u64;
        let _ = bd.draw(&mut d, Instant::from_millis(now));
        for _ in 0..16 {
            bd.handle_vertical_drag(None, from.y as u32, false);
            bd.handle_vertical_drag(Some(from.y as u32), to.y as u32, true);
            // Let the slide transition finish so the next swipe registers.
            for _ in 0..30 {
                now += 25;
                let _ = bd.draw(&mut d, Instant::from_millis(now));
            }
        }
        bd.handle_touch(p, Instant::from_millis(now), false);
        for _ in 0..200 {
            now += 25;
            let _ = bd.draw(&mut d, Instant::from_millis(now));
            if bd.is_confirmed() {
                break;
            }
        }
        assert!(
            bd.is_confirmed(),
            "holding at the probed confirm point confirms the display"
        );
    }

    #[test]
    fn parse_rejects_malformed_targets() {
        let ok = "#3 ".to_string() + &["ABANDON"; 25].join(" ");
        assert!(BackupTarget::parse(&ok).is_ok());
        for bad in [
            "".to_string(),
            "3 ".to_string() + &["ABANDON"; 25].join(" "), // no '#'
            "#x ".to_string() + &["ABANDON"; 25].join(" "), // non-digit index
            "#3 ".to_string() + &["ABANDON"; 24].join(" "), // too few
            "#3 ".to_string() + &["ABANDON"; 26].join(" "), // too many
            "#3 ".to_string() + &["NOTAWORD"; 25].join(" "), // not BIP39
        ] {
            assert!(
                matches!(BackupTarget::parse(&bad), Err(TypistError::Parse(_))),
                "should reject {bad:?}"
            );
        }
    }

    // Types a full backup like `type_into_screen`, except every word-selector
    // tap fires at exactly `select_offset_ms` after the selector's first draw
    // — the knob the wall-clock device path turns implicitly with scheduling.
    // Swallowed taps (grace) retry later like the real typist; what this
    // hunts is a tap that REGISTERS during the appearance window but selects
    // the wrong word, which nothing detects until the checksum 24 rows on.
    fn type_with_selector_offset(
        screen: &mut EnterShareScreen,
        target: &BackupTarget,
        d: &mut SuperDrawTarget<VecFramebuffer<Rgb565>, Rgb565>,
        select_offset_ms: u64,
    ) -> Result<ShareBackup, TypistError> {
        const TICK_MS: u64 = 25;
        let mut now = 0u64;
        let mut draw = |screen: &mut EnterShareScreen, now: &mut u64| {
            *now += TICK_MS;
            let _ = screen.draw(d, Instant::from_millis(*now));
        };

        draw(screen, &mut now);
        let mut selector_shown_at: Option<u64> = None;
        for _ in 0..NUM_WORDS * 64 {
            if screen.is_finished() {
                return screen.get_backup().ok_or_else(|| {
                    TypistError::UnexpectedState("finished without a backup".into())
                });
            }
            if screen.is_invalid() {
                return Err(TypistError::InvalidChecksum);
            }
            if !screen.is_settled() {
                draw(screen, &mut now);
                continue;
            }
            let view = EntryView::from_view_state(&screen.view_state());
            let Some(step) = next_step(&view, target, screen.keyboard_rect())? else {
                draw(screen, &mut now);
                continue;
            };
            if matches!(view.mode, EntryMode::Select { .. }) {
                // The settle draw that swapped the selector in is when its
                // grace clock started; pace the tap to the swept offset.
                let shown = *selector_shown_at.get_or_insert(now);
                while now < shown + select_offset_ms {
                    draw(screen, &mut now);
                }
            } else {
                selector_shown_at = None;
            }
            let before = view.clone();
            if let Some(anchor) = step.scroll {
                let (from, to) = match anchor {
                    ScrollAnchor::Top => (0u32, 1000u32),
                    ScrollAnchor::Bottom => (1000u32, 0u32),
                };
                screen.handle_vertical_drag(None, from, false);
                screen.handle_vertical_drag(Some(from), to, true);
                draw(screen, &mut now);
            }
            screen.handle_touch(step.tap, Instant::from_millis(now), false);
            screen.handle_touch(step.tap, Instant::from_millis(now), true);
            for _ in 0..24 {
                draw(screen, &mut now);
                if EntryView::from_view_state(&screen.view_state()) != before
                    || screen.is_finished()
                    || screen.is_invalid()
                {
                    break;
                }
            }
        }
        Err(TypistError::Stuck(
            "typing budget exhausted before the screen finished".into(),
        ))
    }

    // Sweep selector-tap timing across the appearance grace and fade-in
    // boundary. A tap during the window may be SWALLOWED (the retry types it
    // later — fine); it must never register a DIFFERENT word. The device-path
    // CI failure resolves 25 valid words to an invalid checksum, which only a
    // silently-wrong selector pick can produce; this pins the boundary that
    // wall-clock scheduling sweeps implicitly.
    #[test]
    fn selector_taps_across_the_grace_boundary_never_pick_the_wrong_word() {
        let mut rng = ChaCha20Rng::seed_from_u64(99);
        let secret = Scalar::random(&mut rng);
        let (shares, _key) =
            ShareBackup::generate_shares(secret, 2, 3, frost_backup::FINGERPRINT, &mut rng);
        let share = &shares[0];
        let target = BackupTarget::parse(&share.to_string()).unwrap();
        for offset_ms in (0..=600).step_by(25) {
            let mut screen = EnterShareScreen::new();
            screen.set_constraints(SCREEN);
            match type_with_selector_offset(&mut screen, &target, &mut display(), offset_ms) {
                Ok(typed) => assert_eq!(
                    &typed, share,
                    "selector taps at +{offset_ms}ms typed a DIFFERENT backup"
                ),
                Err(e) => panic!("typing with selector taps at +{offset_ms}ms failed: {e}"),
            }
        }
    }

    // The full mechanical round trip against the REAL screen: valid backups
    // in, the same ShareBackup out of the screen's own model.
    #[test]
    fn types_generated_backups_round_trip() {
        let mut rng = ChaCha20Rng::seed_from_u64(7);
        let secret = Scalar::random(&mut rng);
        let (shares, _key) =
            ShareBackup::generate_shares(secret, 2, 3, frost_backup::FINGERPRINT, &mut rng);
        for share in &shares {
            let target = BackupTarget::parse(&share.to_string()).unwrap();
            let mut screen = EnterShareScreen::new();
            screen.set_constraints(SCREEN);
            let typed = type_into_screen(&mut screen, &target, &mut display())
                .unwrap_or_else(|e| panic!("typing {share} failed: {e}"));
            assert_eq!(&typed, share, "typed backup must round-trip");
        }
    }

    /// Drive `screen` to row 2's empty word: share index "1" confirmed, then
    /// row 1 completed as CABIN through its real word selector. Returns the
    /// wall of simulated time reached.
    fn screen_at_second_word(
        screen: &mut EnterShareScreen,
        d: &mut SuperDrawTarget<VecFramebuffer<Rgb565>, Rgb565>,
    ) -> u64 {
        let mut now = 0u64;
        let origin = screen.keyboard_rect().top_left;
        let mut settle = |screen: &mut EnterShareScreen, now: &mut u64| {
            for _ in 0..200 {
                if screen.is_settled() {
                    return;
                }
                *now += 25;
                let _ = screen.draw(d, Instant::from_millis(*now));
            }
            panic!("screen never settled");
        };
        let press = |screen: &mut EnterShareScreen, now: u64, p: Point| {
            screen.handle_touch(p, Instant::from_millis(now), false);
            screen.handle_touch(p, Instant::from_millis(now), true);
        };

        let mut numeric = NumericKeyboard::new();
        numeric.set_bottom_buttons_enabled(true);
        numeric.set_constraints(KEYBOARD);
        for key in ['1', '✓'] {
            settle(screen, &mut now);
            press(screen, now, numeric.key_point(key).unwrap() + origin);
        }
        for letter in ['C', 'A', 'B'] {
            settle(screen, &mut now);
            press(
                screen,
                now,
                AlphabeticKeyboard::letter_point(letter, 0).unwrap() + origin,
            );
        }
        settle(screen, &mut now);
        // The selector ignores touches for an appearance grace; play it out.
        for _ in 0..48 {
            now += 25;
            let _ = screen.draw(d, Instant::from_millis(now));
        }
        let words = words_with_prefix("CAB");
        let mut selector = WordSelector::new(words, "CAB");
        selector.set_constraints(KEYBOARD);
        press(screen, now, selector.word_point("CABIN").unwrap() + origin);
        assert_eq!(
            EntryView::from_view_state(&screen.view_state()),
            EntryView {
                row: 2,
                cursor: 0,
                mode: EntryMode::Word
            },
            "CABIN selection must advance the model to row 2"
        );
        now
    }

    // The race the settled gate exists for, deterministically: a word-tap
    // registers (model → row 2) but the surface swap is DEFERRED, so the
    // screen is unsettled; a clamp drag issued in that window is dropped by
    // the outgoing selector, and the follow-up tap — aimed at 'Z' on a
    // bottom-pinned keyboard — lands on the top-pinned one instead, typing a
    // VALID but WRONG letter. Gated on is_settled, the same sequence types
    // 'Z'. ('Z' discriminates: it resolves to a ≤8-word selector, any
    // mis-landed letter to a >8-word keyboard row.)
    #[test]
    fn unsettled_drag_drops_and_mistaps_where_settled_lands() {
        let bottom = AlphabeticKeyboard::content_height() as i32 - KEYBOARD.height as i32;

        for gate_on_settled in [false, true] {
            let mut d = display();
            let mut screen = EnterShareScreen::new();
            screen.set_constraints(SCREEN);
            let mut now = screen_at_second_word(&mut screen, &mut d);
            let origin = screen.keyboard_rect().top_left;

            assert!(
                !screen.is_settled(),
                "the registered word-tap must leave the surface swap pending"
            );
            if gate_on_settled {
                for _ in 0..200 {
                    if screen.is_settled() {
                        break;
                    }
                    now += 25;
                    let _ = screen.draw(&mut d, Instant::from_millis(now));
                }
                assert!(screen.is_settled(), "screen must settle under draws");
            }
            screen.handle_vertical_drag(None, 1000, false);
            screen.handle_vertical_drag(Some(1000), 0, true);
            // The deferred swap applies here — after the drag either reached
            // the keyboard (settled leg) or died on the selector (unsettled).
            for _ in 0..200 {
                if screen.is_settled() {
                    break;
                }
                now += 25;
                let _ = screen.draw(&mut d, Instant::from_millis(now));
            }
            let z = AlphabeticKeyboard::letter_point('Z', bottom).unwrap() + origin;
            screen.handle_touch(z, Instant::from_millis(now), false);
            screen.handle_touch(z, Instant::from_millis(now), true);

            let view = EntryView::from_view_state(&screen.view_state());
            if gate_on_settled {
                assert_eq!(
                    view,
                    EntryView {
                        row: 2,
                        cursor: 1,
                        mode: EntryMode::Select {
                            current: "Z".into()
                        }
                    },
                    "gated: the drag scrolls and the tap hits 'Z'"
                );
            } else {
                assert_eq!(
                    (view.row, view.cursor, view.mode),
                    (2, 1, EntryMode::Word),
                    "ungated: the dropped drag makes the tap register a valid-but-WRONG letter"
                );
            }
        }
    }

    /// Spawn a device on its own thread, complete the handshake (coordinator-
    /// side naming shortcut), tell it to enter a physical backup over the
    /// wire, and wait until the entry screen is observably up.
    fn spawned_device_in_entry(
        device_seed: u64,
        rng: &mut ChaCha20Rng,
    ) -> (
        crate::SpawnedDevice,
        frostsnap_coordinator::UsbSerialManager,
    ) {
        use crate::{SimFirmware, VirtualDevice, VirtualSerial};
        use frostsnap_comms::{CoordinatorSendBody, CoordinatorSendMessage};
        use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
        use frostsnap_core::message::{CoordinatorRestoration, CoordinatorToDeviceMessage};
        use frostsnap_core::EnterPhysicalId;
        use std::time::{Duration, Instant as WallInstant};

        let spawned =
            VirtualDevice::spawn(device_seed, SimFirmware::PLACEHOLDER_DIGEST, |_, _, _| {});
        let mut manager = UsbSerialManager::new(Box::new(VirtualSerial::single(
            "sim-0",
            spawned.host.clone().unwrap(),
        )));

        let deadline = WallInstant::now() + Duration::from_secs(30);
        let mut registered = false;
        while WallInstant::now() < deadline && !registered {
            for change in manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        manager.accept_device_name(id, "Sim".to_string())
                    }
                    DeviceChange::Registered { .. } => registered = true,
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(registered, "device should register");

        manager.usb_sender().send(CoordinatorSendMessage::to(
            spawned.device_id,
            CoordinatorSendBody::Core(CoordinatorToDeviceMessage::Restoration(
                CoordinatorRestoration::EnterPhysicalBackup {
                    enter_physical_id: EnterPhysicalId::new(rng),
                },
            )),
        ));
        let deadline = WallInstant::now() + Duration::from_secs(30);
        while spawned.observation.entry_progress().is_none() {
            assert!(
                WallInstant::now() < deadline,
                "entry screen never became observable"
            );
            manager.poll_ports();
            std::thread::sleep(Duration::from_millis(5));
        }
        (spawned, manager)
    }

    // The whole device path: a RUNNING device (own thread) is told to enter a
    // backup over the real protocol, the typist types it through the touch
    // queue closed on the published observation, and the device reports the
    // entered share's image back over the wire — proving touches, threading,
    // observation, and protocol agree on the exact share.
    #[test]
    fn types_a_backup_on_a_running_device_through_the_protocol() {
        use crate::DeviceInput;
        use frostsnap_coordinator::{AppMessageBody, DeviceChange};
        use frostsnap_core::message::{DeviceRestoration, DeviceToCoordinatorMessage};
        use std::time::{Duration, Instant as WallInstant};

        let mut rng = ChaCha20Rng::seed_from_u64(42);
        let secret = Scalar::random(&mut rng);
        let (shares, _key) =
            ShareBackup::generate_shares(secret, 2, 3, frost_backup::FINGERPRINT, &mut rng);
        let share = &shares[0];
        let target = BackupTarget::parse(&share.to_string()).unwrap();

        let (spawned, mut manager) = spawned_device_in_entry(21, &mut rng);
        let input = DeviceInput::new(spawned.touch.clone());
        type_on_device(
            &input,
            &spawned.observation,
            &target,
            Duration::from_secs(240),
        )
        .unwrap_or_else(|e| {
            if let Some(dir) = std::env::var_os("TYPIST_DEBUG") {
                let path = std::path::Path::new(&dir).join("typist_stuck.png");
                let _ = spawned.framebuffer.save_png(&path);
                eprintln!("saved stuck screen to {}", path.display());
            }
            panic!("typing on the device failed: {e}")
        });

        // The device reports the ENTERED share's image over the wire.
        let deadline = WallInstant::now() + Duration::from_secs(30);
        let mut entered_image = None;
        while WallInstant::now() < deadline && entered_image.is_none() {
            for change in manager.poll_ports() {
                if let DeviceChange::AppMessage(msg) = change {
                    if let AppMessageBody::Core(body) = msg.body {
                        if let DeviceToCoordinatorMessage::Restoration(
                            DeviceRestoration::PhysicalEntered(entered),
                        ) = *body
                        {
                            entered_image = Some(entered.share_image);
                        }
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            entered_image,
            Some(share.share_image()),
            "the typed backup must arrive as the exact entered share"
        );
    }

    // Losing the entry screen is NOT acceptance: a coordinator Cancel that
    // lands after the last word (during the success delay, before the device
    // emits EnteredShareBackup) clears the screen — the typist must report
    // that as an error, never as success.
    #[test]
    fn cancel_after_last_word_cannot_masquerade_as_success() {
        use crate::DeviceInput;
        use frostsnap_comms::{CoordinatorSendBody, CoordinatorSendMessage};
        use std::time::{Duration, Instant as WallInstant};

        let mut rng = ChaCha20Rng::seed_from_u64(43);
        let secret = Scalar::random(&mut rng);
        let (shares, _key) =
            ShareBackup::generate_shares(secret, 2, 3, frost_backup::FINGERPRINT, &mut rng);
        let target = BackupTarget::parse(&shares[0].to_string()).unwrap();

        let (spawned, mut manager) = spawned_device_in_entry(22, &mut rng);
        let sender = manager.usb_sender();
        let observation = spawned.observation.clone();
        let device_id = spawned.device_id;

        // Watcher: pump the wire; the instant every row is entered (the 1 s
        // success delay is running, the acceptance event has NOT fired yet),
        // cancel the device.
        let watcher = std::thread::spawn(move || -> bool {
            let deadline = WallInstant::now() + Duration::from_secs(180);
            let mut canceled_at = None;
            while WallInstant::now() < deadline {
                manager.poll_ports();
                if canceled_at.is_none()
                    && observation
                        .entry_progress()
                        .is_some_and(|p| p.view.mode == EntryMode::Done)
                {
                    sender.send(CoordinatorSendMessage::to(
                        device_id,
                        CoordinatorSendBody::Cancel,
                    ));
                    canceled_at = Some(WallInstant::now());
                }
                // Keep pumping so the Cancel actually flushes to the device.
                if canceled_at.is_some_and(|at| at.elapsed() > Duration::from_secs(2)) {
                    break;
                }
                std::thread::sleep(Duration::from_millis(2));
            }
            canceled_at.is_some()
        });

        let result = type_on_device(
            &DeviceInput::new(spawned.touch.clone()),
            &spawned.observation,
            &target,
            Duration::from_secs(240),
        );
        assert!(watcher.join().unwrap(), "the watcher must have canceled");
        match result {
            Err(TypistError::UnexpectedState(_)) => {}
            other => panic!("cancel after Done must not read as success, got {other:?}"),
        }
    }

    // Lexically-valid but checksum-invalid words must be fully typeable (the
    // screen judges validity, not the parser) — and this set deliberately
    // exercises the deep keyboard rows (Q with its auto-U, U–Z letters) and a
    // multi-digit share index.
    #[test]
    fn checksum_invalid_words_type_through_and_resolve_invalid() {
        let mut words = vec!["QUALITY", "ZEBRA", "YOUTH", "WOLF", "VIVID", "UNIFORM"];
        words.extend(["ABANDON"; 19]);
        let text = format!("#12 {}", words.join(" "));
        let target = BackupTarget::parse(&text).unwrap();
        let mut screen = EnterShareScreen::new();
        screen.set_constraints(SCREEN);
        match type_into_screen(&mut screen, &target, &mut display()) {
            Err(TypistError::InvalidChecksum) => {}
            other => panic!("expected InvalidChecksum, got {other:?}"),
        }
    }
}
