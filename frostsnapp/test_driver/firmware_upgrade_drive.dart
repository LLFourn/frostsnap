import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// The firmware-upgrade UX end-to-end: an EXISTING device's firmware is
// invalidated (setFirmwareDigest — the digest is a settable property whose
// value the next announce reports), a replug makes the coordinator see the
// unrecognized digest, the app offers the upgrade, the user consents in the
// app AND on the device (the real hold-to-confirm prompt), the real image
// bytes stream through the real chunk-ready flow control — THROUGH the
// up-to-date head device, which acks passively and forwards — the device
// reboots, re-announces the new digest, and the app's upgrade affordance
// clears. Two interruption cases run FIRST: an abort at the consent stage
// (the protocol's own cancellation), and a mid-byte-stream failure (the head
// is pulled, killing the coordinator's open port). After each, the
// reconnected device still announces the OLD digest — the affordance returns
// — and the final retry completes.
//
// Fidelity note (per the fsim-firmware-upgrade plan): the device-side storage
// is faked — bytes are drained and discarded, the digest is trusted — so this
// covers the protocol and the UX, never the flash path.
//
// Run: `./fsim test firmware_upgrade [--android]`.

Future<void> main() async {
  await SimHarness.runScenario('firmware_upgrade', (h) async {
    // Device 1 is up-to-date and connected from launch; the second device joins
    // at the chain tail, so the transfer must pass through device 1's passive
    // forward path. It joins FACTORY-FRESH — the staleness is applied to the
    // existing, recognized device below, which is the case the setter exists
    // for (a device with an identity, not a specially-spawned stale one).
    final stale = await h.addDevice();
    stdout.writeln('device to invalidate: $stale');

    // The upgrade affordance lives on the Connected Devices tab — behind the
    // navigation drawer on compact (emulator) layouts, a visible rail on wide.
    if (!await h.exists(RegExp('Connected Devices'))) {
      await h.tap('Open navigation menu');
      await h.waitFor(RegExp('Connected Devices'));
    }
    await h.tap(RegExp('Connected Devices'));
    if (await h.exists(RegExp('Upgrade 1 device'))) {
      throw StateError('a factory-fresh device must not be offered an upgrade');
    }

    // Invalidate WHILE CONNECTED — the digest takes effect at the next
    // announce, so nothing changes until the replug re-handshakes...
    await h.device(stale).setFirmwareDigest('42' * 32);
    if (await h.exists(RegExp('Upgrade 1 device'))) {
      throw StateError('the set digest must not surface before an announce');
    }
    // ...and the replug makes the coordinator re-read it: the affordance
    // appears for a device that kept its identity.
    await h.disconnect(stale);
    await h.connect(stale);
    await h.waitFor(RegExp('Upgrade 1 device'));

    // Dismiss a result alert ('Done' on success, 'OK' on abort) tolerantly:
    // the fullscreen dialog's teardown can race the alert away between any
    // check and the tap, so a vanished dialog counts as dismissed.
    Future<void> dismissResultDialog(RegExp title) async {
      try {
        if (await h.exists('Done')) {
          await h.tap('Done');
        } else if (await h.exists('OK')) {
          await h.tap('OK');
        }
      } on StateError {
        // already gone
      }
      await h.waitForAbsent(title);
    }

    // Start the upgrade dialog and give consent on the stale device's real
    // hold-to-confirm prompt (the up-to-date device acks passively on its
    // own). The transfer starts DURING the hold that registers the consent,
    // so the transfer stage is checked right after each hold — waiting for
    // consent-then-Upgrading as two steps would race the paced transfer.
    Future<void> startAndConsent() async {
      await h.tapUntil(RegExp('Upgrade 1 device'), RegExp('Confirm on device'));
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        await h
            .device(stale)
            .holdConfirm(120, 215, const Duration(milliseconds: 3200));
        if (await h.exists(RegExp('Upgrading'))) return;
        if (!await h.exists(RegExp('Confirm on device'))) {
          throw StateError(
            'the ack stage ended without an observable transfer stage',
          );
        }
      }
      throw StateError('the device consent never registered');
    }

    // INTERRUPTION 1, at the consent stage: unplug the stale device while
    // the app waits for its on-device confirm. The upgrade protocol's
    // disconnect handling aborts deterministically; the reconnected device
    // still announces the OLD digest, so the affordance returns.
    await h.tapUntil(RegExp('Upgrade 1 device'), RegExp('Confirm on device'));
    await h.disconnect(stale);
    await h.waitFor(
      RegExp('Upgrade Aborted'),
      timeout: const Duration(seconds: 60),
    );
    await dismissResultDialog(RegExp('Upgrade Aborted'));
    // connect() gates on coordinator recognition of the resulting chain, so
    // past this point the rebooted device's announce has been processed.
    await h.connect(stale);
    await h.waitFor(RegExp('Upgrade 1 device'));
    stdout.writeln('consent-stage abort: old digest survived');

    // INTERRUPTION 2, mid byte-stream: with the transfer visibly running,
    // pull the HEAD — the whole chain loses power and the coordinator's open
    // port DIES (its I/O errors, as a real unplug kills the fd). That error
    // is the raw transfer loop's only exit: it holds no poll loop, so a
    // silently dead line would wedge it forever. Both devices lose power
    // mid-stream; on reconnection they announce their pre-upgrade digests, so
    // the affordance returns. (Pulling the TAIL mid-stream is the one
    // interruption not covered: the head's passive pump would wait forever on
    // a downstream chunk-ready signal, exactly as real hardware does over its
    // device-to-device UART links.)
    await startAndConsent();
    await h.disconnect(1);
    await h.waitFor(
      RegExp('Upgrade Failed'),
      timeout: const Duration(seconds: 60),
    );
    await dismissResultDialog(RegExp('Upgrade Failed'));
    await h.connect(1);
    await h.connect(stale);
    await h.waitFor(RegExp('Upgrade 1 device'));
    stdout.writeln(
      'mid-transfer port death: failed cleanly, old digest survived',
    );

    // The RETRY runs to completion: progress, success dialog, and after the
    // device reboots and is recognized again, the affordance is gone while
    // the Connected Devices surface is live.
    await startAndConsent();
    // The DEVICE's own screen must be animating through the transfer — the
    // real download-progress widget advances per sector. Two mid-transfer
    // samples of the live screen must differ (a frozen device screen was a
    // real regression: rendering happened but frames stopped flowing).
    final shots = await Directory.systemTemp.createTemp('fw-progress');
    try {
      final a = '${shots.path}/a.png';
      final b = '${shots.path}/b.png';
      await h.device(stale).screen(a);
      await Future<void>.delayed(const Duration(seconds: 1));
      await h.device(stale).screen(b);
      final bytesA = await File(a).readAsBytes();
      final bytesB = await File(b).readAsBytes();
      final identical =
          bytesA.length == bytesB.length &&
          List.generate(
            bytesA.length,
            (i) => bytesA[i] == bytesB[i],
          ).every((same) => same);
      if (identical) {
        throw StateError('the device screen must animate during the transfer');
      }
    } finally {
      await shots.delete(recursive: true);
    }
    await h.waitFor(
      RegExp('Upgrade Successful'),
      timeout: const Duration(seconds: 120),
    );
    await dismissResultDialog(RegExp('Upgrade Successful'));
    await h.connect(stale);
    await h.waitFor(RegExp('Connected Devices'));
    if (await h.exists(RegExp('Upgrade 1 device'))) {
      throw StateError(
        'the upgraded device must not be offered another upgrade',
      );
    }

    stdout.writeln(
      'FIRMWARE_UPGRADE_OK: consent abort and mid-transfer port death both '
      'kept the old digest; the retry upgraded, rebooted, and re-announced '
      'up-to-date',
    );
  }, deviceCount: 1);
}
