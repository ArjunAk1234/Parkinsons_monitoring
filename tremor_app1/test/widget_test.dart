// // This is a basic Flutter widget test.
// //
// // To perform an interaction with a widget in your test, use the WidgetTester
// // utility in the flutter_test package. For example, you can send tap and scroll
// // gestures. You can also use WidgetTester to find child widgets in the widget
// // tree, read text, and verify that the values of widget properties are correct.

// import 'package:flutter/material.dart';
// import 'package:flutter_test/flutter_test.dart';

// import 'package:tremor_app1/main.dart';

// void main() {
//   testWidgets('Counter increments smoke test', (WidgetTester tester) async {
//     // Build our app and trigger a frame.
//     await tester.pumpWidget(const MyApp());

//     // Verify that our counter starts at 0.
//     expect(find.text('0'), findsOneWidget);
//     expect(find.text('1'), findsNothing);

//     // Tap the '+' icon and trigger a frame.
//     await tester.tap(find.byIcon(Icons.add));
//     await tester.pump();

//     // Verify that our counter has incremented.
//     expect(find.text('0'), findsNothing);
//     expect(find.text('1'), findsOneWidget);
//   });
// }
// import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tremor_app1/main.dart';

void main() {
  testWidgets('Tremor app loads correctly', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget( TremorMonitorScreen() );

    // Verify that the app title appears
    expect(find.text('Tremor Detector'), findsOneWidget);
    
    // Verify that the status section exists
    expect(find.text('Normal'), findsOneWidget);
    
    // Verify that the history section exists
    expect(find.text('Tremor History'), findsOneWidget);
    
    // Verify that the "No tremor data yet" message appears initially
    expect(find.text('No tremor data yet'), findsOneWidget);
  });
}