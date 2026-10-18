// @trace spec:observatorium-dashboard
import 'package:flutter/material.dart';
import 'model.dart';

const _muted = Color(0xffa4aec1);
const _accent = Color(0xffb8a0ff);

class ConvergencePanel extends StatelessWidget {
  const ConvergencePanel({super.key, required this.grade});
  final ConvergenceGrade grade;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CENTICOLON CONVERGENCE',
            style: TextStyle(color: _accent, letterSpacing: 1.5, fontSize: 11),
          ),
          const SizedBox(height: 10),
          const Text(
            'How much has earned its evidence?',
            style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Each named scenario obligation is a verifiable implementation element. '
            'Earned obligations have matching positive test evidence; residual obligations still need that evidence.',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              Chip(
                avatar: const Icon(Icons.bookmark_outline, size: 17),
                label: Text(grade.text('release') ?? 'No measured release'),
              ),
              const Chip(label: Text('Release-cut evidence')),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth < 500
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 24) / 3;
              return Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  _GradeCount(
                    width: width,
                    label: 'Earned',
                    value: grade.earned,
                    color: const Color(0xff80dbbf),
                  ),
                  _GradeCount(
                    width: width,
                    label: 'Denominator',
                    value: grade.denominator,
                    color: _accent,
                  ),
                  _GradeCount(
                    width: width,
                    label: 'Residual',
                    value: grade.residual,
                    color: const Color(0xffff8c9f),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const Text(
            'Residual = denominator − earned',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 8),
          ResidualReasons(grade: grade),
          if (grade.text('reason') != null) ...[
            const SizedBox(height: 8),
            Text(grade.text('reason')!, style: const TextStyle(color: _muted)),
          ],
          const Divider(height: 32),
          const Text(
            'Evidence ladder',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Highest supported state per obligation',
            style: TextStyle(color: _muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final state in ['declared', 'traced', 'positively_tested'])
                Chip(
                  label: Text(
                    '${evidenceStateLabel(state)} · ${countLabel(grade.stateCount(state))}',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Declared: a scenario exists. Traced: a reachable test is bound to its requirement. '
            'Positively tested: matching positive evidence is recorded. '
            'Higher evidence states are unavailable. Tracing alone earns no satisfaction.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          GradeSource(grade: grade),
          if (grade.count('records') != null) ...[
            const SizedBox(height: 8),
            Text(
              '${countLabel(grade.count('records'))} global run-log records. '
              'This count does not establish matched evidence for these obligations.',
              style: const TextStyle(color: Color(0xffffcc85), fontSize: 12),
            ),
          ],
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Evidence provenance and limits'),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final key in [
                        'gradeSchema',
                        'gradeSha256',
                        'obligationsSha256',
                        'staticSha256',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '$key: ${grade.provenance[key] ?? 'Unavailable'}',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ),
                      for (final entry in {
                        'population': 'Population',
                        'excluded': 'Excluded obligations',
                        'invariantsExcluded': 'Excluded invariants',
                        'populationGaps': 'Population gaps',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${entry.value}: ${provenanceValue(grade.provenance[entry.key])}',
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                        ),
                      if (grade.text('recordScope') != null)
                        Text(
                          'Record scope: ${grade.text('recordScope')}',
                          style: const TextStyle(color: _muted, fontSize: 12),
                        ),
                      ...grade.limitations.map(
                        (limit) => Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            limit,
                            style: const TextStyle(
                              color: Color(0xffffcc85),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'A grade describes recorded evidence within this denominator. It does not establish project-wide correctness.',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

String provenanceValue(Object? value) {
  if (value == null) return 'Unavailable';
  if (value is Map) {
    return value.isEmpty
        ? 'None recorded'
        : value.entries
              .map((entry) => '${entry.key}: ${provenanceValue(entry.value)}')
              .join('; ');
  }
  if (value is List) {
    return value.isEmpty
        ? 'None recorded'
        : value.map(provenanceValue).join('; ');
  }
  return value.toString();
}

class ResidualReasons extends StatelessWidget {
  const ResidualReasons({super.key, required this.grade});
  final ConvergenceGrade grade;
  @override
  Widget build(BuildContext context) {
    final reasons = grade.raw['reasons'] as Map?;
    return Text(
      reasons == null
          ? 'Residual reasons: unavailable'
          : reasons.isEmpty
          ? 'Residual reasons: none reported'
          : 'Residual reasons: ${reasons.entries.map((entry) => '${entry.key} · ${countLabel(entry.value)}').join(' / ')}',
      style: const TextStyle(color: Color(0xffffcc85), fontSize: 12),
    );
  }
}

class _GradeCount extends StatelessWidget {
  const _GradeCount({
    required this.width,
    required this.label,
    required this.value,
    required this.color,
  });
  final double width;
  final String label;
  final num? value;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    decoration: BoxDecoration(
      color: const Color(0xff10131a),
      borderRadius: BorderRadius.circular(12),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 2,
        children: [
          Text(
            countLabel(value),
            style: TextStyle(
              fontSize: value == null ? 22 : 34,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(label, style: const TextStyle(color: _muted)),
        ],
      ),
    ),
  );
}

class GradeSource extends StatelessWidget {
  const GradeSource({super.key, required this.grade});
  final ConvergenceGrade grade;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Observed: ${grade.text('measuredAt') ?? 'Unavailable'}',
        style: const TextStyle(color: _muted, fontSize: 12),
      ),
      const SizedBox(height: 4),
      Text(
        'Source: ${grade.text('source') ?? 'Unavailable'}',
        style: const TextStyle(color: _muted, fontSize: 12),
      ),
      const SizedBox(height: 4),
      Text(
        'Revision: ${grade.text('revision') ?? 'Unavailable'}${grade.raw['dirty'] == true ? ' · working-tree changes' : ''}',
        style: const TextStyle(color: _muted, fontSize: 12),
      ),
    ],
  );
}

class LiveEvidencePanel extends StatelessWidget {
  const LiveEvidencePanel({super.key, required this.grade});
  final ConvergenceGrade? grade;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'LIVE WORKING TREE · DISPLAY-ONLY',
            style: TextStyle(
              color: Color(0xffffcc85),
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          if (grade == null)
            const Text('Live obligation evidence is unavailable.')
          else ...[
            Text(
              '${countLabel(grade!.earned)} earned / ${countLabel(grade!.denominator)} obligations · '
              '${countLabel(grade!.residual)} residual',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            Text(
              '${countLabel(grade!.stateCount('traced'))} traced · '
              '${countLabel(grade!.stateCount('positively_tested'))} positively tested',
              style: const TextStyle(color: _muted),
            ),
            const SizedBox(height: 10),
            GradeSource(grade: grade!),
            const SizedBox(height: 8),
            ResidualReasons(grade: grade!),
            if (grade!.text('reason') != null) ...[
              const SizedBox(height: 8),
              Text(
                grade!.text('reason')!,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ],
          const SizedBox(height: 10),
          const Text(
            'The obligation rows below describe this current observation. '
            'This observation is separate from the release series.',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}
