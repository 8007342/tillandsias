// @trace spec:observatorium-dashboard
import 'dart:convert';

class EvidencePoint {
  EvidencePoint(
    this.date,
    this.value,
    this.y, {
    this.release,
    this.scopeChange,
  });
  final DateTime date;
  final double? value;
  // The collector precomputes log10(1+x). Never derive historical values here.
  final double? y;
  final String? release;
  final String? scopeChange;
  factory EvidencePoint.fromJson(Map<String, dynamic> json) => EvidencePoint(
    DateTime.parse(json['date'] as String),
    (json['value'] as num?)?.toDouble(),
    (json['y'] as num?)?.toDouble(),
    release: json['release']?.toString(),
    scopeChange: json['scopeChange']?.toString(),
  );
}

class EvidenceSeries {
  EvidenceSeries(
    this.id,
    this.label,
    this.points, {
    this.definition = '',
    this.epoch = '',
    this.unit = '',
    this.source = '',
  });
  final String id;
  final String label;
  final List<EvidencePoint> points;
  final String definition;
  final String epoch;
  final String unit;
  final String source;
  factory EvidenceSeries.fromJson(Map<String, dynamic> json) => EvidenceSeries(
    json['id'] as String,
    json['label'] as String,
    (json['points'] as List)
        .map((e) => EvidencePoint.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    definition: json['definition']?.toString() ?? '',
    epoch: json['epoch']?.toString() ?? '',
    unit: json['unit']?.toString() ?? '',
    source: json['source']?.toString() ?? '',
  );
}

class Evidence {
  Evidence(this.raw, this.series);
  final Map<String, dynamic> raw;
  final List<EvidenceSeries> series;
  factory Evidence.decode(String source) {
    final raw = jsonDecode(source) as Map<String, dynamic>;
    if (raw['schemaVersion'] != 1) {
      throw const FormatException('Unsupported evidence schema');
    }
    final graph = raw['graph'] as Map<String, dynamic>;
    if (graph['scale'] != 'log10(1+x)') {
      throw const FormatException(
        'Expected precomputed log10(1+x) coordinates',
      );
    }
    return Evidence(
      raw,
      (graph['series'] as List)
          .map(
            (e) => EvidenceSeries.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
    );
  }
  Map<String, dynamic> get current =>
      Map<String, dynamic>.from(raw['current'] as Map);
  Map<String, dynamic> get details =>
      Map<String, dynamic>.from(raw['details'] as Map);
  ConvergenceGrade get releaseGrade =>
      ConvergenceGrade.fromJson(current['residual'] as Map? ?? const {});
  ConvergenceGrade? get liveGrade => current['residualLive'] is Map
      ? ConvergenceGrade.fromJson(current['residualLive'] as Map)
      : null;
  List<ObligationEvidence>? get obligations => details['obligations'] is List
      ? (details['obligations'] as List)
            .map((row) => ObligationEvidence.fromJson(row as Map))
            .toList()
      : null;
  List<String> get gaps =>
      (raw['gaps'] as List).map((e) => e.toString()).toList();
  List<Map> get scopeChanges =>
      (raw['scopeChanges'] as List? ?? const []).cast<Map>();
  String get revision => raw['revision'].toString();
  String get generatedAt => raw['generatedAt'].toString();
  String get epoch => (raw['epoch'] as Map)['description'].toString();
  List<DateTime> get dates =>
      series.expand((s) => s.points.map((p) => p.date)).toSet().toList()
        ..sort();
}

/// Counts belong to one observation. Missing values never become zeroes.
class ConvergenceGrade {
  ConvergenceGrade.fromJson(Map json) : raw = Map<String, dynamic>.from(json);
  final Map<String, dynamic> raw;
  num? count(String key) => raw[key] is num ? raw[key] as num : null;
  num? get earned => count('satisfied');
  num? get denominator => count('denominator');
  num? get residual => count('value');
  String? text(String key) => raw[key]?.toString();
  num? stateCount(String state) {
    final histogram = raw['histogram'] as Map?;
    final value =
        histogram?[state] ??
        raw[switch (state) {
          'positively_tested' => 'positivelyTested',
          _ => state,
        }];
    return value is num ? value : null;
  }

  Map get provenance => raw['provenance'] as Map? ?? const {};
  List<String> get limitations =>
      (provenance['limitations'] as List? ?? const [])
          .map((value) => value.toString())
          .toList();
}

class ObligationEvidence {
  ObligationEvidence.fromJson(Map json) : raw = Map<String, dynamic>.from(json);
  final Map<String, dynamic> raw;
  String text(String key) => raw[key]?.toString() ?? 'Unavailable';
  String get id => text('id');
  String get state => text('state');
  String get searchable => raw.values.join(' ').toLowerCase();
}

String evidenceStateLabel(String state) => switch (state) {
  'declared' => 'Declared',
  'traced' => 'Traced',
  'positively_tested' => 'Positively tested',
  _ => state,
};

String countLabel(dynamic value) {
  if (value == null) return 'Unmeasured';
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}
