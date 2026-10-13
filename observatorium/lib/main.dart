// @trace spec:observatorium-dashboard
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'evidence_chart.dart';
import 'model.dart';

void main() => runApp(const ObservatoriumApp());

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
  const EvidenceLoader({super.key});
  @override
  State<EvidenceLoader> createState() => _EvidenceLoaderState();
}

class _EvidenceLoaderState extends State<EvidenceLoader> {
  late Future<Evidence> future;
  Future<Evidence> load() async {
    final bundle = NetworkAssetBundle(Uri.base);
    return Evidence.decode(await bundle.loadString('data/metrics.json'));
  }

  @override
  void initState() {
    super.initState();
    future = load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Evidence>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasData) return Dashboard(evidence: snapshot.data!);
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
                if (!snapshot.hasError)
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
                  SelectableText(snapshot.error.toString()),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => setState(() => future = load()),
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key, required this.evidence});
  final Evidence evidence;
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final enabled = <String>{'commits', 'specs', 'plan', 'residual'};
  bool logarithmic = true;
  bool dots = true;
  int window = 0;
  DateTime? selected;
  String detail = 'Plan';
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
    final specs = current['specs'] as Map;
    final plan = current['plan'] as Map;
    final residual = current['residual'] as Map;
    final commits = current['commits'] as Map;
    final visible = evidence.series
        .where((s) => enabled.contains(s.id))
        .toList();
    return Scaffold(
      body: SelectionArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1400),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
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
                              'TILLANDSIAS / REPOSITORY INTELLIGENCE',
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
                              'A clear view of the work. Evidence, with its limits.',
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
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth > 850
                            ? (constraints.maxWidth - 48) / 4
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
                              '${specs['requirements']} requirements · ${specs['scenarios']} scenarios',
                              'specs',
                            ),
                            metric(
                              width,
                              'PLAN LEDGER',
                              plan['total'],
                              '${(plan['states'] as Map).entries.map((e) => '${e.value} ${e.key}').join(' · ')}',
                              'plan',
                            ),
                            metric(
                              width,
                              'RESIDUAL',
                              residual['value'],
                              residual['reason']?.toString() ??
                                  residual['source'].toString(),
                              'residual',
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
                    const SizedBox(height: 26),
                    Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'The long view',
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
                            Wrap(
                              spacing: 10,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                ...evidence.series.map(
                                  (s) => FilterChip(
                                    label: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 210,
                                      ),
                                      child: Text(
                                        s.label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    tooltip: s.label,
                                    selected: enabled.contains(s.id),
                                    avatar: Icon(
                                      Icons.circle,
                                      size: 10,
                                      color: seriesColor(s.id),
                                    ),
                                    onSelected: (value) => setState(
                                      () => value
                                          ? enabled.add(s.id)
                                          : enabled.remove(s.id),
                                    ),
                                  ),
                                ),
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
                                        '${enabled.join()}-$window-$logarithmic-$dots-$selected',
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
                                  : '${dateLabel(selected!)} · ${visible.map((s) {
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
                                      'What this evidence can tell us',
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
                        ...['Plan', 'Specs', 'Data'].map(
                          (value) => ChoiceChip(
                            label: Text(
                              value == 'Data' ? 'Time series' : value,
                            ),
                            selected: detail == value,
                            onSelected: (_) => setState(() => detail = value),
                          ),
                        ),
                        SizedBox(
                          width: 300,
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
                    evidenceTable(evidence, start, end),
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
                      'Counts describe repository artifacts and activity. They do not establish correctness, progress, or convergence.',
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

  Widget evidenceTable(Evidence evidence, DateTime start, DateTime end) {
    List<String> headings;
    List<List<String>> rows;
    if (detail == 'Data') {
      headings = ['Date', ...evidence.series.map((s) => s.label)];
      rows = evidence.dates
          .where((d) => !d.isBefore(start) && !d.isAfter(end))
          .toList()
          .reversed
          .map(
            (date) => [
              dateLabel(date),
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
      rows = (evidence.details[specs ? 'specs' : 'plan'] as List).map((item) {
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
      }).toList();
    }
    rows = rows
        .where((row) => row.join(' ').toLowerCase().contains(query))
        .toList();
    if (rows.isEmpty)
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('No matching evidence.'),
      );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: 1100,
        child: PaginatedDataTable(
          columns: headings.map((h) => DataColumn(label: Text(h))).toList(),
          source: EvidenceTableSource(rows),
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
  EvidenceTableSource(this.rows);
  final List<List<String>> rows;
  @override
  DataRow? getRow(int index) => index >= rows.length
      ? null
      : DataRow.byIndex(
          index: index,
          cells: rows[index]
              .map(
                (cell) => DataCell(
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Text(
                      cell,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
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
