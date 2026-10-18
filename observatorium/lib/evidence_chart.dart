// @trace spec:observatorium-dashboard
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flame/game.dart';
import 'package:flutter/painting.dart';
import 'model.dart';

const seriesColors = <String, Color>{
  'commits': Color(0xffb8a0ff),
  'specs': Color(0xff80dbbf),
  'plan': Color(0xffffcc85),
  'residual': Color(0xffff8c9f),
  'earned': Color(0xff80dbbf),
  'denominator': Color(0xffb8a0ff),
};
Color seriesColor(String id) {
  id = id.split('@').first;
  if (seriesColors.containsKey(id)) return seriesColors[id]!;
  // Stable across platforms and sessions, unlike String.hashCode.
  final hash = id.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff);
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.65, 0.72).toColor();
}

/// Static evidence rendered by Flame. Only measured points are drawn.
/// A cached picture avoids rerunning chart layout on each engine frame.
class EvidenceChart extends FlameGame {
  EvidenceChart({
    required this.series,
    required this.start,
    required this.end,
    required this.logarithmic,
    required this.showDots,
    required this.selected,
  });
  final List<EvidenceSeries> series;
  final DateTime start;
  final DateTime end;
  final bool logarithmic;
  final bool showDots;
  final DateTime? selected;
  ui.Picture? _picture;
  @override
  Future<void> onLoad() async {
    await super.onLoad();
    pauseEngine(); // No animation or simulation; Flutter repaints on resize.
  }

  @override
  void onGameResize(Vector2 size) {
    _picture?.dispose();
    _picture = null;
    super.onGameResize(size);
  }

  @override
  void onRemove() {
    _picture?.dispose();
    _picture = null;
    super.onRemove();
  }

  @override
  Color backgroundColor() => const Color(0xff171b25);

  double? coordinate(EvidencePoint point) =>
      logarithmic ? point.y : point.value;
  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (_picture == null) {
      final recorder = ui.PictureRecorder();
      renderEvidence(Canvas(recorder));
      _picture = recorder.endRecording();
    }
    canvas.drawPicture(_picture!);
  }

  void renderEvidence(Canvas canvas) {
    final width = size.x;
    final height = size.y;
    if (width < 100 || height < 100) return;
    const left = 54.0;
    const top = 24.0;
    final right = width - 24;
    final bottom = height - 38;
    final visible = series
        .expand((s) => s.points)
        .where((p) => !p.date.isBefore(start) && !p.date.isAfter(end));
    final values = visible.map(coordinate).whereType<double>();
    final maximum = math.max(1.0, values.fold<double>(0, math.max));
    final span = math.max(
      1,
      end.millisecondsSinceEpoch - start.millisecondsSinceEpoch,
    );
    double x(DateTime date) =>
        left +
        (right - left) *
            (date.millisecondsSinceEpoch - start.millisecondsSinceEpoch) /
            span;
    double y(double value) => bottom - (bottom - top) * value / maximum;
    final grid = Paint()
      ..color = const Color(0xff2c3140)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final value = maximum * i / 4;
      canvas.drawLine(Offset(left, y(value)), Offset(right, y(value)), grid);
      label(
        canvas,
        logarithmic ? value.toStringAsFixed(2) : value.toStringAsFixed(0),
        Offset(4, y(value) - 7),
      );
    }
    label(canvas, dateLabel(start), Offset(left, bottom + 14));
    label(
      canvas,
      dateLabel(end),
      Offset(math.max(left, right - 78), bottom + 14),
    );
    for (final item in series) {
      final color = seriesColor(item.id);
      for (final point in item.points) {
        if (point.date.isBefore(start) || point.date.isAfter(end)) continue;
        final value = coordinate(point);
        if (value == null || !value.isFinite) continue;
        final position = Offset(x(point.date), y(value));
        canvas.drawCircle(position, showDots ? 3 : 1.7, Paint()..color = color);
      }
    }
    if (selected != null &&
        !selected!.isBefore(start) &&
        !selected!.isAfter(end)) {
      canvas.drawLine(
        Offset(x(selected!), top),
        Offset(x(selected!), bottom),
        Paint()
          ..color = const Color(0xffe2e5ef)
          ..strokeWidth = 1,
      );
    }
    if (values.isEmpty)
      label(
        canvas,
        'No measured observations in this window',
        Offset(left + 14, top + 35),
      );
  }

  void label(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Color(0xff9ca6ba), fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }
}

String dateLabel(DateTime date) => date.toIso8601String().substring(0, 10);
