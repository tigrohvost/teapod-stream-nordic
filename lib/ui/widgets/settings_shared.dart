import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class SetSectionHeader extends StatelessWidget {
  final TeapodTokens t;
  final String addr;
  final String label;
  const SetSectionHeader({
    super.key,
    required this.t,
    required this.addr,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.lineSoft)),
      ),
      child: Row(
        children: [
          Text(
            addr,
            style: AppTheme.mono(
              size: 10,
              color: t.textMuted,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(width: 8),
          Text('·', style: AppTheme.mono(size: 10, color: t.textMuted)),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: AppTheme.mono(size: 10, color: t.textDim, letterSpacing: 1),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '—' * 16,
              style: AppTheme.mono(size: 10, color: t.textMuted),
              overflow: TextOverflow.clip,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class SetCornerTicks extends StatelessWidget {
  final TeapodTokens t;
  final Color color;
  const SetCornerTicks({super.key, required this.t, required this.color});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned(
              top: 6,
              left: 6,
              child: _SmallTick(color: color, tl: true),
            ),
            Positioned(
              top: 6,
              right: 6,
              child: _SmallTick(color: color, tr: true),
            ),
            Positioned(
              bottom: 6,
              left: 6,
              child: _SmallTick(color: color, bl: true),
            ),
            Positioned(
              bottom: 6,
              right: 6,
              child: _SmallTick(color: color, br: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _SmallTick extends StatelessWidget {
  final Color color;
  final bool tl, tr, bl, br;
  const _SmallTick({
    required this.color,
    this.tl = false,
    this.tr = false,
    this.bl = false,
    this.br = false,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(8, 8),
    painter: _SmallTickPainter(color: color, tl: tl, tr: tr, bl: bl, br: br),
  );
}

class _SmallTickPainter extends CustomPainter {
  final Color color;
  final bool tl, tr, bl, br;
  const _SmallTickPainter({
    required this.color,
    required this.tl,
    required this.tr,
    required this.bl,
    required this.br,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final w = size.width;
    final h = size.height;
    if (tl) {
      canvas.drawLine(Offset.zero, Offset(w, 0), p);
      canvas.drawLine(Offset.zero, Offset(0, h), p);
    }
    if (tr) {
      canvas.drawLine(Offset(0, 0), Offset(w, 0), p);
      canvas.drawLine(Offset(w, 0), Offset(w, h), p);
    }
    if (bl) {
      canvas.drawLine(Offset(0, h), Offset(w, h), p);
      canvas.drawLine(Offset(0, 0), Offset(0, h), p);
    }
    if (br) {
      canvas.drawLine(Offset(0, h), Offset(w, h), p);
      canvas.drawLine(Offset(w, 0), Offset(w, h), p);
    }
  }

  @override
  bool shouldRepaint(_SmallTickPainter old) => old.color != color;
}
