// lib/wall_filter.dart
import 'dart:math';
import 'package:flutter/material.dart';

class LidarPoint {
  final double x; 
  final double y; 

  LidarPoint(this.x, this.y);

  factory LidarPoint.fromPolar(double angleDegree, double distanceMm) {
    double angleRad = angleDegree * pi / 180.0;
    double distanceMeters = distanceMm / 1000.0;
    return LidarPoint(distanceMeters * cos(angleRad), distanceMeters * sin(angleRad));
  }

  Offset toOffset() => Offset(x, y);
}

class WallModel {
  final double m; 
  final double b; 
  final double centerX; 
  final double centerY; 
  List<LidarPoint> inliers = [];

  WallModel(this.m, this.b, this.centerX, this.centerY);

  double distanceTo(Offset p) {
    return (p.dy - (m * p.dx + b)).abs() / sqrt(m * m + 1);
  }
}

class RoomMetrics {
  final double length;
  final double width;
  final double area;
  final List<Offset> cornersInSensorGKS;

  List<Offset> get corners => cornersInSensorGKS;

  RoomMetrics({
    required this.length,
    required this.width,
    required this.area,
    required this.cornersInSensorGKS,
  });
}

class MultiWallFilter {
  static RoomMetrics process({
    required List<Offset> rawPoints,
    required int maxWalls,
    required double clusterTolerance,
    required bool isMultiWall,
    required double esp32Length,
    required double esp32Width,
    required double esp32Area,
  }) {
    if (rawPoints.length < 15) {
      return RoomMetrics(length: esp32Length, width: esp32Width, area: esp32Area, cornersInSensorGKS: rawPoints);
    }

    // =========================================================================
    // MODUS A: DEIN ORIGINALER, UNBERÜHRTER 4-WAND-FILTER (Perzentil-Box)
    // =========================================================================
    if (!isMultiWall) {
      List<double> angles = [];
      for (int k = 0; k < rawPoints.length - 8; k += 2) {
        double dx = rawPoints[k + 8].dx - rawPoints[k].dx;
        double dy = rawPoints[k + 8].dy - rawPoints[k].dy;
        if (sqrt(dx * dx + dy * dy) > 0.40) {
          double a = atan2(dy, dx) % (pi / 2);
          if (a < 0) a += pi / 2;
          angles.add(a);
        }
      }
      double roomAngle = angles.isEmpty ? 0.0 : (angles..sort())[angles.length ~/ 2];
      
      List<Offset> rotated = [];
      double cosA = cos(-roomAngle), sinA = sin(-roomAngle);
      for (var p in rawPoints) {
        rotated.add(Offset(p.dx * cosA - p.dy * sinA, p.dx * sinA + p.dy * cosA));
      }
      
      List<double> xVals = rotated.map((p) => p.dx).toList()..sort();
      List<double> yVals = rotated.map((p) => p.dy).toList()..sort();
      
      double wallLeft = xVals[xVals.length ~/ 20];
      double wallRight = xVals[xVals.length - 1 - (xVals.length ~/ 20)];
      double wallBottom = yVals[yVals.length ~/ 20];
      double wallTop = yVals[yVals.length - 1 - (yVals.length ~/ 20)];
      
      List<Offset> orthoBox = [
        Offset(wallLeft, wallBottom), 
        Offset(wallRight, wallBottom), 
        Offset(wallRight, wallTop), 
        Offset(wallLeft, wallTop), 
        Offset(wallLeft, wallBottom), 
      ];
      
      List<Offset> finalBox = [];
      double cosR = cos(roomAngle), sinR = sin(roomAngle);
      for (var p in orthoBox) {
        finalBox.add(Offset(p.dx * cosR - p.dy * sinR, p.dx * sinR + p.dy * cosR));
      }

      return RoomMetrics(
        length: esp32Length, // Starr die echten Hardware-Werte zurückliefern
        width: esp32Width,
        area: esp32Area,
        cornersInSensorGKS: finalBox,
      );
    }

    // =========================================================================
    // MODUS B: DEIN FUNKTIONIERENDES, DICHTEGEWICHTETES MULTI-WAND POLYGON-MODELL
    // =========================================================================
    List<MapEntry<List<Offset>, double>> bewerteteVersuche = [];
    
    for (int seed = 10; seed < 60; seed++) {
      List<WallModel> walls = [];
      List<Offset> remainingPoints = List.from(rawPoints);
      final deterministicRandom = Random(seed);

      for (int i = 0; i < maxWalls; i++) {
        if (remainingPoints.length < 15) break;
        WallModel? bestModel;
        int maxInliers = 0;

        for (int iter = 0; iter < 40; iter++) {
          if (remainingPoints.length < 2) break;
          int idx1 = deterministicRandom.nextInt(remainingPoints.length);
          int idx2 = deterministicRandom.nextInt(remainingPoints.length);
          if (idx1 == idx2) continue;
          var p1 = remainingPoints[idx1]; var p2 = remainingPoints[idx2];
          if ((p2.dx - p1.dx).abs() < 1e-5) continue;

          double m = (p2.dy - p1.dy) / (p2.dx - p1.dx);
          double b = p1.dy - m * p1.dx;
          var currentModel = WallModel(m, b, (p1.dx + p2.dx) / 2.0, (p1.dy + p2.dy) / 2.0);

          int inlierCount = 0;
          for (var p in remainingPoints) { if (currentModel.distanceTo(p) < clusterTolerance) inlierCount++; }
          if (inlierCount > maxInliers) { maxInliers = inlierCount; bestModel = currentModel; }
        }

        if (bestModel != null && maxInliers > 15) {
          for (var p in remainingPoints) { if (bestModel.distanceTo(p) < clusterTolerance) bestModel.inliers.add(LidarPoint(p.dx, p.dy)); }
          walls.add(bestModel);
          remainingPoints.removeWhere((p) => bestModel!.inliers.any((ip) => (ip.x - p.dx).abs() < 1e-4 && (ip.y - p.dy).abs() < 1e-4));
        } else { break; }
      }

      if (walls.length < 3) continue;
      walls.sort((a, b) => atan2(a.centerY, a.centerX).compareTo(atan2(b.centerY, b.centerX)));

      List<Offset> versuchsCorners = [];
      for (int i = 0; i < walls.length; i++) {
        WallModel w1 = walls[i]; WallModel w2 = walls[(i + 1) % walls.length];
        double deltaM = w1.m - w2.m;
        if (deltaM.abs() > 0.02) {
          double xEcke = (w2.b - w1.b) / deltaM; double yEcke = w1.m * xEcke + w1.b;
          if (xEcke.abs() < 12.0 && yEcke.abs() < 12.0) versuchsCorners.add(Offset(xEcke, yEcke));
        }
      }

      if (versuchsCorners.length >= 3) {
        double qualitaetsScore = 0.0;
        double eckenToleranzQuadrat = 0.06 * 0.06;

        for (var ecke in versuchsCorners) {
          int punkteAnEcke = 0;
          for (var pt in rawPoints) {
            double dx = ecke.dx - pt.dx; double dy = ecke.dy - pt.dy;
            if ((dx * dx + dy * dy) < eckenToleranzQuadrat) punkteAnEcke++;
          }
          qualitaetsScore += punkteAnEcke * 15.0;
        }

        for (var wall in walls) {
          if (wall.inliers.isEmpty) { qualitaetsScore -= 100.0; continue; }
          double minX = wall.inliers.map((p) => p.x).reduce(min);
          double maxX = wall.inliers.map((p) => p.x).reduce(max);
          for (double x = minX; x <= maxX; x += 0.25) {
            double y = wall.m * x + wall.b; bool abschnittBestaetigt = false;
            for (var pt in rawPoints) {
              if (((x - pt.dx) * (x - pt.dx) + (y - pt.dy) * (y - pt.dy)) < 0.04) { abschnittBestaetigt = true; break; }
            }
            if (!abschnittBestaetigt) { qualitaetsScore -= 25.0; }
          }
        }
        bewerteteVersuche.add(MapEntry(versuchsCorners, qualitaetsScore));
      }
    }

    if (bewerteteVersuche.isNotEmpty) {
      bewerteteVersuche.sort((a, b) => b.value.compareTo(a.value));
      var gewinnerEcken = bewerteteVersuche.first.key;
      List<Offset> polygonEcken = List.from(gewinnerEcken)..add(gewinnerEcken.first);

      double minX = polygonEcken.map((c) => c.dx).reduce(min);
      double maxX = polygonEcken.map((c) => c.dx).reduce(max);
      double minY = polygonEcken.map((c) => c.dy).reduce(min);
      double maxY = polygonEcken.map((c) => c.dy).reduce(max);

      double areaSum = 0.0;
      int j = polygonEcken.length - 1;
      for (int i = 0; i < polygonEcken.length; i++) {
        areaSum += (polygonEcken[j].dx + polygonEcken[i].dx) * (polygonEcken[j].dy - polygonEcken[i].dy);
        j = i;
      }

      return RoomMetrics(
        length: (maxX - minX).abs(),
        width: (maxY - minY).abs(),
        area: areaSum.abs() / 2.0,
        cornersInSensorGKS: polygonEcken,
      );
    }

    return RoomMetrics(length: esp32Length, width: esp32Width, area: esp32Area, cornersInSensorGKS: rawPoints);
  }
}
