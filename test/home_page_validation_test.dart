import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaxp_flutter_meet/main.dart';

void main() {
  testWidgets('Invalid room shows SnackBar', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '!!');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Valid room does not show SnackBar on submit', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'standup_10');
    await tester.testTextInput.receiveAction(TextInputAction.go);

    // Pump a frame to allow any SnackBar to appear if wrongly shown
    await tester.pump();

    expect(find.byType(SnackBar), findsNothing);
  });
}