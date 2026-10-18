// @trace spec:observatorium-dashboard
// Source: schema-v1 collector snapshot; refresh cadence follows metrics TTL (60s).
import 'dart:async';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'evidence_chart.dart';
import 'convergence.dart';
import 'model.dart';

void main() => runApp(const ObservatoriumApp());

Future<Evidence> fetchEvidence({http.Client? client, Uri? base}) async {
  final transport = client ?? http.Client();
  try {
    final response = await transport
        .get(
          (base ?? Uri.base).resolve('data/metrics.json'),
          headers: const {'Cache-Control': 'no-cache'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError(
        'Evidence request failed (HTTP ${response.statusCode}).',
      );
    }
    return Evidence.decode(response.body);
  } finally {
    if (client == null) transport.close();
  }
}

class ObservatoriumApp extends StatelessWidget {
  const ObservatoriumApp({super.key, this.evidence});
  final Evidence? evidence;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tillandsias · Observatorium',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff10131a),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffb8a0ff),
        brightness: Brightness.dark,
      ),
      cardTheme: const CardThemeData(color: Color(0xff171b25), elevation: 0),
    ),
    home: evidence == null
        ? const EvidenceLoader()
        : Dashboard(evidence: evidence!),
  );
}

class EvidenceLoader extends StatefulWidget {
  const EvidenceLoader({super.key, this.loadEvidence});
  final Future<Evidence> Function()? loadEvidence;
  @override
  State<EvidenceLoader> createState() => _EvidenceLoaderState();
}

class _EvidenceLoaderState extends State<EvidenceLoader> {
  Evidence? evidence;
  Object? error;
  Timer? timer;
  bool refreshing = false;

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      final latest = await (widget.loadEvidence?.call() ?? fetchEvidence());
      if (!mounted) return;
      if (evidence?.revision != latest.revision ||
          evidence?.generatedAt != latest.generatedAt ||
          error != null) {
        setState(() {
          evidence = latest;
          error = null;
        });
      }
    } catch (failure) {
      if (mounted) setState(() => error = failure);
    } finally {
      refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (evidence != null)
      return Dashboard(
        evidence: evidence!,
        onRefresh: refresh,
        refreshError: error == null
            ? null
            : 'Latest refresh unavailable; showing the last loaded snapshot.',
      );
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'OBSERVATORIUM',
                style: TextStyle(letterSpacing: 4, fontSize: 20),
              ),
              const SizedBox(height: 24),
              if (error == null)
                const CircularProgressIndicator()
              else ...[
                const Text(
                  'Evidence could not be loaded.',
                  style: TextStyle(fontSize: 22),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The published dashboard needs data/metrics.json from the repository collector.',
                ),
                const SizedBox(height: 12),
                SelectableText(error.toString()),
                const SizedBox(height: 16),
                FilledButton(onPressed: refresh, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({
    super.key,
    required this.evidence,
    this.onRefresh,
    this.refreshError,
  });
  final Evidence evidence;
  final VoidCallback? onRefresh;
  final String? refreshError;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final enabled = <String>{'earned', 'denominator', 'residual'};
  bool logarithmic = true;
  bool dots = true;
  int window = 0;
  DateTime? selected;
  String detail = 'Obligations';
  String obligationState = 'all';
  String query = '';
  @override
  Widget build(BuildContext context) {
    final evidence = widget.evidence;
    final dates = evidence.dates;
    final end = dates.isEmpty ? DateTime.utc(1970) : dates.last;
    final first = dates.isEmpty ? end : dates.first;
    final requested = window == 0
        ? first
        : end.subtract(Duration(days: window));
    final start = requested.isBefore(first) ? first : requested;
    final current = evidence.current;
    final specs = current['specs'] as Map? ?? const {};
    final plan = current['plan'] as Map? ?? const {};
    final commits = current['commits'] as Map? ?? const {};
    final visible = evidence.series
        .where((s) => enabled.contains(s.id.split('@').first))
        .toList();
    return Scaffold(
      body: SelectionArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1400),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: MediaQuery.sizeOf(context).width < 600 ? 16 : 28,
                  vertical: 30,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 36,
                      runSpacing: 16,
                      children: [
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'TILLANDSIAS / EVIDENCE',
                              style: TextStyle(
                                color: Color(0xffb8a0ff),
                                fontSize: 11,
                                letterSpacing: 2,
                              ),
                            ),
                            SizedBox(height: 10),
                            Text(
                              'Observatorium',
                              style: TextStyle(
                                fontSize: 38,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -1,
                              ),
                            ),
                            SizedBox(height: 6),
                            Text(
                              'Implementation obligations, measured against evidence.',
                              style: TextStyle(color: Color(0xffa4aec1)),
                            ),
                          ],
                        ),
                        Chip(
                          avatar: const Icon(
                            Icons.visibility_outlined,
                            size: 18,
                          ),
                          label: Text(
                            'READ ONLY · ${evidence.revision.substring(0, evidence.revision.length < 8 ? evidence.revision.length : 8)}',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    if (widget.onRefresh != null) ...[
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: widget.onRefresh,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Refresh evidence'),
                          ),
                          const Text(
                            'Checks for published snapshots every 60 seconds.',
                            style: TextStyle(
                              color: Color(0xff9ca6ba),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      if (widget.refreshError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 12),
                          child: Text(
                            widget.refreshError!,
                            style: const TextStyle(color: Color(0xffffcc85)),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                    ConvergencePanel(grade: evidence.releaseGrade),
                    const SizedBox(height: 16),
                    LiveEvidencePanel(grade: evidence.liveGrade),
                    const SizedBox(height: 26),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Convergence over releases',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              logarithmic
                                  ? 'Y: log10(1 + count). Zero is shown at zero; equal spacing represents multiplicative growth.'
                                  : 'Y: raw count. All series share a zero baseline.',
                              style: const TextStyle(color: Color(0xffa4aec1)),
                            ),
                            const SizedBox(height: 18),
                            if (evidence.scopeChanges.isNotEmpty) ...[
                              const Text(
                                'Obligation scope changed',
                                style: TextStyle(color: Color(0xffffcc85)),
                              ),
                              ...evidence.scopeChanges.map(
                                (change) => Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    '${change['release'] ?? change['date']}: ${change['before']} → ${change['after']} obligations. ${change['label'] ?? ''}',
                                    style: const TextStyle(
                                      color: Color(0xffa4aec1),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                ...seriesControls(evidence, convergence: true),
                                DropdownButton<int>(
                                  value: window,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 0,
                                      child: Text('All history'),
                                    ),
                                    DropdownMenuItem(
                                      value: 30,
                                      child: Text('Last 30 days'),
                                    ),
                                    DropdownMenuItem(
                                      value: 90,
                                      child: Text('Last 90 days'),
                                    ),
                                    DropdownMenuItem(
                                      value: 365,
                                      child: Text('Last year'),
                                    ),
                                  ],
                                  onChanged: (value) => setState(() {
                                    window = value!;
                                    selected = null;
                                  }),
                                ),
                                FilterChip(
                                  label: const Text('Log scale'),
                                  selected: logarithmic,
                                  onSelected: (value) =>
                                      setState(() => logarithmic = value),
                                ),
                                FilterChip(
                                  label: const Text('Larger points'),
                                  selected: dots,
                                  onSelected: (value) =>
                                      setState(() => dots = value),
                                ),
                              ],
                            ),
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text('Repository series'),
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      children: seriesControls(
                                        evidence,
                                        convergence: false,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              height: 330,
                              child: LayoutBuilder(
                                builder: (context, constraints) => GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (event) {
                                    final fraction =
                                        ((event.localPosition.dx - 54) /
                                                (constraints.maxWidth - 78))
                                            .clamp(0.0, 1.0);
                                    final target = start.add(
                                      Duration(
                                        milliseconds:
                                            ((end.millisecondsSinceEpoch -
                                                        start
                                                            .millisecondsSinceEpoch) *
                                                    fraction)
                                                .round(),
                                      ),
                                    );
                                    final candidates = dates
                                        .where(
                                          (d) =>
                                              !d.isBefore(start) &&
                                              !d.isAfter(end),
                                        )
                                        .toList();
                                    if (candidates.isNotEmpty)
                                      setState(
                                        () => selected = candidates.reduce(
                                          (a, b) =>
                                              (a.difference(target).abs() <
                                                  b.difference(target).abs())
                                              ? a
                                              : b,
                                        ),
                                      );
                                  },
                                  child: Semantics(
                                    label:
                                        'Time series chart. ${logarithmic ? 'Logarithmic' : 'Linear'} count axis. Exact observations are available in the data table below.',
                                    child: GameWidget(
                                      key: ValueKey(
                                        '${evidence.revision}-${evidence.generatedAt}-${enabled.join()}-$window-$logarithmic-$dots-$selected',
                                      ),
                                      game: EvidenceChart(
                                        series: visible,
                                        start: start,
                                        end: end,
                                        logarithmic: logarithmic,
                                        showDots: dots,
                                        selected: selected,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              selected == null
                                  ? 'Click the chart to inspect a dated observation. Missing measurements remain gaps.'
                                  : '${selected!.toIso8601String()} · ${visible.map((s) {
                                      final points = s.points.where((p) => p.date == selected);
                                      return '${s.label}: ${points.isEmpty ? 'unmeasured' : countLabel(points.first.value)}';
                                    }).join(' · ')}',
                              style: const TextStyle(color: Color(0xffc2c9d8)),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'Epoch: ${evidence.epoch} Observations are not connected across unmeasured intervals.',
                              style: const TextStyle(
                                color: Color(0xff9ca6ba),
                                fontSize: 12,
                              ),
                            ),
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text(
                                'Series definitions and sources',
                              ),
                              subtitle: const Text(
                                'Each series retains its own unit and measurement epoch.',
                              ),
                              children: visible
                                  .map(
                                    (s) => ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      leading: Icon(
                                        Icons.circle,
                                        size: 12,
                                        color: seriesColor(s.id),
                                      ),
                                      title: Text(s.label),
                                      subtitle: Text(
                                        '${s.definition}\nUnit: ${s.unit.isEmpty ? 'count' : s.unit} · Epoch: ${s.epoch}\nSource: ${s.source}',
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (evidence.gaps.isNotEmpty)
                      Card(
                        margin: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: Color(0xffffcc85),
                                    size: 19,
                                  ),
                                  SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'Measurement gaps and limits',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              ...evidence.gaps.map(
                                (gap) => Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Text(
                                    gap,
                                    style: const TextStyle(
                                      color: Color(0xffb8c1d1),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    const Text(
                      'Inspect the evidence',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ...[
                          'Obligations',
                          'Plan',
                          'Specs',
                          'Gate targets',
                          'Data',
                        ].map(
                          (value) => ChoiceChip(
                            label: Text(
                              value == 'Data' ? 'Time series' : value,
                            ),
                            selected: detail == value,
                            onSelected: (_) => setState(() => detail = value),
                          ),
                        ),
                        if (detail == 'Obligations')
                          SizedBox(
                            width: 250,
                            child: DropdownButton<String>(
                              isExpanded: true,
                              key: const ValueKey('obligation-state-filter'),
                              value: obligationState,
                              items:
                                  [
                                        'all',
                                        'declared',
                                        'traced',
                                        'positively_tested',
                                      ]
                                      .map(
                                        (state) => DropdownMenuItem(
                                          value: state,
                                          child: Text(
                                            state == 'all'
                                                ? 'All evidence states'
                                                : evidenceStateLabel(state),
                                          ),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (state) =>
                                  setState(() => obligationState = state!),
                            ),
                          ),
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 400
                              ? 250
                              : 300,
                          child: TextField(
                            decoration: const InputDecoration(
                              isDense: true,
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Filter evidence',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) =>
                                setState(() => query = value.toLowerCase()),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (detail == 'Obligations') ...[
                      const Text(
                        'Current working-tree obligations · display-only. Select a row to inspect its full evidence.',
                        style: TextStyle(
                          color: Color(0xffa4aec1),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    evidenceTable(evidence, start, end),
                    const SizedBox(height: 28),
                    const Text(
                      'Repository context',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth > 850
                            ? (constraints.maxWidth - 32) / 3
                            : (constraints.maxWidth > 480
                                  ? (constraints.maxWidth - 16) / 2
                                  : constraints.maxWidth);
                        return Wrap(
                          spacing: 16,
                          runSpacing: 16,
                          children: [
                            metric(
                              width,
                              'SPECIFICATIONS',
                              specs['files'],
                              '${countLabel(specs['requirements'])} requirements · ${countLabel(specs['scenarios'])} scenarios',
                              'specs',
                            ),
                            metric(
                              width,
                              'PLAN LEDGER',
                              plan['total'],
                              '${(plan['states'] as Map? ?? const {}).entries.map((e) => '${e.value} ${e.key}').join(' · ')}',
                              'plan',
                            ),
                            metric(
                              width,
                              'COMMITS',
                              commits['total'],
                              'Reachable history · evidence of activity',
                              'commits',
                            ),
                          ],
                        );
                      },
                    ),
                    if (current['luaMigration'] is Map) ...[
                      const SizedBox(height: 12),
                      luaInventory(current['luaMigration'] as Map),
                    ],
                    const SizedBox(height: 24),
                    Text(
                      'Snapshot generated ${evidence.generatedAt} · Source revision ${evidence.revision}',
                      style: const TextStyle(
                        color: Color(0xff9ca6ba),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Repository counts describe artifacts and activity. The CentiColon grade reports only evidence earned within its stated obligations.',
                      style: TextStyle(color: Color(0xff9ca6ba), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> seriesControls(Evidence evidence, {required bool convergence}) {
    const convergenceLabels = {
      'earned': 'Earned obligations',
      'denominator': 'Obligation denominator',
      'residual': 'Residual obligations',
    };
    final distinct = <String, EvidenceSeries>{};
    for (final series in evidence.series) {
      final base = series.id.split('@').first;
      if (convergenceLabels.containsKey(base) == convergence) {
        distinct.putIfAbsent(base, () => series);
      }
    }
    return distinct.entries.map((entry) {
      final label = convergenceLabels[entry.key] ?? entry.value.label;
      return FilterChip(
        label: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width < 400 ? 130 : 210,
          ),
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
        tooltip: label,
        selected: enabled.contains(entry.key),
        avatar: Icon(Icons.circle, size: 10, color: seriesColor(entry.key)),
        onSelected: (value) => setState(
          () => value ? enabled.add(entry.key) : enabled.remove(entry.key),
        ),
      );
    }).toList();
  }

  Widget metric(
    double width,
    String title,
    dynamic value,
    String subtitle,
    String id,
  ) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.6,
                color: seriesColors[id],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              countLabel(value),
              style: TextStyle(
                fontSize: value == null ? 25 : 34,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(color: Color(0xffa4aec1), fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  Widget luaInventory(Map inventory) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gate implementation inventory',
            style: TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            '${countLabel(inventory['lua'])} Lua targets · ${countLabel(inventory['shell'])} shell targets',
          ),
          const SizedBox(height: 8),
          Text(
            inventory['definition']?.toString() ?? 'Definition unavailable',
            style: const TextStyle(color: Color(0xffa4aec1), fontSize: 12),
          ),
          if (inventory['reason'] != null &&
              inventory['reason'] != inventory['definition'])
            Text(inventory['reason'].toString()),
          const SizedBox(height: 8),
          Text(
            'Source: ${inventory['source'] ?? 'Unavailable'} · Epoch: ${inventory['epoch'] ?? 'Unavailable'}',
            style: const TextStyle(color: Color(0xffa4aec1), fontSize: 12),
          ),
        ],
      ),
    ),
  );

  void inspectObligation(ObligationEvidence obligation) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Obligation evidence'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: SelectionArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current working tree · display-only',
                  style: TextStyle(color: Color(0xffffcc85)),
                ),
                const SizedBox(height: 16),
                for (final entry in obligation.raw.entries) ...[
                  Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(entry.value?.toString() ?? 'Unavailable'),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Widget evidenceTable(Evidence evidence, DateTime start, DateTime end) {
    List<String> headings;
    List<List<String>> rows;
    List<ObligationEvidence>? obligations;
    if (detail == 'Obligations') {
      final all = evidence.obligations;
      if (all == null) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Obligation evidence is unavailable. No per-obligation rows were published.',
          ),
        );
      }
      obligations = all
          .where(
            (row) =>
                (obligationState == 'all' || row.state == obligationState) &&
                row.searchable.contains(query),
          )
          .toList();
      headings = [
        'Obligation / scenario',
        'Requirement ID',
        'Specification',
        'State',
        'Reason',
      ];
      rows = obligations
          .map(
            (row) => [
              row.id,
              row.text('req_id'),
              row.text('spec'),
              evidenceStateLabel(row.state),
              row.text('reason'),
            ],
          )
          .toList();
    } else if (detail == 'Gate targets') {
      headings = ['Implementation target', 'Language', 'Gate manifests'];
      final inventory = evidence.details['luaMigration'] as List?;
      if (inventory == null) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Gate target inventory is unavailable.'),
        );
      }
      rows = inventory.map((item) {
        final row = item as Map;
        return [
          row['path'].toString(),
          row['language'].toString(),
          (row['manifests'] as List? ?? const []).join(', '),
        ];
      }).toList();
    } else if (detail == 'Data') {
      headings = ['Date', ...evidence.series.map((s) => s.label)];
      rows = evidence.dates
          .where((d) => !d.isBefore(start) && !d.isAfter(end))
          .toList()
          .reversed
          .map(
            (date) => [
              date.toIso8601String(),
              ...evidence.series.map((s) {
                final points = s.points.where((p) => p.date == date);
                return points.isEmpty
                    ? 'Unmeasured'
                    : countLabel(points.first.value);
              }),
            ],
          )
          .toList();
    } else {
      final specs = detail == 'Specs';
      headings = specs
          ? ['Specification', 'Requirements', 'Scenarios']
          : ['Order', 'Title', 'Status'];
      rows = (evidence.details[specs ? 'specs' : 'plan'] as List? ?? const [])
          .map((item) {
            final m = item as Map;
            return specs
                ? [
                    m['path'].toString(),
                    countLabel(m['requirements']),
                    countLabel(m['scenarios']),
                  ]
                : [
                    m['id'].toString(),
                    m['title'].toString(),
                    m['status'].toString(),
                  ];
          })
          .toList();
    }
    if (obligations == null) {
      rows = rows
          .where((row) => row.join(' ').toLowerCase().contains(query))
          .toList();
    }
    if (rows.isEmpty)
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No matching evidence.'),
      );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: detail == 'Obligations' ? 1400 : 1100,
        child: PaginatedDataTable(
          columns: headings.map((h) => DataColumn(label: Text(h))).toList(),
          source: EvidenceTableSource(
            rows,
            onInspect: obligations == null
                ? null
                : (index) => inspectObligation(obligations![index]),
          ),
          rowsPerPage: rows.length < 10 ? rows.length : 10,
          availableRowsPerPage: const [10],
          showCheckboxColumn: false,
          showFirstLastButtons: true,
        ),
      ),
    );
  }
}

class EvidenceTableSource extends DataTableSource {
  EvidenceTableSource(this.rows, {this.onInspect});
  final List<List<String>> rows;
  final void Function(int)? onInspect;
  @override
  DataRow? getRow(int index) => index >= rows.length
      ? null
      : DataRow.byIndex(
          index: index,
          onSelectChanged: onInspect == null ? null : (_) => onInspect!(index),
          cells: rows[index]
              .map(
                (cell) => DataCell(
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Tooltip(
                      message: cell,
                      child: Text(
                        cell,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        );
  @override
  bool get isRowCountApproximate => false;
  @override
  int get rowCount => rows.length;
  @override
  int get selectedRowCount => 0;
}
