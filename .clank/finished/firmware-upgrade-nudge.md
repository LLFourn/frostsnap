# firmware-upgrade-nudge

Offer a firmware upgrade before starting a device workflow, at the sites that currently don't
mention firmware at all.

## Goal

One function, called at the top of an action, before anything is sent to the device:

```dart
/// Offers a firmware upgrade for whichever of [devices] is connected and eligible.
/// Returns false if the caller should abandon the action without starting it.
Future<bool> maybeNudgeFirmwareUpgrade(BuildContext context, Iterable<DeviceId> devices);
```

- Nothing connected needs an upgrade, or the user already skipped it this session → returns `true`
  immediately, no UI, behaviour unchanged.
- Otherwise an ordinary dialog offering **Upgrade** or **Skip**.
  - **Skip** → record it and return `true`; the action proceeds on the current firmware.
  - **Upgrade** → run the existing upgrade flow, wait for the device to come back, return `true`.
  - Device gone for good / user backed out → return `false`.

Reuse `DeviceActionUpgradeController.run(context)` for the upgrade itself so the acks and progress
UI are identical to the device-list "Upgrade N devices" button. Note it upgrades every connected
eligible device, not only the ones passed in — same as that button, and fine.

## Why it goes before the send, not inside the dialog

The obvious placement — have `FullscreenActionDialogController` show the nudge when it notices an
upgradeable device — does not work. Constructing the controller only *schedules* a route for the
next frame; the call site sends the protocol on the very next line:

```dart
controller = FullscreenActionDialogController(...);        // device_action_backup_check.dart:46
...
final checkStream = coord.tellDeviceToCheckBackup(...);    // :70 — device lights up right here
```

`tell_device_to_check_backup` calls `start_protocol` synchronously (`coordinator.rs:1099`), so the
device is already displaying a prompt before any dialog paints. Nudging at paint time would mean
cancelling a workflow the device has already reacted to, which is confusing to look at. Aborting and
resuming later was considered and rejected for the same reason — nothing is permanently lost by a
cancel, but the device UI flickering through a request it then abandons is worse than not asking.

Gating before the send also means the nudge and the action dialog can never be on screen together:
the action dialog's route isn't pushed until the gate resolves. That is why this needs no
coordination mechanism between dialogs.

**`FullscreenActionDialogController` is not modified by this plan.**

## Scope

**In** — the six action sites that currently offer no firmware path at all:

| Site | Where the line goes |
|---|---|
| check backup | `device_action_backup_check.dart` `show()`, above the controller |
| display backup | `device_action_backup.dart` `show()`, above the controller |
| erase device | `device.dart` `showEraseDialog()`, after the signing-session precondition |
| erase all devices | `settings.dart` `_showEraseAllDialog()`, after the empty-list check |
| verify address | `wallet_receive.dart`, the `focus` setter's verify branch |
| signing | `wallet_tx_details.dart` `initState` — **`SigningMode.start` only** |

Signing excludes the restore path: that session is already live, so there is nothing to gate and
rebooting a device under it would be worse than stale firmware.

**Out — do not touch, do not duplicate:**

- **Keygen** already gates on `devicesNeedUpgrade` (`wallet_create.dart:312`) with its own upgrade
  buttons. Leave it alone.
- **Restoration** already gates via `FirmwareUpgradeView` (`recovery_flow.dart:441`). Leave it alone.
- The device-list **"Upgrade N devices"** button stays and must keep working.
- `device.dart:122` / `device_list.dart:51` are display-only eligibility banners, not gates. Leave them.
- `recovery_flow.dart:305` starts its protocol inside `build()`. Real bug, **LLFourn is handling it
  separately** — out of scope here, do not fix it in this branch.

## Dismissal state

Per-device, in memory, session-scoped. Not persisted; restarting the app nudges again. Per-device
rather than global because the prompt names the device you are about to act on.

## The one detail to get right

Return only once the device is actually back in the device list. `tell_device_to_check_backup`
raises `"device not connected"` if it fires into the window while the device is still rebooting, so
returning as soon as the upgrade reports success is not enough.

## Deferred, deliberately

A helper that wraps "maybe upgrade, then run the fullscreen action dialog" in one call would be
nicer than a line at each site. **LLFourn's call: wire the six sites by hand first and see what
shape falls out.** Do not invent the abstraction up front.

## Testing

`fsim` cannot drive this, so there is nothing honest to automate — **no new tests**, and no mocked
device-stack tests. LLFourn tests it manually.

`flutter analyze` and `just dart-format-check-app` must be clean, and the existing suite must still
pass.

## Acceptance

1. Starting one of the six actions with an upgradeable device connected offers the upgrade first,
   and nothing has been sent to the device at that point.
2. Skip proceeds with the action on current firmware; that device is not nudged again this session;
   restarting the app nudges again.
3. Upgrade runs the existing flow, and the action starts afterwards against the reconnected device.
4. No upgrade available, or already skipped → no dialog and no behaviour change.
5. Keygen, restoration and the device-list button behave exactly as before.

## House rules

- **No WHAT comments.** Comment the WHY when it isn't obvious — a rationale, constraint or hazard.
  Delete any comment the code below it already says. Applies to code from subagents too.
- Match the surrounding style and comment density.
- Keep it small. If this starts growing a coordination mechanism, stop and say so.
