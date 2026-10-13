// @trace spec:observatorium-dashboard
import 'dart:convert';

class EvidencePoint {
  EvidencePoint(this.date, this.value, this.y);
  final DateTime date;
  final double? value;
  // The collector precomputes log10(1+x). Never derive historical values here.
  final double? y;
  factory EvidencePoint.fromJson(Map<String, dynamic> json) => EvidencePoint(
    DateTime.parse(json['date'] as String),
    (json['value'] as num?)?.toDouble(),
    (json['y'] as num?)?.toDouble(),
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
  List<String> get gaps =>
      (raw['gaps'] as List).map((e) => e.toString()).toList();
  String get revision => raw['revision'].toString();
  String get generatedAt => raw['generatedAt'].toString();
  String get epoch => (raw['epoch'] as Map)['description'].toString();
  List<DateTime> get dates =>
      series.expand((s) => s.points.map((p) => p.date)).toSet().toList()
        ..sort();
}

String countLabel(dynamic value) =>
    value == null ? 'Unmeasured' : value.toString();
