// @trace spec:observatorium-dashboard
import 'dart:convert';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tillandsias_observatorium/main.dart';
import 'package:tillandsias_observatorium/model.dart';
import 'package:tillandsias_observatorium/evidence_chart.dart';

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
  testWidgets(
    'periodic refresh preserves controls and keeps last evidence on failure',
    (tester) async {
      var calls = 0;
      Future<Evidence> load() async {
        calls++;
        if (calls == 3) throw StateError('offline');
        final data = fixture();
        data['generatedAt'] = '2026-10-13T00:0$calls:00Z';
        return Evidence.decode(jsonEncode(data));
      }

      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(home: EvidenceLoader(loadEvidence: load)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Log scale'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(calls, 2);
      expect(
        find.text('Y: raw count. All series share a zero baseline.'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(
        find.text(
          'Latest refresh unavailable; showing the last loaded snapshot.',
        ),
        findsOneWidget,
      );
      expect(find.text('Observatorium'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 3);
    },
  );
  testWidgets('an unavailable specification scan is shown as unmeasured', (
    tester,
  ) async {
    final data = fixture();
    data['current'] = Map<String, dynamic>.from(data['current'] as Map)
      ..['specs'] = null;
    await tester.pumpWidget(
      ObservatoriumApp(evidence: Evidence.decode(jsonEncode(data))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Unmeasured'), findsNWidgets(2));
    expect(
      find.text('Unmeasured requirements · Unmeasured scenarios'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
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
      final before =
          tester
                  .widget<GameWidget>(
                    find.byWidgetPredicate((w) => w is GameWidget),
                  )
                  .game
              as EvidenceChart;
      expect(before.logarithmic, isTrue);
      expect(before.paused, isTrue);
      await tester.tap(find.text('Log scale'));
      await tester.pump(const Duration(milliseconds: 100));
      final after =
          tester
                  .widget<GameWidget>(
                    find.byWidgetPredicate((w) => w is GameWidget),
                  )
                  .game
              as EvidenceChart;
      expect(after.logarithmic, isFalse);
      expect(identical(before, after), isFalse);
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
  testWidgets(
    'the headline residual is the release cut; the deploy grade is a labelled display-only card (1661-vckd)',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final data = fixture();
      final current = data['current'] as Map<String, dynamic>;
      current['residual'] = {
        'value': 1527,
        'release': 'v56.10.13.1',
        'reason': 'Release v56.10.13.1 cut (2026-10-13): graded after a recorded litmus run',
      };
      current['residualLive'] = {
        'traced': 2,
        'displayOnly': true,
        'label': 'Requirements traced at this deploy, display-only',
      };
      await tester.pumpWidget(
        ObservatoriumApp(evidence: Evidence.decode(jsonEncode(data))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('LIVE GRADE · DISPLAY-ONLY'), findsOneWidget);
      expect(
        find.text('Requirements traced at this deploy, display-only'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Release v56.10.13.1 cut (2026-10-13): graded after a recorded litmus run',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
