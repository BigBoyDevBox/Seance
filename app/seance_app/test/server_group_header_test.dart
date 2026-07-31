import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/ui/server_list_pane.dart';

/// The header is the app's only collapsible surface, so what a screen reader
/// makes of a chevron and a bare count is asserted rather than assumed.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required String name,
    required int count,
    required bool collapsed,
    VoidCallback? onToggle,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ServerGroupHeader(
          name: name,
          count: count,
          collapsed: collapsed,
          onToggle: onToggle ?? () {},
        ),
      ),
    ),
  );

  testWidgets('shows the name, the count, and a direction', (tester) async {
    await pump(tester, name: 'Production', count: 3, collapsed: false);
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    await pump(tester, name: 'Production', count: 3, collapsed: true);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('tapping anywhere on the row toggles', (tester) async {
    var toggles = 0;
    await pump(
      tester,
      name: 'Production',
      count: 3,
      collapsed: false,
      onToggle: () => toggles++,
    );
    await tester.tap(find.text('Production'));
    await tester.tap(find.text('3'));
    expect(toggles, 2);
  });

  testWidgets('is announced as one control that says what it holds', (
    tester,
  ) async {
    await pump(tester, name: 'Production', count: 3, collapsed: false);
    // Found through a widget *inside* the merge boundary: getSemantics walks
    // up to the nearest enclosing node, and from the header itself that is the
    // route above the boundary, not the merged node under it.
    final node = tester.getSemantics(find.text('Production'));
    // getSemanticsData(), not the node's own fields: MergeSemantics folds the
    // descendants' labels in at data time, so reading `node.label` would see
    // the empty label of the node they merged *into*.
    final data = node.getSemanticsData();
    // One merged control, not a name and an orphaned number: the count says
    // what there are three *of*, and the fold state is spoken rather than left
    // to the chevron, which is invisible to a screen reader.
    expect(data.label, contains('Production'));
    expect(data.label, contains('3 servers'));
    expect(
      node,
      isSemantics(hasExpandedState: true, isExpanded: true, hasTapAction: true),
    );

    await pump(tester, name: 'Production', count: 3, collapsed: true);
    expect(
      tester.getSemantics(find.text('Production')),
      isSemantics(hasExpandedState: true, isExpanded: false),
    );
  });

  testWidgets('a group of one is announced in the singular', (tester) async {
    await pump(tester, name: 'CI', count: 1, collapsed: false);
    final label = tester
        .getSemantics(find.text('CI'))
        .getSemanticsData()
        .label;
    expect(label, contains('1 server'));
    expect(label, isNot(contains('1 servers')));
  });
}
