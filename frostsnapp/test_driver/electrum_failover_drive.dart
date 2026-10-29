import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// The connection failures we have actually shipped, driven against two real servers.
//
// Every case asserts the app's OWN view (`electrumStatus`), or a door's `accepted` count, rather
// than a consequence: "the balance eventually appeared" passes just as well when no failover
// happened, and a live connection count cannot tell a kept connection from a remade one.
//
// Run: `./fsim test electrum_failover`.

/// Fund a whole 1 BTC so the asserted amount is unmistakable.
const int _fundSats = 100000000;

/// The wallet's first receive address, derived OUTSIDE the app from its exported descriptor, so
/// funding it cannot inherit an app-side derivation bug. Avoids driving the Receive sheet, which
/// this test has no reason to exercise.
Future<String> _receiveAddress(AppSession h, SimFaucet faucet) async {
  final descriptor = await h.walletDescriptor();
  final receive = descriptor.replaceAll('<0;1>', '0').split('#').first;
  final info = await faucet.rpc('getdescriptorinfo', [receive]);
  final canonical = (info as Map)['descriptor'] as String;
  final addrs = await faucet.rpc('deriveaddresses', [
    canonical,
    [0, 0],
  ]);
  return (addrs as List).first as String;
}

/// Progress marker. This scenario drives nine distinct connection states, several of which wait
/// on backoffs, so a timeout that cannot say WHICH one was running is nearly useless.
void _step(String what) {
  stdout.writeln('ELECTRUM_FAILOVER_STEP: $what');
}

Future<int> _accepted(SimFaucet faucet, String id) async {
  final servers = await faucet.electrumServers();
  return servers.firstWhere((s) => s['id'] == id)['accepted'] as int;
}

Future<void> main() async {
  await Scenario.run('electrum_failover', withRegtest: true, (s) async {
    final faucet = await s.faucet();

    // The primary is down BEFORE the app exists. `runScenario` provisions the app before handing
    // the body its session, which is already too late to test what happens at startup — hence
    // `Scenario.run` and ordering the setup by hand.
    await faucet.electrumSetMode('a', 'down');
    final h = await s.provisionInstance(0, totalInstances: 1, deviceCount: 1);
    await h.createWallet(name: 'SimFailover');

    _step('1 startup failover to the backup');
    // ---- 1. musdom's bug: a broken primary must not stop the failover completing ----
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: true),
      describe: 'connected to the backup while the primary is down',
    );
    // And the connection is a working one, not just a socket: a receive syncs over it.
    final address = await _receiveAddress(h, faucet);
    await faucet.fund(address, _fundSats);
    await h.waitFor(RegExp('Receiving'), timeout: const Duration(seconds: 90));
    await h.waitFor(
      RegExp(r'1\.00 000 000'),
      timeout: const Duration(seconds: 20),
    );

    _step('3 primary returns, stay on backup');
    // ---- 3. The primary comes back. We STAY on the backup ----
    // Pinning what we actually do, not what one might assume: nothing restores a preference for
    // the primary, so the app keeps the working connection it has. A future change to that
    // should be deliberate, and should have to edit this.
    await faucet.electrumSetMode('a', 'tcp');
    final acceptedByPrimary = await _accepted(faucet, 'a');
    await Future<void>.delayed(const Duration(seconds: 6));
    final still = await h.electrumStatus();
    if (!still.connectedTo(backup: true)) {
      throw StateError('expected to stay on the backup, got $still');
    }
    if (await _accepted(faucet, 'a') != acceptedByPrimary) {
      throw StateError(
        'the app connected to the primary just because it came back — '
        'if that is now intended, this case is what changes',
      );
    }

    _step('move to the primary');
    // ---- Get onto the PRIMARY, which is where the next two cases have to start ----
    // Disabling the backup is the only thing that makes the app leave a working connection; it
    // then stays on the primary when the backup is re-enabled (that is case 6's subject).
    await h.setElectrumEnabled('primary_only');
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: false),
      describe: 'moved to the primary when the backup was disabled',
    );
    await h.setElectrumEnabled('all');
    await Future<void>.delayed(const Duration(seconds: 2));

    _step('6 slot-toggle isolation');
    // ---- 6. The #508 regression: touching the OTHER slot must not disturb this connection ----
    // Only unit coverage of `reconnect_needed` existed for this. `accepted` makes it exact: a
    // teardown-and-reconnect shows up as a new connection to the primary, where sampling the
    // status for a momentary Disconnected is a race the test loses.
    // Settle on a connection first, so `before` is not read mid-reconnect.
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: false),
      describe: 'settled on the primary before toggling',
    );
    final beforeToggle = await _accepted(faucet, 'a');
    // Toggled REPEATEDLY, and each half waited out rather than slept through. Correct code
    // reconnects zero times no matter how often the other slot is toggled, so repetition costs
    // a correct run nothing; a broken one has to keep its reconnect outside every one of these
    // windows to escape. A single 3s sleep did not: the same mutation was caught here once and
    // slipped past to be caught by a later case the next time.
    for (var i = 0; i < 3; i++) {
      await h.setElectrumEnabled('primary_only');
      await h.waitForElectrum(
        (st) => st.connectedTo(backup: false),
        describe: 'still on the primary with the backup disabled (round $i)',
      );
      await h.setElectrumEnabled('all');
      await h.waitForElectrum(
        (st) => st.connectedTo(backup: false),
        describe: 'still on the primary with the backup re-enabled (round $i)',
      );
      if (await _accepted(faucet, 'a') != beforeToggle) {
        throw StateError(
          'toggling the backup slot reconnected the primary (round $i) — a live '
          'connection was torn down for a change that did not affect it',
        );
      }
    }

    _step('2 rotate away from a dead session');
    // ---- 2. adam's bug: a session that dies after the probe must rotate AWAY ----
    // The direction matters, and getting it backwards makes the test worthless. We are on the
    // PRIMARY, and the primary is the server `try_connect` tries FIRST by default — so a client
    // that simply retried would land right back on it and never notice. Only rotating away
    // produces the backup. (Asserting the mirror image — on the backup, expect the primary —
    // passes with or without the rotation, which is exactly what a mutation showed.)
    final beforeRotate = await _accepted(faucet, 'b');
    await faucet.electrumDropConnections('a');
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: true),
      describe: 'rotated to the backup after the primary session died',
      timeout: const Duration(seconds: 60),
    );
    if (await _accepted(faucet, 'b') <= beforeRotate) {
      throw StateError(
        'the app reports the backup without having connected to it',
      );
    }

    _step('4 hanging server');
    // ---- 4. A server that accepts and never speaks ----
    // Distinct from `down`: the app spends its connect timeout before giving up, so this is the
    // case where a failover has to survive a SLOW failure rather than a fast one.
    //
    // We are on the backup, so it is the BACKUP's session that has to die: rotating away from it
    // is what sends the app to the hanging primary. Killing the primary's session instead touches
    // nothing the app is using, and the assertion below would pass without an attempt on `a`.
    await faucet.electrumSetMode('a', 'hang');
    final hangKnocks = await _accepted(faucet, 'a');
    final beforeHang = await _accepted(faucet, 'b');
    if (await faucet.electrumDropConnections('b') == 0) {
      throw StateError('expected a live backup session to kill');
    }
    // Waited for BEFORE the status: the status still reads "on the backup" until the app notices
    // its session died, so checking it first can pass before anything has happened.
    final knockDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (await _accepted(faucet, 'a') <= hangKnocks) {
      if (DateTime.now().isAfter(knockDeadline)) {
        throw StateError(
          'the app never tried the hanging primary, so the slow failure went untested',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: true),
      describe: 'failed over past a hanging primary',
      timeout: const Duration(seconds: 60),
    );
    if (await _accepted(faucet, 'b') <= beforeHang) {
      throw StateError(
        'the app reports the backup without having reconnected to it',
      );
    }

    _step('5 both down, still retrying');
    // ---- 5. Both gone: settle on disconnected, keep retrying, raise NO Flutter error ----
    await faucet.electrumSetMode('a', 'down');
    await faucet.electrumSetMode('b', 'down');
    await faucet.electrumDropConnections('b');
    await h.waitForElectrum(
      (st) => st.state == 'disconnected',
      describe: 'disconnected with both servers down',
      timeout: const Duration(seconds: 60),
    );
    // Still TRYING, not parked: the retry loop keeps knocking on both doors.
    final knocksA = await _accepted(faucet, 'a');
    final knocksB = await _accepted(faucet, 'b');
    await Future<void>.delayed(const Duration(seconds: 8));
    if (await _accepted(faucet, 'a') <= knocksA &&
        await _accepted(faucet, 'b') <= knocksB) {
      throw StateError(
        'the app stopped retrying while both servers were down — it would never '
        'notice either coming back',
      );
    }

    _step('7 usable with no chain');
    // ---- 7. Spending with nowhere to broadcast must not take the app down ----
    // No assertion about which error the user sees; the point is that a wallet with no chain
    // connection stays usable and raises nothing hidden. Any Flutter error here fails the
    // scenario through the harness's own checking, which is what makes this worth driving.
    await h.tap(RegExp('Receive'));
    await h.waitFor('Later');
    await h.tap('Later');
    await h.waitFor(RegExp('Share Address'));
    await h.dismissSheetOrDialog();

    _step('recovery');
    // ---- Recovery: one door back is enough ----
    await faucet.electrumSetMode('a', 'tcp');
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: false),
      describe: 'reconnected once the primary came back',
      timeout: const Duration(seconds: 60),
    );

    await faucet.close();
    stdout.writeln(
      'ELECTRUM_FAILOVER_DRIVE_OK: startup failover, session-death rotation, '
      'slot-toggle isolation, hang, both-down retry, recovery',
    );
  });
}
