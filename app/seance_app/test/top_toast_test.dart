import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/top_toast.dart';

void main() {
  testWidgets('top toast shows its message then auto-dismisses', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showTopToast(
                Overlay.of(context),
                message: 'Inserted: ls -la',
                duration: const Duration(seconds: 3),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump(); // insert the overlay entry
    await tester.pump(const Duration(milliseconds: 200)); // fade/slide in
    expect(find.text('Inserted: ls -la'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4)); // past the duration
    await tester.pump(); // process removal
    expect(find.text('Inserted: ls -la'), findsNothing);
  });

  testWidgets('toasts stack instead of overlapping, and actions fire',
      (tester) async {
    var uploaded = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                showTopToast(
                  Overlay.of(context),
                  message: 'first',
                  duration: const Duration(seconds: 6),
                );
                showTopToast(
                  Overlay.of(context),
                  message: 'second',
                  duration: const Duration(seconds: 6),
                  actionLabel: 'Upload',
                  onAction: () => uploaded++,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
    // Stacked vertically, not painted on top of each other.
    final firstBottom = tester.getBottomLeft(find.text('first')).dy;
    final secondTop = tester.getTopLeft(find.text('second')).dy;
    expect(secondTop, greaterThan(firstBottom));

    await tester.tap(find.text('Upload'));
    await tester.pump();
    expect(uploaded, 1);
    expect(find.text('second'), findsNothing);
    expect(find.text('first'), findsOneWidget);

    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    expect(find.text('first'), findsNothing);
  });
}
