// @trace spec:observatorium-dashboard
import 'dart:convert';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tillandsias_observatorium/convergence.dart';
import 'package:tillandsias_observatorium/main.dart';
import 'package:tillandsias_observatorium/model.dart';
import 'package:tillandsias_observatorium/evidence_chart.dart';

Map<String, dynamic> fixture({bool measured = true}) => {
  'schemaVersion': 1,
  'generatedAt': '2026-10-18T00:00:00Z',
  'revision': '123456789abcdef',
  'epoch': {'description': 'Measured snapshot epoch'},
  'current': {
    'specs': {'files': 2, 'requirements': 4, 'scenarios': 6},
    'plan': {
      'total': 3,
      'states': {'done': 1, 'ready': 2},
    },
    'residual': measured
        ? {
            'value': 3,
            'satisfied': 0,
            'denominator': 3,
            'declared': 2,
            'traced': 1,
            'positivelyTested': 0,
            'histogram': {'declared': 2, 'traced': 1, 'positively_tested': 0},
            'records': 166,
            'reasons': {'no-binding': 2, 'unrun': 1},
            'recordScope': 'global run-log count',
            'source': 'release/grade.json',
            'release': 'v56.10.17.1',
            'measuredAt': '2026-10-17T00:00:00Z',
            'revision': 'release123',
            'provenance': {
              'limitations': ['Legacy snapshot has no per-obligation hashes.'],
              'population': 'Active named scenarios',
              'excluded': {'retired': 2},
              'invariantsExcluded': 4,
              'populationGaps': ['Ambiguous scenario'],
            },
          }
        : {
            'value': null,
            'source': 'none',
            'reason': 'No comparable measurement',
          },
    if (measured)
      'residualLive': {
        'value': 2,
        'satisfied': 1,
        'denominator': 3,
        'histogram': {'declared': 1, 'traced': 1, 'positively_tested': 1},
        'source': 'working/grade.json',
        'revision': '123456789abcdef',
        'measuredAt': '2026-10-18T00:00:00Z',
        'dirty': true,
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
          {'date': '2026-10-17', 'value': 20, 'y': 1.322219},
        ],
      },
      {
        'id': 'earned',
        'label': 'Earned obligations',
        'points': [
          {
            'date': '2026-10-17',
            'value': measured ? 0 : null,
            'y': measured ? 0 : null,
          },
        ],
      },
      {
        'id': 'denominator',
        'label': 'Obligation denominator',
        'points': [
          {
            'date': '2026-10-17',
            'value': measured ? 3 : null,
            'y': measured ? 0.60206 : null,
          },
        ],
      },
      {
        'id': 'residual',
        'label': 'Residual obligations',
        'points': [
          {'date': '2026-10-12', 'value': null, 'y': null},
          {
            'date': '2026-10-17',
            'value': measured ? 3 : null,
            'y': measured ? 0.60206 : null,
          },
        ],
      },
    ],
  },
  'gaps': ['Historical intervals without observations remain unmeasured.'],
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
    if (measured)
      'obligations': [
        {
          'id': 'scenario-declared',
          'req_id': 'req-a',
          'spec': 'spec-alpha',
          'state': 'declared',
          'reason': 'No implementation trace',
        },
        {
          'id': 'scenario-traced',
          'req_id': 'req-b',
          'spec': 'spec-beta',
          'state': 'traced',
          'reason': 'No matched positive test record',
          'host': 'linux',
        },
        {
          'id': 'scenario-tested',
          'req_id': 'req-c',
          'spec': 'spec-gamma',
          'state': 'positively_tested',
          'reason': 'Positive record matches the obligation',
        },
      ],
  },
};

void viewport(
  WidgetTester tester, {
  double width = 1400,
  double height = 1800,
}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> showEvidence(
  WidgetTester tester,
  Map<String, dynamic> data,
) async {
  await tester.pumpWidget(
    ObservatoriumApp(evidence: Evidence.decode(jsonEncode(data))),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
}

EvidenceChart chart(WidgetTester tester) =>
    tester
            .widget<GameWidget>(
              find.byWidgetPredicate((widget) => widget is GameWidget),
            )
            .game
        as EvidenceChart;

void main() {
  test(
    'HTTP loader uses the published artifact and requests revalidation',
    () async {
      final client = MockClient((request) async {
        expect(
          request.url.toString(),
          'https://example.test/dashboard/data/metrics.json',
        );
        expect(request.headers['Cache-Control'], 'no-cache');
        return http.Response(jsonEncode(fixture()), 200);
      });
      final evidence = await fetchEvidence(
        client: client,
        base: Uri.parse('https://example.test/dashboard/'),
      );
      expect(evidence.releaseGrade.earned, 0);
      expect(evidence.releaseGrade.denominator, 3);
      expect(evidence.liveGrade!.earned, 1);
      client.close();
    },
  );

  test('HTTP loader rejects failed responses before decoding', () async {
    final client = MockClient((_) async => http.Response('unavailable', 503));
    await expectLater(
      fetchEvidence(client: client, base: Uri.parse('https://example.test/')),
      throwsStateError,
    );
    client.close();
  });

  testWidgets(
    'periodic refresh preserves controls and retains the last loaded evidence on failure',
    (tester) async {
      var calls = 0;
      Future<Evidence> load() async {
        calls++;
        if (calls == 3) throw StateError('offline');
        final data = fixture();
        data['generatedAt'] = '2026-10-18T00:0$calls:00Z';
        return Evidence.decode(jsonEncode(data));
      }

      viewport(tester);
      await tester.pumpWidget(
        MaterialApp(home: EvidenceLoader(loadEvidence: load)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await reveal(tester, find.text('Log scale'));
      await tester.tap(find.text('Log scale'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(calls, 2);
      expect(chart(tester).logarithmic, isFalse);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(
        find.text(
          'Latest refresh unavailable; showing the last loaded snapshot.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 3);
    },
  );

  testWidgets(
    'release and live grades have separate counts, sources and observation times',
    (tester) async {
      viewport(tester);
      await showEvidence(tester, fixture());
      final headline = find.byType(ConvergencePanel);
      expect(
        find.descendant(of: headline, matching: find.text('0')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: headline, matching: find.text('3')),
        findsNWidgets(2),
      );
      expect(find.text('v56.10.17.1'), findsOneWidget);
      expect(find.text('Source: release/grade.json'), findsOneWidget);
      expect(find.text('Observed: 2026-10-17T00:00:00Z'), findsOneWidget);
      expect(find.text('LIVE WORKING TREE · DISPLAY-ONLY'), findsOneWidget);
      expect(
        find.text('1 earned / 3 obligations · 2 residual'),
        findsOneWidget,
      );
      expect(find.text('Source: working/grade.json'), findsOneWidget);
      expect(find.text('Observed: 2026-10-18T00:00:00Z'), findsOneWidget);
      expect(find.text('Positively tested · 0'), findsOneWidget);
      expect(
        find.text('Residual reasons: no-binding · 2 / unrun · 1'),
        findsOneWidget,
      );
      expect(
        find.textContaining('166 global run-log records.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Higher evidence states are unavailable.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Evidence provenance and limits'));
      await tester.pumpAndSettle();
      expect(
        find.text('Legacy snapshot has no per-obligation hashes.'),
        findsOneWidget,
      );
      expect(find.text('gradeSha256: Unavailable'), findsOneWidget);
      expect(find.text('Population: Active named scenarios'), findsOneWidget);
      expect(find.text('Excluded obligations: retired: 2'), findsOneWidget);
      expect(find.text('Excluded invariants: 4'), findsOneWidget);
      expect(find.text('Population gaps: Ambiguous scenario'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'missing evidence remains unmeasured and missing obligations have an explanation',
    (tester) async {
      viewport(tester);
      final data = fixture(measured: false);
      data['current'] = Map<String, dynamic>.from(data['current'] as Map)
        ..['specs'] = null;
      await showEvidence(tester, data);
      expect(
        find.descendant(
          of: find.byType(ConvergencePanel),
          matching: find.text('Unmeasured'),
        ),
        findsNWidgets(3),
      );
      expect(find.text('No measured release'), findsOneWidget);
      expect(
        find.text('Live obligation evidence is unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Obligation evidence is unavailable. No per-obligation rows were published.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Unmeasured requirements · Unmeasured scenarios'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'dashboard and obligation controls fit a $width pixel viewport',
      (tester) async {
        viewport(tester, width: width, height: 900);
        await showEvidence(tester, fixture());
        expect(tester.takeException(), isNull);
        await reveal(tester, find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'spec-beta');
        await tester.pump();
        expect(find.text('scenario-traced'), findsOneWidget);
        expect(find.text('scenario-declared'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('preserves zero and missing evidence independently', () {
    final evidence = Evidence.decode(jsonEncode(fixture()));
    expect(evidence.series.first.points.first.value, 0);
    expect(evidence.series.first.points.first.y, 0);
    expect(evidence.series.last.points.first.value, isNull);
    expect(evidence.series.last.points.first.y, isNull);
    expect(evidence.releaseGrade.earned, 0);
    expect(ConvergenceGrade.fromJson({}).earned, isNull);
  });

  test('rejects an unrecognized scale', () {
    final data = fixture();
    (data['graph'] as Map)['scale'] = 'linear';
    expect(() => Evidence.decode(jsonEncode(data)), throwsFormatException);
  });

  testWidgets(
    'chart defaults to convergence and supports scale, metrics and time window controls',
    (tester) async {
      viewport(tester);
      final data = fixture();
      final series = (data['graph'] as Map)['series'] as List;
      series.add(<String, Object>{
        ...Map<String, Object>.from(series[1] as Map),
        'id': 'earned@legacy',
        'epoch': 'legacy',
      });
      await showEvidence(tester, data);
      expect(find.text('Earned obligations'), findsOneWidget);
      expect(chart(tester).series.map((series) => series.id), [
        'earned',
        'denominator',
        'residual',
        'earned@legacy',
      ]);
      expect(chart(tester).logarithmic, isTrue);
      expect(chart(tester).paused, isTrue);
      await reveal(tester, find.text('Log scale'));
      await tester.tap(find.text('Log scale'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(chart(tester).logarithmic, isFalse);
      expect(find.text('Commits'), findsNothing);
      await reveal(tester, find.text('Repository series'));
      await tester.tap(find.text('Repository series'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Commits'));
      await tester.tap(find.text('Commits'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        chart(tester).series.any((series) => series.id == 'commits'),
        isTrue,
      );
      await reveal(tester, find.text('All history'));
      await tester.tap(find.text('All history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 30 days').last);
      await tester.pumpAndSettle();
      expect(find.text('Last 30 days'), findsOneWidget);
      expect(
        find.text(
          'Historical intervals without observations remain unmeasured.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'obligations filter by text and state and expose inspectable full evidence',
    (tester) async {
      viewport(tester);
      await showEvidence(tester, fixture());
      await reveal(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'req-b');
      await tester.pump();
      expect(find.text('scenario-traced'), findsOneWidget);
      expect(find.text('scenario-declared'), findsNothing);
      await reveal(tester, find.text('scenario-traced'));
      await tester.tap(find.text('scenario-traced'));
      await tester.pumpAndSettle();
      expect(find.text('Obligation evidence'), findsOneWidget);
      expect(find.text('linux'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.byKey(const ValueKey('obligation-state-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Positively tested').last);
      await tester.pumpAndSettle();
      expect(find.text('scenario-tested'), findsOneWidget);
      expect(find.text('scenario-traced'), findsNothing);
      await tester.enterText(find.byType(TextField), 'absent');
      await tester.pump();
      expect(find.text('No matching evidence.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
