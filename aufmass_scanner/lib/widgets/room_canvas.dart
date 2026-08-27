// lib/widgets/room_canvas.dart
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

class RoomCanvas extends StatelessWidget {
  final List<Offset> rawPoints;
  final List<Offset> filteredPoints;
  final bool showRawLayer;

  const RoomCanvas({
    super.key,
    required this.rawPoints,
    required this.filteredPoints,
    required this.showRawLayer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 250,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF33333A)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CustomPaint(
          painter: _LidarRoomPainter(
            rawPoints: rawPoints,
            filteredPoints: filteredPoints,
            showRawLayer: showRawLayer,
          ),
        ),
      ),
    );
  }
}

class _LidarRoomPainter extends CustomPainter {
  final List<Offset> rawPoints;
  final List<Offset> filteredPoints;
  final bool showRawLayer;

  _LidarRoomPainter({
    required this.rawPoints,
    required this.filteredPoints,
    required this.showRawLayer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (rawPoints.isEmpty && filteredPoints.isEmpty) return;

    final allPoints = [...rawPoints, ...filteredPoints];
    double minX = allPoints.map((p) => p.dx).reduce(min);
    double maxX = allPoints.map((p) => p.dx).reduce(max);
    double minY = allPoints.map((p) => p.dy).reduce(min);
    double maxY = allPoints.map((p) => p.dy).reduce(max);

    double roomWidth = max(0.1, maxX - minX);
    double roomHeight = max(0.1, maxY - minY);

    double scale = min((size.width - 40) / roomWidth, (size.height - 40) / roomHeight);
    Offset center = Offset(
      size.width / 2 - ((minX + maxX) / 2) * scale,
      size.height / 2 - ((minY + maxY) / 2) * scale,
    );

    if (showRawLayer && rawPoints.isNotEmpty) {
      final paintRaw = Paint()
        ..color = Colors.redAccent.withOpacity(0.5)
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round;

      for (var p in rawPoints) {
        canvas.drawPoints(PointMode.points, [p * scale + center], paintRaw);
      }
    }

    if (filteredPoints.isNotEmpty) {
      final paintWalls = Paint()
        ..color = const Color(0xFF00FF66)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;

      final path = Path();
      path.moveTo(filteredPoints.first.dx * scale + center.dx, filteredPoints.first.dy * scale + center.dy);
      
      for (int i = 1; i < filteredPoints.length; i++) {
        path.lineTo(filteredPoints[i].dx * scale + center.dx, filteredPoints[i].dy * scale + center.dy);
      }
      canvas.drawPath(path, paintWalls);

      final paintCorners = Paint()
        ..color = Colors.blue
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round;

      for (var p in filteredPoints) {
        canvas.drawPoints(PointMode.points, [p * scale + center], paintCorners);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LidarRoomPainter oldDelegate) {
    return oldDelegate.rawPoints != rawPoints ||
        oldDelegate.filteredPoints != filteredPoints ||
        oldDelegate.showRawLayer != showRawLayer;
  }
}
