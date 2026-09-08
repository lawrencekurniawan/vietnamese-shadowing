import 'package:flutter_test/flutter_test.dart';

import 'package:vietnamese_shadowing/main.dart';

void main() {
  testWidgets(
    'Vietnamese Shadowing app starts',
    (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const VietnameseShadowingApp(),
      );

      expect(
        find.text(
          'Vietnamese Shadowing',
        ),
        findsOneWidget,
      );
    },
  );
}