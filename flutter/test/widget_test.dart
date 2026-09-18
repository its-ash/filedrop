// Smoke test: verifies the FileDrop app widget tree builds without
// throwing. Full FFI-backed behavior isn't exercised here since
// FileDropFfiService's real bindings aren't wired up in this scaffold
// pass (see lib/services/filedrop_ffi_service.dart) — this test only
// guards against build-time regressions in the widget tree itself.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:filedrop/main.dart';

void main() {
  testWidgets('FileDropApp renders a MaterialApp', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: FileDropApp()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
