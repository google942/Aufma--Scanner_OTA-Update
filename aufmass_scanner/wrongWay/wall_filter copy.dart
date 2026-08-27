// lib/wall_filter.dart
import 'dart:math';
import 'package:flutter/material.dart';

/// Repräsentiert eine homogene 2D-Transformationsmatrix (3x3) für KMT-Operationen.
class TransformationMatrix2D {
  final double m00, m01, m02;
  final double m10, m11, m12;
  final double m20, m21, m22;

  const TransformationMatrix2D({
    this.m00 = 1, this.m01 = 0, this.m02 = 0,
    this.m10 = 0, this.m11 = 1, this.m12 = 0,
    this.m20 = 0, this.m21 = 0, this.m22 = 1,
  });

  factory TransformationMatrix2D.alignment(Offset translation, double rotationAngle, bool flipY) {
    double c = cos(rotationAngle);
    double s = sin(rotationAngle);
    double yScale = flipY ? -1.0 : 1.0;
    
    return TransformationMatrix2D(
      m00: c,   m01: -s * yScale, m02: translation.dx,
      m10: s,   m11: c * yScale,  m12: translation.dy,
      m20: 0,   m21: 0,           m22: 1,
    );
  }

  Offset transform(Offset p) {
    double x = m00 * p.dx + m01 * p.dy + m02;
    double y = m10 * p.dx + m11 * p.dy + m12;
    return Offset(x, y);
  }

  TransformationMatrix2D inverse() {
    double det = m00 * m11 - m01 * m10;
    if (det.abs() < 1e-12) return const TransformationMatrix2D();
    return TransformationMatrix2D(
      m00: m11 / det,  m01: -m01 / det, m02: (m01 * m12 - m02 * m11) / det,
      m10: -m10 / det, m11: m00 / det,  m12: (m02 * m10 - m00 * m12) / det,
      m20: 0,          m21: 0,          m22: 1,
    );
  }
}

class RoomMetrics {
  final double length;
  final double width;
  final double area;
  final List<Offset> cornersInRaumLKS;
  final List<Offset> cornersInSensorGKS;
  final TransformationMatrix2D sensorToRaum;

  List<Offset> get corners => cornersInSensorGKS;

  RoomMetrics({
    required this.length,
    required this.width,
    required this.area,
    required this.cornersInRaumLKS,
    required this.cornersInSensorGKS,
    required this.sensorToRaum,
  });
}

class MultiWallFilter {
  static RoomMetrics process({
    required List<Offset> rawPoints, 
    int maxWalls = 100, 
    double clusterTolerance = 0.15, 
    bool isMultiWall = false,
  }) {
    if (rawPoints.length < 15) {
      return RoomMetrics(length: 0, width: 0, area: 0, cornersInRaumLKS: [], cornersInSensorGKS: [], sensorToRaum: const TransformationMatrix2D());
    }

    // =========================================================================
    // SCHRITT 1: KMT-Bezugsflächen-Ermittlung (Dominante Hauptwände statt Wand A)
    // =========================================================================
    // Wir klassifizieren Vektoren in 5-Grad-Schritten, um die echten langen Hauptwände zu finden
    Map<int, double> sectorLengths = {};
    for (int k = 0; k < rawPoints.length - 8; k += 4) {
      double dx = rawPoints[k + 8].dx - rawPoints[k].dx;
      double dy = rawPoints[k + 8].dy - rawPoints[k].dy;
      double len = sqrt(dx * dx + dy * dy);
      if (len > 0.08) {
        double angle = (atan2(dy, dx) % (pi / 2));
        if (angle < 0) angle += pi / 2;
        int sector = (angle * 180 / pi).round() % 90;
        sectorLengths[sector] = (sectorLengths[sector] ?? 0) + len;
      }
    }

    int dominantSector = 0;
    double maxSectorLen = 0;
    sectorLengths.forEach((sector, len) {
      if (len > maxSectorLen) {
        maxSectorLen = len;
        dominantSector = sector;
      }
    });
    double roomAngle = dominantSector * pi / 180;

    // =========================================================================
    // SCHRITT 2: Stabiles, unantastbares Haupt-Rohteilrechteck einmessen
    // =========================================================================
    List<Offset> preRotated = [];
    double cosA = cos(-roomAngle), sinA = sin(-roomAngle);
    for (var p in rawPoints) {
      preRotated.add(Offset(p.dx * cosA - p.dy * sinA, p.dx * sinA + p.dy * cosA));
    }
    
    List<double> xVals = preRotated.map((p) => p.dx).toList()..sort();
    List<double> yVals = preRotated.map((p) => p.dy).toList()..sort();

    // 5%-Quantil schützt vor "Ausbrüchen" durch offene Türen/Fenster auf der Außenhaut
    double boundLeft = xVals[xVals.length ~/ 20]; 
    double boundBottom = yVals[yVals.length ~/ 20];
    double boundRight = xVals[xVals.length - 1 - (xVals.length ~/ 20)];
    double boundTop = yVals[yVals.length - 1 - (yVals.length ~/ 20)];

    // Nullpunkt des stabilen Raum-LKS in die Ecke unten links legen
    Offset originOffsetSensorGKS = Offset(
      boundLeft * cos(roomAngle) - boundBottom * sin(roomAngle),
      boundLeft * sin(roomAngle) + boundBottom * cos(roomAngle)
    );

    final TransformationMatrix2D sensorToRaum = TransformationMatrix2D.alignment(originOffsetSensorGKS, roomAngle, true).inverse();
    final TransformationMatrix2D raumToSensor = sensorToRaum.inverse();

    List<Offset> ptsInRaumLKS = rawPoints.map((p) => sensorToRaum.transform(p)).toList();

    // Die unverrückbare, starr geschlossene Außenhaut (Wand A, B, C, D)
    final double baseLeft = 0.0;
    final double baseBottom = 0.0;
    final double baseRight = boundRight - boundLeft;
    final double baseTop = boundTop - boundBottom;

    List<Offset> orthoBoxRaumLKS = [];

    // =========================================================================
    // SCHRITT 3: Nischen-Infiltration streng INNERHALB der Außenhaut-Grenzen
    // =========================================================================
    if (isMultiWall) {
      double minNicheSize = 0.35; // Erkennt Bauteile ab 35cm Tiefe
      
      double innerLeft = baseLeft;   double nicheLeftYStart = baseBottom;   double nicheLeftYEnd = baseTop;
      double innerRight = baseRight; double nicheRightYStart = baseBottom; double nicheRightYEnd = baseTop;
      double innerBottom = baseBottom; double nicheBottomXStart = baseLeft; double nicheBottomXEnd = baseRight;
      double innerTop = baseTop;     double nicheTopXStart = baseLeft;     double nicheTopXEnd = baseRight;

      bool hasLeft = false, hasRight = false, hasBottom = false, hasTop = false;
      double splitX = (baseLeft + baseRight) / 2;
      double splitY = (baseBottom + baseTop) / 2;

      // Antast-Funktion scannt von der eingefrorenen Außenhaut ins Innere des Raums
      Map<String, double>? scanInternalNiche(List<Offset> pts, double start, double end, bool scanX, double step) {
        double current = start;
        while ((step > 0 ? current <= end : current >= end)) {
          List<double> crossVals = [];
          for (var p in pts) {
            double d = scanX ? (p.dx - current).abs() : (p.dy - current).abs();
            // Nur Punkte werten, die sich innerhalb des zulässigen Gehäuses befinden
            if (d < 0.04) {
              double cross = scanX ? p.dy : p.dx;
              if (scanX ? (p.dy >= baseBottom && p.dy <= baseTop) : (p.dx >= baseLeft && p.dx <= baseRight)) {
                crossVals.add(cross);
              }
            }
          }
          // Signal für eine massive, reale Innenwandstruktur im Raum
          if (crossVals.length > 22) {
            crossVals.sort();
            return {'pos': current, 'min': crossVals.first, 'max': crossVals.last};
          }
          current += step;
        }
        return null;
      }

      // Wir tasten uns von der Außenhaut kontrolliert nach innen vor
      var leftScan = scanInternalNiche(ptsInRaumLKS, baseLeft + 0.20, splitX - 0.25, true, 0.02);
      var rightScan = scanInternalNiche(ptsInRaumLKS, baseRight - 0.20, splitX + 0.25, true, -0.02);
      var bottomScan = scanInternalNiche(ptsInRaumLKS, baseBottom + 0.20, splitY - 0.25, false, 0.02);
      var topScan = scanInternalNiche(ptsInRaumLKS, baseTop - 0.20, splitY + 0.25, false, -0.02);

      if (leftScan != null && (leftScan['pos']! - baseLeft).abs() >= minNicheSize) {
        innerLeft = leftScan['pos']!; nicheLeftYStart = leftScan['min']!; nicheLeftYEnd = leftScan['max']!; hasLeft = true;
      }
      if (rightScan != null && (baseRight - rightScan['pos']!).abs() >= minNicheSize) {
        innerRight = rightScan['pos']!; nicheRightYStart = rightScan['min']!; nicheRightYEnd = rightScan['max']!; hasRight = true;
      }
      if (bottomScan != null && (bottomScan['pos']! - baseBottom).abs() >= minNicheSize) {
        innerBottom = bottomScan['pos']!; nicheBottomXStart = bottomScan['min']!; nicheBottomXEnd = bottomScan['max']!; hasBottom = true;
      }
      if (topScan != null && (baseTop - topScan['pos']!).abs() >= minNicheSize) {
        innerTop = topScan['pos']!; nicheTopXStart = topScan['min']!; nicheTopXEnd = topScan['max']!; hasTop = true;
      }

      // Bauteil-Polygon lückenlos im Uhrzeigersinn verketten
      orthoBoxRaumLKS.add(Offset(baseLeft, baseBottom));

      if (hasBottom) {
        orthoBoxRaumLKS.add(Offset(nicheBottomXStart, baseBottom));
        orthoBoxRaumLKS.add(Offset(nicheBottomXStart, innerBottom));
        orthoBoxRaumLKS.add(Offset(nicheBottomXEnd, innerBottom));
        orthoBoxRaumLKS.add(Offset(nicheBottomXEnd, baseBottom));
      }

      orthoBoxRaumLKS.add(Offset(baseRight, baseBottom));

      // Rechter Rücksprung (Euer realer T-Raum-Flügel)
      if (hasRight) {
        orthoBoxRaumLKS.add(Offset(baseRight, max(baseBottom, nicheRightYStart)));
        orthoBoxRaumLKS.add(Offset(innerRight, max(baseBottom, nicheRightYStart)));
        orthoBoxRaumLKS.add(Offset(innerRight, min(baseTop, nicheRightYEnd)));
        orthoBoxRaumLKS.add(Offset(baseRight, min(baseTop, nicheRightYEnd)));
      }

      orthoBoxRaumLKS.add(Offset(baseRight, baseTop));

      if (hasTop) {
        orthoBoxRaumLKS.add(Offset(nicheTopXEnd, baseTop));
        orthoBoxRaumLKS.add(Offset(nicheTopXEnd, innerTop));
        orthoBoxRaumLKS.add(Offset(nicheTopXStart, innerTop));
        orthoBoxRaumLKS.add(Offset(nicheTopXStart, baseTop));
      }

      orthoBoxRaumLKS.add(Offset(baseLeft, baseTop));

      if (hasLeft) {
        orthoBoxRaumLKS.add(Offset(baseLeft, min(baseTop, nicheLeftYEnd)));
        orthoBoxRaumLKS.add(Offset(innerLeft, min(baseTop, nicheLeftYEnd)));
        orthoBoxRaumLKS.add(Offset(innerLeft, max(baseBottom, nicheLeftYStart)));
        orthoBoxRaumLKS.add(Offset(baseLeft, max(baseBottom, nicheLeftYStart)));
      }

      orthoBoxRaumLKS.add(Offset(baseLeft, baseBottom));

      List<Offset> cleanBox = [];
      for (var p in orthoBoxRaumLKS) {
        if (cleanBox.isEmpty || (cleanBox.last - p).distance > 0.03) cleanBox.add(p);
      }
      orthoBoxRaumLKS = cleanBox;
      if (orthoBoxRaumLKS.first != orthoBoxRaumLKS.last) orthoBoxRaumLKS.add(orthoBoxRaumLKS.first);
    }

    if (orthoBoxRaumLKS.isEmpty || orthoBoxRaumLKS.length < 4) {
      orthoBoxRaumLKS = [
        Offset(baseLeft, baseBottom),
        Offset(baseRight, baseBottom),
        Offset(baseRight, baseTop),
        Offset(baseLeft, baseTop),
        Offset(baseLeft, baseBottom),
      ];
    }

    // =========================================================================
    // SCHRITT 4: Rücktransformation ins Sensor-GKS für präzise CAD-Exporte
    // =========================================================================
    List<Offset> finalBoxSensorGKS = orthoBoxRaumLKS.map((p) => raumToSensor.transform(p)).toList();

    double maxRoomLength = baseRight;
    double maxRoomWidth = baseTop;

    double areaSum = 0.0;
    List<Offset> areaPts = List.from(orthoBoxRaumLKS);
    if (areaPts.isNotEmpty && areaPts.first == areaPts.last) {
      areaPts.removeLast();
    }
    
    int j = areaPts.length - 1;
    for (int i = 0; i < areaPts.length; i++) {
      areaSum += (areaPts[j].dx + areaPts[i].dx) * (areaPts[j].dy - areaPts[i].dy);
      j = i;
    }

    return RoomMetrics(
      length: maxRoomLength,
      width: maxRoomWidth,
      area: areaSum.abs() / 2.0,
      cornersInRaumLKS: orthoBoxRaumLKS,
      cornersInSensorGKS: finalBoxSensorGKS,
      sensorToRaum: sensorToRaum,
    );
  }
}
