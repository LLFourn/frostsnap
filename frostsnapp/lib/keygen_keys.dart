import 'package:flutter/widgets.dart';

/// Stable widget [Key]s for the keygen flow controls.
///
/// This is the single source of truth shared by the app and the out-of-process
/// sim driver (sim-7): both sides reference these exact handles so a script and
/// a human read the same names. The `keygen.*` value strings make a mismatch in
/// the driver obvious at a glance.
abstract final class KeygenKeys {
  /// "Create a multi-sig wallet" entry in the wallet-add list.
  static const createMultisigEntry = ValueKey<String>(
    'keygen.createMultisigEntry',
  );

  /// The single step-advance button whose label/action vary by step, keyed PER
  /// STEP (`keygen.next.<step>`, e.g. `keygen.next.name`/`.devices`/`.threshold`)
  /// so the sim-7 driver can both target it and assert which step it is on. The
  /// button has no retained state and the step page rebuilds on every transition,
  /// so the per-step key changing element identity across steps is harmless.
  static ValueKey<String> primaryButtonForStep(String step) =>
      ValueKey<String>('keygen.next.$step');

  /// Per-device inline name field in the devices step (a devices-step landmark).
  static const deviceNameField = ValueKey<String>('keygen.deviceNameField');

  /// The threshold selector in the threshold step (a threshold-step landmark).
  static const thresholdSelector = ValueKey<String>('keygen.thresholdSelector');

  /// "Yes" in the keygen security-check confirm dialog.
  static const confirmYes = ValueKey<String>('keygen.confirmYes');

  /// "No" in the keygen security-check confirm dialog.
  static const confirmNo = ValueKey<String>('keygen.confirmNo');

  /// "Cancel" in the keygen dialog footer.
  static const dialogCancel = ValueKey<String>('keygen.dialogCancel');
}
