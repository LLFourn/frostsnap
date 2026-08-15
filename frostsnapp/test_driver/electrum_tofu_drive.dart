import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// Trust-on-first-use, driven through the real Edit Server dialog against servers presenting
// certificates the harness mints: first use, rotation, expiry, a forgery signed by a trusted
// leaf, and a case-folded host.
//
// The trust store is keyed by HOST alone, which fixes where each case can run. Door `a` is
// `127.0.0.1` and ends up trusting `a1`; any other certificate there is a CHANGE, so the cases
// that need a host with nothing stored (expiry, forgery) run on door `b` (`localhost`), and they
// reject rather than trust so `b` stays untrusted until case 5 deliberately trusts it.
//
// Run: `./fsim test electrum_tofu`.

final _caseFolded = ExpectedFailure(
  'a case-folded host reuses its trust entry instead of re-prompting',
  fixedBy: 'PR #584 (TOFU host normalisation)',
);

const _trust = 'Trust Certificate';
final _changed = RegExp(r'certificate for this server has changed');

void _step(String what) {
  stdout.writeln('ELECTRUM_TOFU_STEP: $what');
}

/// What the dialog settled on after Connect & Save. Waited for as a set, because which one
/// appears IS the result under test — waiting for the expected one would report the others as a
/// timeout rather than as what happened.
enum _Outcome { saved, prompt, failed }

Future<_Outcome> _outcome(AppSession h) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    if (await h.exists(_trust)) return _Outcome.prompt;
    if (await h.exists('Server saved')) return _Outcome.saved;
    if (await h.exists('Connection failed')) return _Outcome.failed;
  }
  throw StateError('Connect & Save settled on nothing within 30s');
}

/// `AB:CD:…` split over lines, as the dialog renders it, back to the bare hex the door reports.
String _hex(String rendered) =>
    rendered.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();

Future<String> _fingerprint(SimFaucet faucet, String id) async {
  final servers = await faucet.electrumServers();
  return servers.firstWhere((s) => s['id'] == id)['fingerprint'] as String;
}

/// The Settings destination, not the Settings page's own title: its label carries the tab index.
final _settingsTab = RegExp(r'^Settings\n');

Future<void> _openElectrumSettings(AppSession h) async {
  if (!await h.exists(_settingsTab)) {
    await h.tap('Open navigation menu');
  }
  await h.tap(_settingsTab);
  await h.tap(RegExp('^Electrum server'));
}

/// A server tile by the url it holds. Every network has a "Primary Server" row, and the sim tray
/// shows the same url, so neither the title nor the url alone picks out the regtest slot.
RegExp _serverTile(String url) =>
    RegExp('^(Primary|Backup) Server\n${RegExp.escape(url)}\$');

/// Open the regtest slot currently holding [currentUrl], type [url] and submit.
Future<_Outcome> _connectAndSave(
  AppSession h, {
  required String currentUrl,
  required String url,
}) async {
  await h.scrollIntoView(_serverTile(currentUrl));
  await h.tap(_serverTile(currentUrl));
  await h.waitFor('Server URL');
  await h.enterText('Server URL', url);
  await h.tap('Connect & Save');
  return _outcome(h);
}

void _expect(_Outcome got, _Outcome want, String why) {
  if (got != want) throw StateError('$why: expected $want, got $got');
}

Future<void> main() async {
  await SimHarness.runScenario('electrum_tofu', withRegtest: true, expectedToFail: _caseFolded, (
    h,
  ) async {
    final faucet = await h.faucet();
    // A wallet is what starts the chain client; without one nothing connects and the regtest
    // card has no status to show.
    await h.createWallet(name: 'SimTofu');
    final initial = await h.waitForElectrum(
      (st) => st.connectedTo(backup: false),
      describe: 'connected to the plaintext primary',
    );

    await _openElectrumSettings(h);
    if (!await h.exists(_serverTile(initial.primaryUrl))) {
      // Test networks are hidden outside developer mode.
      await h.tapTooltip('Back');
      await h.tap('Developer mode');
      await h.tap(RegExp('^Electrum server'));
      await h.waitFor(_serverTile(initial.primaryUrl));
    }

    _step('1 first use');
    // ---- 1. First use: the prompt carries the cert the door is actually presenting ----
    final aUrl = await faucet.electrumSetMode('a', 'tls', identity: 'a1');
    final a1 = await _fingerprint(faucet, 'a');
    _expect(
      await _connectAndSave(h, currentUrl: initial.primaryUrl, url: aUrl),
      _Outcome.prompt,
      'a first-seen self-signed server must prompt',
    );
    if (await h.exists(_changed)) {
      throw StateError('a first use was presented as a changed certificate');
    }
    final shown = _hex(await h.getSelectableTextByKey('tofu-fingerprint'));
    if (shown != a1) {
      throw StateError('the prompt shows $shown, the server presents $a1');
    }
    await h.tap(_trust);
    await h.waitFor('Server saved');
    await h.tap('Done');
    // "Server saved" is the dialog's own probe. Whether the chain client uses the stored trust
    // is a separate question, and the app will not leave the working backup it fell over to when
    // the door switched to TLS, so make the primary the only choice.
    await h.setElectrumEnabled('primary_only');
    await h.waitForElectrum(
      (st) => st.connectedTo(backup: false) && st.primaryUrl == aUrl,
      describe: 'connected to the primary over TLS',
    );
    await h.setElectrumEnabled('all');

    _step('2 rotation');
    // ---- 2. Rotation: a different cert on a trusted host is a CHANGE, and rejecting it keeps
    // the old trust ----
    await faucet.electrumSetMode('a', 'tls', identity: 'a2');
    final a2 = await _fingerprint(faucet, 'a');
    _expect(
      await _connectAndSave(h, currentUrl: aUrl, url: aUrl),
      _Outcome.prompt,
      'a rotated certificate must prompt',
    );
    if (!await h.exists(_changed)) {
      throw StateError('a rotated certificate was not marked as changed');
    }
    final rotated = _hex(await h.getSelectableTextByKey('tofu-fingerprint'));
    final previous = _hex(
      await h.getSelectableTextByKey('tofu-old-fingerprint'),
    );
    if (rotated != a2 || previous != a1) {
      throw StateError(
        'expected new $a2 over old $a1, the prompt shows $rotated over $previous',
      );
    }
    await h.tap('Reject');
    // The dialog cross-fades, so the prompt outlives the Reject for a moment; a Connect & Save
    // read during the fade would see its Trust button and report a prompt that is not there.
    await h.waitForAbsent(_trust);
    // "a1 still stored", asked of the app's behaviour rather than its store: with a1 back on the
    // door, the same url must save WITHOUT a prompt.
    await faucet.electrumSetMode('a', 'tls', identity: 'a1');
    await h.tap('Connect & Save');
    _expect(
      await _outcome(h),
      _Outcome.saved,
      'rejecting a rotation must leave the original certificate trusted',
    );
    await h.tap('Done');

    final bTcp = (await h.electrumStatus()).backupUrl;

    _step('4 cross-host forgery');
    // ---- 4. A leaf signed by a TRUSTED cert, for a host we never trusted ----
    // The regression test for `0918095516`: while TOFU certs sat in the PKI root store, `a1`
    // was an unconstrained CA and this chain verified silently.
    final bUrl = await faucet.electrumSetMode(
      'b',
      'tls',
      identity: 'b_evil',
      shape: 'signed_by',
      issuer: 'a1',
    );
    _expect(
      await _connectAndSave(h, currentUrl: bTcp, url: bUrl),
      _Outcome.prompt,
      'a certificate chained to a trusted leaf was accepted for another host',
    );
    if (await h.exists(_changed)) {
      throw StateError('an untrusted host was presented as a changed one');
    }
    await h.tap('Reject');
    await h.waitForAbsent(_trust);

    // Cases 3 and 5 reuse this dialog: after Reject or Try Again it is back at its input with the
    // backup url still typed, which is how a user would retry, and the dialog has no Close.
    _step('3 expired');
    // ---- 3. Expired: refused outright, never offered for trust ----
    await faucet.electrumSetMode(
      'b',
      'tls',
      identity: 'b_expired',
      shape: 'expired',
    );
    await h.tap('Connect & Save');
    _expect(
      await _outcome(h),
      _Outcome.failed,
      'an expired certificate must fail without offering trust',
    );
    await h.tap('Try Again');
    await h.waitForAbsent('Connection failed');

    _step('5 case-folded host');
    // ---- 5. One host, two spellings: one trust entry ----
    await faucet.electrumSetMode('b', 'tls', identity: 'b1');
    final b1 = await _fingerprint(faucet, 'b');
    await h.tap('Connect & Save');
    _expect(
      await _outcome(h),
      _Outcome.prompt,
      'a first-seen server must prompt',
    );
    await h.tap(_trust);
    await h.waitFor('Server saved');
    await h.tap('Done');
    final folded = bUrl.replaceFirst('localhost', 'LocalHost');
    final got = await _connectAndSave(h, currentUrl: bUrl, url: folded);
    // #584's defect is a MISSING trust entry for the other spelling, so it can only show as a
    // first-use prompt for the certificate already trusted. Anything else is a different failure
    // and must not be reported as that one.
    if (got == _Outcome.failed) {
      throw StateError('the case-folded url failed to connect at all');
    }
    if (got == _Outcome.prompt) {
      if (await h.exists(_changed)) {
        throw StateError('the case-folded host was prompted as a CHANGED cert');
      }
      final reprompted = _hex(
        await h.getSelectableTextByKey('tofu-fingerprint'),
      );
      if (reprompted != b1) {
        throw StateError(
          're-prompted for $reprompted, the server presents $b1',
        );
      }
    }
    final hit = await _caseFolded.guard(() async {
      _expect(
        got,
        _Outcome.saved,
        'the same host spelled differently re-prompted',
      );
    });
    if (hit) {
      await faucet.close();
      return;
    }
    await h.tap('Done');

    await faucet.close();
    stdout.writeln(
      'ELECTRUM_TOFU_DRIVE_OK: first use, rotation, forgery, expiry, case-folded host',
    );
  });
}
