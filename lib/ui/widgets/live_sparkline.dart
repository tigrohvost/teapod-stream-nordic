import 'package:flutter/material.dart';

class LiveSparkline extends StatelessWidget {
  final List<double> samples;
  final Color color;
  final double strokeWidth;

  const LiveSparkline({
    super.key,
    required this.samples,
    required this.color,
    this.strokeWidth = 1.5,
  });

  /// Chart vertices for [samples] in [size]: non-finite or negative samples
  /// sit on the baseline, one sample is a centred dot, none is nothing.
  @visibleForTesting
  static List<Offset> pointsFor(List<double> samples, Size size) {
    if (samples.isEmpty ||
        size.isEmpty ||
        !size.width.isFinite ||
        !size.height.isFinite) {
      return const [];
    }
    final clean = samples.map((v) => v.isFinite && v > 0 ? v : 0.0).toList();
    if (clean.length == 1) return [Offset(size.width / 2, size.height / 2)];
    final max = clean.fold<double>(0.5, (m, v) => v > m ? v : m);
    final w = size.width;
    final h = size.height;
    final n = clean.length;
    return [
      for (var i = 0; i < n; i++)
        Offset((i / (n - 1)) * w, h - (clean[i] / max) * (h - 4) - 2),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: CustomPaint(
        painter: _SparklinePainter(
          samples: samples,
          color: color,
          strokeWidth: strokeWidth,
        ),
        size: const Size(double.infinity, 42),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> samples;
  final Color color;
  final double strokeWidth;

  const _SparklinePainter({
    required this.samples,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final points = LiveSparkline.pointsFor(samples, size);
    if (points.isEmpty) return;
    if (points.length == 1) {
      canvas.drawCircle(points.single, strokeWidth, Paint()..color = color);
      return;
    }
    final w = size.width;
    final h = size.height;

    // Build path
    final linePath = Path();
    linePath.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }

    // Fill gradient
    final fillPath = Path.from(linePath)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [color.withAlpha(0x59), color.withAlpha(0x00)],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // Stroke
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(linePath, strokePaint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.samples != samples || old.color != color;
}
