import 'package:flutter/services.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:frostsnap/main.dart' as app;

/// Driver data channel for clipboard access the harness can't get off the widget tree by semantic
/// label. `clipboard` reads the app clipboard (e.g. a wallet receive address after its Copy
/// button); `setclip:<text>` writes it (e.g. to seed a recipient before a Paste button) — portably,
/// via Flutter's own Clipboard, so scenarios don't shell out to pbcopy/xclip. Test-only.
Future<String> _driverData(String? payload) async {
  const setClipPrefix = 'setclip:';
  if (payload != null && payload.startsWith(setClipPrefix)) {
    await Clipboard.setData(
      ClipboardData(text: payload.substring(setClipPrefix.length)),
    );
    return 'ok';
  }
  switch (payload) {
    case 'clipboard':
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text ?? '';
    default:
      throw 'sim_app: unknown driver data request "$payload"';
  }
}

/// Instrumented SIM entrypoint (the app channel of the sim-8 harness).
///
/// Enables the `flutter_driver` extension so the out-of-process harness can drive the
/// app's widget tree by semantic label over the VM service, then runs the normal app.
/// Lives in `test_driver/` so `flutter_driver` stays a dev-dependency and never enters
/// production `lib/main.dart`. SIM mode + a clean app dir come from the run flags:
///
///   flutter run -t test_driver/sim_app.dart --dart-define=SIM=true \
///     --dart-define=SIM_APP_DIR=/tmp/...
Future<void> main() {
  // Who owns the keyboard — the one mode switch for the session. When the AGENT owns it,
  // text is emulated through flutter_driver (`driver.enterText` works) and the real
  // keyboard is blocked; when the USER owns it, the real keyboard works and
  // `driver.enterText` does not. The two are mutually exclusive (no hybrid). Defaults to
  // the agent (the automated test path); `simctl serve` hands the keyboard to a human.
  const agentOwnsKeyboard = bool.fromEnvironment(
    'SIM_AGENT_OWNS_KEYBOARD',
    defaultValue: true,
  );
  enableFlutterDriverExtension(
    handler: _driverData,
    enableTextEntryEmulation: agentOwnsKeyboard,
  );
  return app.main();
}
