import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The four-colour Google "G" drawn as vector arcs, for the "Google ile Giriş
/// Yap" button (replaces the generic `Icons.g_mobiledata` stand-in).
///
/// Purely decorative: the button's own label names the action, so the mark is
/// excluded from the semantics tree.
class GoogleMark extends StatelessWidget {
  final double size;

  const GoogleMark({super.key, this.size = 18});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _GoogleMarkPainter()),
      ),
    );
  }
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    Paint arc(Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    double deg(double d) => d * math.pi / 180;

    // Angles measured clockwise from 3 o'clock.
    canvas.drawArc(rect, deg(-40), deg(-95), false, arc(_red)); // top
    canvas.drawArc(rect, deg(-135), deg(-90), false, arc(_yellow)); // left
    canvas.drawArc(rect, deg(135), deg(-90), false, arc(_green)); // bottom
    canvas.drawArc(rect, deg(45), deg(-45), false, arc(_blue)); // right, lower
    // Blue crossbar of the G.
    final bar = Paint()..color = _blue;
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, size.height / 2 - stroke / 2, size.width / 2, stroke),
      bar,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
