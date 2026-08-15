import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// Runtime device lifecycle end-to-end: a session may start with ZERO devices and build
// its fleet at runtime; removal tombstones a device's number forever; and the two
// writers — the harness (app channel) and the TRAY (the in-app panel a human drives) —
// stay convergent on one numbering throughout, because they share one allocator (the
// pool). Numbers are asserted relative to what addDevice returns, never hardcoded:
// on android the APK launches with one baked-in device that converging to
// `deviceCount: 0` removes, so the first runtime number differs by lane.
//
// Run: `./fsim test device_lifecycle [--android]`.

Future<void> main() async {
  await SimHarness.runScenario('device_lifecycle', (h) async {
    // The empty-fleet session: no devices until the test says so.
    final atLaunch = await h.deviceNumbers();
    if (atLaunch.isNotEmpty) {
      throw StateError('deviceCount: 0 must launch empty, got $atLaunch');
    }

    // Harness-side add.
    final first = await h.addDevice();
    // Tray-side add: the same allocator, driven through the panel a human uses.
    // (Docked and visible on wide surfaces; behind the edge handle on narrow.)
    if (!await h.exists('Add device')) {
      await h.tap('Open simulator');
      await h.waitFor('Add device');
    }
    await h.tap('Add device');
    late int second;
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final numbers = await h.deviceNumbers();
      if (numbers.length == 2) {
        second = numbers.firstWhere((n) => n != first);
        break;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError('the tray add never landed (fleet: $numbers)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (second <= first) {
      throw StateError(
        'numbers must be allocated monotonically (got $second after $first)',
      );
    }
    // The tray lists both (its device cards are labeled by number; the card's
    // semantics merge the number with its neighbours, so match by pattern).
    await h.waitFor(RegExp('Device $first\\b'));
    await h.waitFor(RegExp('Device $second\\b'));

    // Remove the FIRST device (it is connected — removal disconnects it first).
    await h.removeDevice(first);
    final afterRemove = await h.deviceNumbers();
    if (afterRemove.length != 1 || afterRemove.single != second) {
      throw StateError(
        'the survivor must keep its number: expected [$second], got $afterRemove',
      );
    }
    // The tray converges on the removal.
    await h.waitForAbsent(RegExp('Device $first\\b'));

    // The tombstone: the freed number is never reused, and operating on it errors.
    final third = await h.addDevice();
    if (third == first || third <= second) {
      throw StateError(
        'a removed number must never be reused (got $third after removing $first)',
      );
    }
    var removedErr = '';
    try {
      await h.removeDevice(first);
    } catch (e) {
      removedErr = '$e';
    }
    if (!removedErr.contains('removed')) {
      throw StateError(
        're-removing device $first should name the tombstone, got: $removedErr',
      );
    }
    var driveErr = '';
    try {
      await h.device(first).deviceId();
    } catch (e) {
      driveErr = '$e';
    }
    if (!driveErr.contains('no device $first')) {
      throw StateError(
        'driving removed device $first should error clearly, got: $driveErr',
      );
    }
    // The FRB surface names the tombstone for every mutator, not just lookups:
    // re-cabling THROUGH the removed number and toggling its connection both
    // error rather than succeed or panic.
    var chainErr = '';
    try {
      await h.setChain([first, second]);
    } catch (e) {
      chainErr = '$e';
    }
    if (!chainErr.contains('removed')) {
      throw StateError(
        'setChain through removed device $first should error, got: $chainErr',
      );
    }
    // The driver surface filters removed devices at lookup ('no device N');
    // the FRB layer beneath says 'removed' (pinned at the Rust level). Either
    // is the planned clear error — never success.
    var connectErr = '';
    try {
      await h.connect(first);
    } catch (e) {
      connectErr = '$e';
    }
    if (!connectErr.contains('removed') &&
        !connectErr.contains('no device $first')) {
      throw StateError(
        'connecting removed device $first should error, got: $connectErr',
      );
    }

    // TRAY-side removal — the other writer of the same pool. The remove control
    // lives on disconnected cards, so unplug the second device first, then drive
    // the tray's own button and assert the pool converged.
    await h.disconnect(second);
    if (!await h.exists('Add device')) {
      await h.tap('Open simulator');
      await h.waitFor('Add device');
    }
    await h.tapTooltip('Remove device $second');
    final trayDeadline = DateTime.now().add(const Duration(seconds: 15));
    while ((await h.deviceNumbers()).contains(second)) {
      if (!DateTime.now().isBefore(trayDeadline)) {
        throw StateError('the tray remove never landed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final afterTrayRemove = await h.deviceNumbers();
    if (afterTrayRemove.length != 1 || afterTrayRemove.single != third) {
      throw StateError(
        'tray removal must converge the pool: expected [$third], '
        'got $afterTrayRemove',
      );
    }

    // SNAPSHOT / RESTORE: the durable half of a device travels through the
    // harness as opaque bytes. Saving a CONNECTED device's state errors (unplug
    // it, then pocket it); a saved state whose identity is still live is rejected
    // (one device per identity); after removal, restore yields a FRESH number
    // carrying the SAME device identity — the physical device back from the
    // drawer.
    var snapErr = '';
    try {
      await h.saveDeviceState(third);
    } catch (e) {
      snapErr = '$e';
    }
    if (!snapErr.contains('unplug')) {
      throw StateError(
        'saving connected device $third should error, got: $snapErr',
      );
    }
    await h.disconnect(third);
    final idBefore = await h.device(third).deviceId();
    final snap = await h.saveDeviceState(third);
    var dupErr = '';
    try {
      await h.addDeviceFromSavedState(snap);
    } catch (e) {
      dupErr = '$e';
    }
    if (!dupErr.contains('already')) {
      throw StateError(
        'restoring a still-live identity should error, got: $dupErr',
      );
    }
    await h.removeDevice(third);
    final restored = await h.addDeviceFromSavedState(snap);
    if (restored <= third) {
      throw StateError(
        'restore must get a fresh number (got $restored after $third)',
      );
    }
    if (await h.device(restored).deviceId() != idBefore) {
      throw StateError('the restored device must keep its identity');
    }
    final finalFleet = await h.deviceNumbers();
    if (finalFleet.length != 1 || finalFleet.single != restored) {
      throw StateError('expected only [$restored], got $finalFleet');
    }

    // The stale-FRB-handle contract: a handle cached BEFORE removal must error
    // clearly on every stateful method afterwards — never succeed, never panic.
    final probe = await h.staleDeviceHandleProbe(restored);
    for (final line in probe.split('\n')) {
      if (line.contains('NO ERROR') || !line.contains('removed')) {
        throw StateError('stale-handle probe violated the contract: $line');
      }
    }

    stdout.writeln(
      'DEVICE_LIFECYCLE_OK: empty launch, tray+harness share one allocator '
      '($first, $second, $third), save/restore keeps identity '
      '($restored), tombstones hold on every surface incl cached handles',
    );
  }, deviceCount: 0);
}
