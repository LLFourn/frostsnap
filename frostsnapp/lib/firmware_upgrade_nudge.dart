import 'dart:async';

import 'package:flutter/material.dart';
import 'package:frostsnap/device_action_upgrade.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/id_ext.dart';
import 'package:frostsnap/snackbar.dart';
import 'package:frostsnap/src/rust/api.dart';
import 'package:frostsnap/src/rust/api/device_list.dart';
import 'package:frostsnap/theme.dart';

/// In memory only — a restart offers again. Per device rather than global
/// because the prompt names the device the user is about to act on.
final _skipped = deviceIdSet([]);

/// A backstop, not the normal path: the upgrade flow's own "Done" dialog
/// usually outlasts the reboot.
const _reconnectTimeout = Duration(seconds: 30);

/// Offers a firmware upgrade for whichever of [devices] is connected and
/// eligible, before the caller starts a device workflow.
///
/// Returns false if the caller should abandon the action without starting it.
///
/// Call this *before* sending anything to the device. The coordinator's
/// protocol calls dispatch to the device the moment they are invoked, so a
/// prompt raised afterwards would be asking about a workflow the device has
/// already begun displaying.
Future<bool> maybeNudgeFirmwareUpgrade(
  BuildContext context,
  Iterable<DeviceId> devices,
) async {
  final wanted = deviceIdSet(devices);
  final targets = deviceIdSet(
    coord
        .deviceListState()
        .devices
        .where(
          (dev) =>
              wanted.contains(dev.id) &&
              !_skipped.contains(dev.id) &&
              dev.needsFirmwareUpgrade(),
        )
        .map((dev) => dev.id),
  );
  if (targets.isEmpty) return true;

  // Not barrier-dismissible: a stray tap on the scrim would abandon the action
  // entirely, which is a harsher outcome than either button offers.
  final upgrade = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpgradeOfferDialog(deviceCount: targets.length),
  );
  if (upgrade == null) return false;

  if (!upgrade) {
    _skipped.addAll(targets);
    return true;
  }

  if (!context.mounted) return false;

  final controller = DeviceActionUpgradeController();
  try {
    if (!await controller.run(context)) return false;
  } finally {
    controller.dispose();
  }

  if (await _awaitUpgraded(targets)) return true;
  if (context.mounted) {
    showErrorSnackbar(context, 'Device did not reconnect after the upgrade');
  }
  return false;
}

/// The caller's protocol would fail with "device not connected" if it fired
/// into the window while the device is still re-enumerating after its reboot.
Future<bool> _awaitUpgraded(Set<DeviceId> targets) async {
  bool ready(DeviceListState state) => targets.every((id) {
    final device = state.getDevice(id: id);
    return device != null && !device.needsFirmwareUpgrade();
  });

  if (ready(coord.deviceListState())) return true;

  try {
    await GlobalStreams.deviceListSubject
        .firstWhere((update) => ready(update.state))
        .timeout(_reconnectTimeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

class _UpgradeOfferDialog extends StatelessWidget {
  final int deviceCount;

  const _UpgradeOfferDialog({required this.deviceCount});

  @override
  Widget build(BuildContext context) {
    final versionName = coord.upgradeFirmwareVersionName() ?? '';
    final subject = deviceCount == 1
        ? 'This device'
        : 'These $deviceCount devices';

    return AlertDialog(
      title: Text('Firmware upgrade available'),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, minWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('$subject can be upgraded before you continue.'),
            SizedBox(height: 16),
            SelectionArea(
              child: Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  title: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: 'New Firmware '),
                        TextSpan(text: versionName, style: monospaceTextStyle),
                      ],
                    ),
                  ),
                  subtitle: Text(
                    coord.upgradeFirmwareDigest() ?? '',
                    style: monospaceTextStyle.copyWith(fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('Skip'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text('Upgrade'),
        ),
      ],
    );
  }
}
