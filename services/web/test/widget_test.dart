import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:budgify_web/main.dart';

void main() {
  testWidgets('Budgify brand uses the product name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BrandMark()));
    expect(find.text('budgify'), findsOneWidget);
  });

  testWidgets('registration form validates required account fields', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AuthScreen(
          api: Api(),
          error: null,
          busy: false,
          onAuthenticate: (register, email, password) async {},
        ),
      ),
    ));

    await tester.tap(find.text('New to Budgify? Create an account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
  });
}
