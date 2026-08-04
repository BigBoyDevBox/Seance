import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/built_in_text_editor.dart';
import 'package:seance_app/ui/editor_syntax.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-editor-test-');
    file = File('${directory.path}/config.txt');
    await file.writeAsString('one\ntwo\n');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads UTF-8 and atomically saves edited text', () async {
    expect(await loadBuiltInTextDocument(file), 'one\ntwo\n');

    await saveBuiltInTextDocument(file, 'changed\n');

    expect(await file.readAsString(), 'changed\n');
    expect(await directory.list().length, 1);
  });

  test('preserves a UTF-8 BOM and CRLF line endings', () async {
    await file.writeAsBytes([0xef, 0xbb, 0xbf, ...'one\r\ntwo\r\n'.codeUnits]);
    final document = await loadBuiltInTextDocumentDetails(file);

    expect(document.text, 'one\r\ntwo\r\n');
    expect(document.hasUtf8Bom, isTrue);
    expect(document.lineEnding, '\r\n');

    await saveBuiltInTextDocument(
      file,
      '${document.text}three\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      ...'one\r\ntwo\r\nthree\r\n'.codeUnits,
    ]);
  });

  test('refuses to overwrite an independently changed local copy', () async {
    final document = await loadBuiltInTextDocumentDetails(file);
    await file.writeAsString('external change\n');

    await expectLater(
      saveBuiltInTextDocument(
        file,
        'built-in change\n',
        expectedSha256: document.sha256,
      ),
      throwsStateError,
    );
    expect(await file.readAsString(), 'external change\n');
  });

  test('rejects malformed, binary, and oversized content', () async {
    await file.writeAsBytes([0xff]);
    await expectLater(loadBuiltInTextDocument(file), throwsStateError);

    await file.writeAsBytes([0, 1, 2]);
    await expectLater(loadBuiltInTextDocument(file), throwsStateError);

    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      loadBuiltInTextDocument(file, maximumBytes: 2),
      throwsStateError,
    );
  });

  testWidgets('edits, saves, and reports the local save', (tester) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('one\ntwo\n'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'edited locally\n');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pumpAndSettle();

    expect(savedText, 'edited locally\n');
    expect(saved, 1);
    expect(find.textContaining('Saved locally'), findsOneWidget);
  });

  testWidgets('protects unsaved changes when leaving', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'unsaved');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    expect(find.text('unsaved'), findsOneWidget);
  });

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets('Ctrl-S saves and uploads a server file immediately',
      (tester) async {
    var uploads = 0;
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\ntwo\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
          onUpload: () async {
            uploads++;
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(uploads, 1);
    // The upload reconciles the copy itself; onSaved only runs when it fails.
    expect(saved, 0);
    expect(find.text('Saved and uploaded.'), findsOneWidget);
    // No confirmation dialog of any kind appeared.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('Ctrl-S falls back to reconciling when the upload fails',
      (tester) async {
    var saved = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async {},
          onSaved: () async => saved++,
          onUpload: () async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(saved, 1);
    expect(find.text('Saved locally; not uploaded.'), findsOneWidget);
  });

  testWidgets('Ctrl-S saves locally when there is no upload target',
      (tester) async {
    var saved = 0;
    String? savedText;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
          saveDocument: (_, text) async => savedText = text,
          onSaved: () async => saved++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'edited\n');
    await tester.pump();
    await pressCtrlS(tester);
    await tester.pumpAndSettle();

    expect(savedText, 'edited\n');
    expect(saved, 1);
    expect(find.text('Saved locally.'), findsOneWidget);
  });

  testWidgets('opens scrolled to the top with the caret at the start',
      (tester) async {
    final longText =
        List.generate(400, (index) => 'line $index').join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/long.txt',
          initialText: longText,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(TextField),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, 0);
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.controller.selection.baseOffset, 0);
  });

  testWidgets('uses a monospace font stack', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'one\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    final style = tester.widget<TextField>(find.byType(TextField)).style;
    expect(style?.fontFamilyFallback, contains('monospace'));
  });

  testWidgets('find bar counts matches, navigates, wraps, and toggles case',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'alpha beta\nBeta gamma\nbeta end\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    final searchField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == 'Find in file',
    );
    expect(searchField, findsOneWidget);

    await tester.enterText(searchField, 'beta');
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous match'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget); // wraps backwards

    // The caret is parked on the third match; the case-sensitive re-search
    // drops 'Beta' and resumes from the caret, i.e. its second match.
    await tester.tap(find.byTooltip('Match case'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(searchField, findsNothing);
  });

  testWidgets('search highlights land on the editor text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'alpha beta\n',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Find'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in file',
      ),
      'beta',
    );
    await tester.pumpAndSettle();

    final editorField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.controller is CodeEditingController,
        )
        .first;
    final controller = tester.widget<TextField>(editorField).controller!
        as CodeEditingController;
    expect(controller.searchMatches, hasLength(1));
    expect(controller.searchMatches.single.start, 6);
    expect(controller.activeMatchIndex, 0);
  });

  testWidgets('edits made during a save remain unsaved', (tester) async {
    final saveStarted = Completer<void>();
    final finishSave = Completer<void>();
    String? persisted;
    await tester.pumpWidget(
      MaterialApp(
        home: BuiltInTextEditorScreen(
          file: file,
          remotePath: '/etc/config.txt',
          initialText: 'initial',
          saveDocument: (_, text) async {
            persisted = text;
            saveStarted.complete();
            await finishSave.future;
          },
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'first edit');
    await tester.pump();
    await tester.tap(find.byTooltip('Save locally'));
    await tester.pump();
    await saveStarted.future;
    await tester.enterText(find.byType(TextField), 'newer edit');
    finishSave.complete();
    await tester.pumpAndSettle();

    expect(persisted, 'first edit');
    expect(find.textContaining('Unsaved'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.save_outlined),
          )
          .onPressed,
      isNotNull,
    );
  });
}
