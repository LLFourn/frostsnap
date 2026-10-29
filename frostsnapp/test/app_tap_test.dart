import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_driver/app_tap.dart';
import '../test_driver/tooltip_resolve.dart';

// fsim-app-pixel-tap: the resolver feeds find.byTooltip ONE exact string (every input path, exact
// strings included, gets diagnostics), and tap-at speaks GLOBAL LOGICAL pixels — the widget tests pin
// the coordinate model on a non-1x view with a translated target so a DPR-scaling or local-rect
// mistake cannot come back.
void main() {
  group('resolveTooltip', () {
    const available = ['Edit device name', 'Delete wallet', 'Edit wallet'];

    test('exact string resolves to itself', () {
      expect(resolveTooltip('Delete wallet', available), 'Delete wallet');
    });

    test('unknown exact string lists the available tooltips', () {
      expect(
        () => resolveTooltip('Rename', available),
        throwsA(
          predicate(
            (e) =>
                '$e'.contains('no on-stage tooltip') &&
                '$e'.contains('Edit device name') &&
                '$e'.contains('Delete wallet'),
          ),
        ),
      );
    });

    test('duplicated exact tooltip errors with its matches', () {
      expect(
        () => resolveTooltip('Edit', ['Edit', 'Edit']),
        throwsA(predicate((e) => '$e'.contains('ambiguous'))),
      );
    });

    test('regex resolves when it matches exactly one', () {
      expect(resolveTooltip(RegExp(r'Delete.*'), available), 'Delete wallet');
    });

    test('ambiguous regex lists every match', () {
      expect(
        () => resolveTooltip(RegExp(r'Edit.*'), available),
        throwsA(
          predicate(
            (e) =>
                '$e'.contains('ambiguous') &&
                '$e'.contains('Edit device name') &&
                '$e'.contains('Edit wallet'),
          ),
        ),
      );
    });

    test('regex with no match lists availability; empty stage says none', () {
      expect(
        () => resolveTooltip(RegExp(r'zzz'), available),
        throwsA(predicate((e) => '$e'.contains('no on-stage tooltip'))),
      );
      expect(
        () => resolveTooltip('x', const []),
        throwsA(predicate((e) => '$e'.contains('(none)'))),
      );
    });

    test('exact string never substring-matches', () {
      expect(
        () => resolveTooltip('Edit', available),
        throwsA(predicate((e) => '$e'.contains('no on-stage tooltip'))),
      );
    });
  });

  group('parseTapAt', () {
    test('parses x,y with whitespace', () {
      expect(parseTapAt('12.5, 40'), const Offset(12.5, 40));
    });

    test('malformed payloads return null', () {
      expect(parseTapAt(''), isNull);
      expect(parseTapAt('12'), isNull);
      expect(parseTapAt('a,b'), isNull);
      expect(parseTapAt('1,2,3'), isNull);
    });

    test('non-finite axes are rejected (NaN passes every bounds compare)', () {
      expect(parseTapAt('NaN,5'), isNull);
      expect(parseTapAt('5,NaN'), isNull);
      expect(parseTapAt('Infinity,5'), isNull);
      expect(parseTapAt('5,-Infinity'), isNull);
    });
  });

  group('tapAtBoundsError', () {
    const size = Size(400, 800);

    test('inside is accepted, edges are half-open', () {
      expect(tapAtBoundsError(const Offset(0, 0), size), isNull);
      expect(tapAtBoundsError(const Offset(399.9, 799.9), size), isNull);
      expect(tapAtBoundsError(const Offset(400, 0), size), isNotNull);
      expect(tapAtBoundsError(const Offset(0, 800), size), isNotNull);
    });

    test('negative and far-out coordinates name the logical size', () {
      final err = tapAtBoundsError(const Offset(-1, 5), size)!;
      expect(err, contains('400'));
      expect(err, contains('800'));
    });
  });

  group('dispatchLogicalTap', () {
    testWidgets(
      'hits a translated target at its global LOGICAL center on a 2x view',
      (tester) async {
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.resetDevicePixelRatio);
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Padding(
              // Asymmetric translation: a local-rect or DPR-scaled dispatch cannot land here.
              padding: const EdgeInsets.only(left: 120, top: 260),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 60,
                  height: 40,
                  child: GestureDetector(onTap: () => taps++),
                ),
              ),
            ),
          ),
        );
        // Global logical center of the 60x40 target translated by (120, 260).
        dispatchLogicalTap(
          const Offset(120 + 30, 260 + 20),
          viewId: tester.view.viewId,
        );
        await tester.pump();
        expect(taps, 1);
        // A DPR-scaled dispatch (x2) would have landed here instead — prove it misses the target.
        dispatchLogicalTap(
          const Offset((120 + 30) * 2, (260 + 20) * 2),
          viewId: tester.view.viewId,
        );
        await tester.pump();
        expect(taps, 1);
      },
    );
  });
}
