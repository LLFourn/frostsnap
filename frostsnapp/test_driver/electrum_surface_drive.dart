import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// The electrum control surface, exercised once end to end: the harness's view of the two front
// doors, and the app's view of what it is connected to. Behaviour under failure is
// `electrum_failover_drive`; this proves the plumbing carries — a control verb that never runs
// from a test is a verb that is broken the day someone needs it.
//
// Run: `./fsim test electrum_surface`.

Future<void> main() async {
  await SimHarness.runScenario('electrum_surface', withRegtest: true, (
    h,
  ) async {
    final faucet = await h.faucet();

    // Two doors, both plaintext, on different HOSTS — the property TOFU rests on, since the
    // trust store is keyed by host alone.
    final servers = await faucet.electrumServers();
    if (servers.length != 2) {
      throw StateError('expected two front doors, got $servers');
    }
    final (a, b) = (servers[0], servers[1]);
    if (a['id'] != 'a' || b['id'] != 'b') {
      throw StateError('doors should be a then b, got $servers');
    }
    for (final door in servers) {
      if (door['mode'] != 'tcp') {
        throw StateError('door ${door['id']} should come up plaintext: $door');
      }
      if (door['fingerprint'] != null) {
        throw StateError('a plaintext door presents no certificate: $door');
      }
    }
    if (!(a['url'] as String).contains('127.0.0.1') ||
        !(b['url'] as String).contains('localhost')) {
      throw StateError('the doors must differ in host: $servers');
    }

    // The app is pointed at both, and connects to the primary. A wallet is what starts the
    // chain client at all — connections are lazy, so there is nothing to observe before one
    // exists.
    await h.createWallet(name: 'SimElectrum');
    final connected = await h.waitForElectrum(
      (s) => s.connectedTo(backup: false),
      describe: 'connected to the primary',
    );
    if (connected.primaryUrl != a['url'] || connected.backupUrl != b['url']) {
      throw StateError(
        'the app should be pointed at both doors, got $connected',
      );
    }

    // A connected app holds a live session on the door it is using, and none on the other.
    final live = await faucet.electrumServers();
    if ((live[0]['connections'] as int) < 1) {
      throw StateError('the primary should have a live session: ${live[0]}');
    }

    // Dropping it is a session failure, not a configuration change: the door stays open.
    final dropped = await faucet.electrumDropConnections('a');
    if (dropped < 1) {
      throw StateError('expected to drop the live session, dropped $dropped');
    }

    // The modes round-trip, and a mode change never moves the endpoint — the app has these
    // urls persisted, so a door that came back on another port would be a different server.
    final tls = await faucet.electrumSetMode('a', 'tls', identity: 'a1');
    if (!tls.startsWith('ssl://')) {
      throw StateError('tls should change the scheme, got $tls');
    }
    final serving = (await faucet.electrumServers()).first;
    if (serving['identity'] != 'a1' ||
        (serving['fingerprint'] as String).length != 64) {
      throw StateError('a tls door reports its certificate: $serving');
    }
    for (final mode in ['down', 'hang', 'tcp']) {
      final url = await faucet.electrumSetMode('a', mode);
      final port = Uri.parse(url).port;
      if (port != Uri.parse(a['url'] as String).port) {
        throw StateError('mode $mode moved the door: $url');
      }
    }

    // The app's own settings are drivable without touching the settings UI, and the app acts on
    // them: disabling everything must put it back to idle rather than leaving a stale Connected.
    await h.setElectrumEnabled('none');
    await h.waitForElectrum(
      (s) => s.state == 'idle',
      describe: 'idle after disabling every server',
    );
    // Swapped, not re-set to the same values: a setter that did nothing would be invisible if
    // the test wrote back what was already there.
    await h.setElectrumServers(
      primary: b['url'] as String,
      backup: a['url'] as String,
    );
    await h.setElectrumEnabled('all');
    final swapped = await h.waitForElectrum(
      (s) => s.isConnected,
      describe: 'connected again after re-enabling',
    );
    if (swapped.primaryUrl != b['url'] || swapped.backupUrl != a['url']) {
      throw StateError('the slots should have swapped, got $swapped');
    }

    await assertStatusReadsAreNonDestructive(h, faucet);

    await faucet.close();
  });
}

/// Reading status must not cost the app its own status updates.
///
/// `subscribeChainStatus` installs a SINGLE-owner sink in the coordinator (`StatusTracker` holds
/// one `Box<dyn Sink>`, and `set_sink` replaces it). A harness read that subscribed on its own
/// would displace the UI's subscription and then cancel, leaving the coordinator emitting into a
/// dead sink — the app would render a frozen status for the rest of the run, and every later
/// failover test would be asserting against a lie.
///
/// So this asserts through the UI's own rendering: the chain-status icon's tooltip is
/// `"<state>: <url>"`, fed by the subscription the app made at startup.
Future<void> assertStatusReadsAreNonDestructive(
  AppSession h,
  SimFaucet faucet,
) async {
  Future<String> rendered() async {
    final tips = await h.semantics().tooltips();
    final status = tips.where((t) => t.contains(': tcp://')).toList();
    if (status.length != 1) {
      throw StateError('expected exactly one chain-status tooltip, got $tips');
    }
    return status.single;
  }

  Future<String> waitForRendered(
    bool Function(String) predicate,
    String describe,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    var last = '';
    while (DateTime.now().isBefore(deadline)) {
      last = await rendered();
      if (predicate(last)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('the UI never rendered $describe (last: "$last")');
  }

  await waitForRendered((t) => t.startsWith('Connected:'), 'a connection');

  // Each read is a chance to steal the sink.
  for (var i = 0; i < 5; i++) {
    await h.electrumStatus();
  }

  // Now change the world. The app's own subscriber must still hear about it.
  await faucet.electrumSetMode('a', 'down');
  await faucet.electrumSetMode('b', 'down');
  await faucet.electrumDropConnections('a');
  await waitForRendered(
    (t) => !t.startsWith('Connected:'),
    'the disconnection that followed a harness read',
  );

  await faucet.electrumSetMode('a', 'tcp');
  await faucet.electrumSetMode('b', 'tcp');
  await waitForRendered(
    (t) => t.startsWith('Connected:'),
    'the reconnection that followed a harness read',
  );
}
