import 'dart:async';

import 'package:seance_core/src/ssh/sequential_cleanup.dart';
import 'package:test/test.dart';

void main() {
  const actionTimeout = Duration(milliseconds: 10);

  test('cleanup attempts every action and preserves the first error', () async {
    final firstError = StateError('first');
    final actionsRun = <String>[];

    await expectLater(
      runSequentialCleanup(
        [
          () {
            actionsRun.add('first');
            throw firstError;
          },
          () => actionsRun.add('second'),
          () {
            actionsRun.add('third');
            throw StateError('third');
          },
        ],
        actionTimeout: actionTimeout,
      ),
      throwsA(same(firstError)),
    );

    expect(actionsRun, ['first', 'second', 'third']);
  });

  test('ignored cleanup failures remain bounded', () async {
    var laterActionRan = false;

    await runSequentialCleanup(
      [
        () => Completer<void>().future,
        () => laterActionRan = true,
      ],
      actionTimeout: actionTimeout,
      failureMode: CleanupFailureMode.ignore,
    );

    expect(laterActionRan, isTrue);
  });
}
