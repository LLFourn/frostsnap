import 'package:flutter/widgets.dart';

/// SIM-ONLY: a text scale the harness imposes on the app, for a desktop that has no system font
/// scale. Null leaves the platform's own scale in place, which on Android is the system setting.
final simTextScale = ValueNotifier<double?>(null);

/// Applies [simTextScale] to [child]'s `MediaQuery`, the way a system font scale would.
class SimTextScale extends StatelessWidget {
  final Widget child;

  const SimTextScale({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: simTextScale,
      builder: (context, scale, _) => scale == null
          ? child
          : MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child,
            ),
    );
  }
}
