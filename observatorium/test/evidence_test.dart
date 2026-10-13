// @trace spec:observatorium-dashboard
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tillandsias_observatorium/main.dart';
import 'package:tillandsias_observatorium/model.dart';

Map<String, dynamic> fixture() => {
  'schemaVersion': 1,
  'generatedAt': '2026-10-13T00:00:00Z',
  'revision': '123456789abcdef',
  'epoch': {'description': 'Measured snapshot epoch'},
  'current': {
    'specs': {'files': 2, 'requirements': 4, 'scenarios': 6},
    'plan': {
      'total': 3,
      'states': {'done': 1, 'ready': 2},
    },
    'residual': {
      'value': null,
      'source': 'none',
      'reason': 'No comparable measurement',
    },
    'commits': {'total': 20},
  },
  'graph': {
    'scale': 'log10(1+x)',
    'series': [
      {
        'id': 'commits',
        'label': 'Commits',
        'points': [
          {'date': '2026-10-12', 'value': 0, 'y': 0},
          {'date': '2026-10-13', 'value': 20, 'y': 1.322219},
        ],
      },
      {
        'id': 'residual',
        'label': 'Residual',
        'points': [
          {'date': '2026-10-12', 'value': null, 'y': null},
          {'date': '2026-10-13', 'value': null, 'y': null},
        ],
      },
    ],
  },
  'gaps': ['Residual has not been measured.'],
  'details': {
    'specs': [
      {
        'path': 'openspec/specs/example/spec.md',
        'requirements': 4,
        'scenarios': 6,
      },
    ],
    'plan': [
      {'id': '1-example', 'title': 'An observed order', 'status': 'done'},
    ],
  },
};
void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('dashboard adapts to $width pixel screens', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ObservatoriumApp(evidence: Evidence.decode(jsonEncode(fixture()))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test('preserves true zero and missing evidence independently', () {
    final evidence = Evidence.decode(jsonEncode(fixture()));
    expect(evidence.series.first.points.first.value, 0);
    expect(evidence.series.first.points.first.y, 0);
    expect(evidence.series.last.points.first.value, isNull);
    expect(evidence.series.last.points.first.y, isNull);
    expect(evidence.gaps.single, 'Residual has not been measured.');
  });
  test('rejects an unrecognized scale instead of mislabeling coordinates', () {
    final data = fixture();
    (data['graph'] as Map)['scale'] = 'linear';
    expect(() => Evidence.decode(jsonEncode(data)), throwsFormatException);
  });
  testWidgets(
    'exposes missing evidence, scale controls and filterable source rows',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ObservatoriumApp(evidence: Evidence.decode(jsonEncode(fixture()))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Observatorium'), findsOneWidget);
      expect(find.text('Unmeasured'), findsOneWidget);
      expect(find.text('Residual has not been measured.'), findsOneWidget);
      await tester.tap(find.text('Log scale'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.text('Y: raw count. All series share a zero baseline.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'not-present');
      await tester.pump();
      expect(find.text('No matching evidence.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
