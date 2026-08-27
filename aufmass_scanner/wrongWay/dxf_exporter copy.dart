// lib/dxf_exporter.dart
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

class DxfExporter {
  static String _getWallLetter(int index) {
    return String.fromCharCode(65 + (index % 26));
  }

  /// Exportiert die berechneten Wände inklusive Text-Beschriftung (A, B, C...) für CAD
  static Future<void> generateAndShare({
    required String roomName,
    required List<Offset> filteredPoints,
    required List<Offset> rawPoints,
  }) async {
    List<Offset> pointsToExport = filteredPoints.isNotEmpty ? filteredPoints : rawPoints;
    if (pointsToExport.isEmpty) return;

    String name = roomName.trim().isEmpty ? "Aufmass" : roomName.trim();
    StringBuffer dxf = StringBuffer();

    // 1. Header & Layer-Tabellen
    dxf.write("  0\nSECTION\n  2\nHEADER\n  0\nENDSEC\n");
    dxf.write("  0\nSECTION\n  2\nTABLES\n  0\nTABLE\n  2\nLAYER\n");
    dxf.write("  0\nLAYER\n  2\nWAENDE\n 70\n0\n 62\n3\n  0\nLAYER\n  2\nBESCHRIFTUNG\n 70\n0\n 62\n7\n"); // Layer für Texte (Farbe 7 = Weiß/Schwarz)
    dxf.write("  0\nENDTAB\n  0\nENDSEC\n  0\nSECTION\n  2\nENTITIES\n");

    // 2. Linien und zugehörige Text-Buchstaben schreiben
    for (int i = 0; i < pointsToExport.length - 1; i++) {
      Offset p1 = pointsToExport[i];
      Offset p2 = pointsToExport[i + 1];
      
      // Wand-Linie schreiben
      dxf.write("  0\nLINE\n  8\nWAENDE\n 10\n${p1.dx}\n 20\n${p1.dy}\n 11\n${p2.dx}\n 21\n${p2.dy}\n");

      // TEXT-PLATZIERUNG: Mittelpunkt der Wand berechnen
      double midX = (p1.dx + p2.dx) / 2;
      double midY = (p1.dy + p2.dy) / 2;

      // Normalenvektor nach außen berechnen (für ca. 15cm Abstand zur Wand)
      double dx = p2.dx - p1.dx;
      double dy = p2.dy - p1.dy;
      double len = sqrt(dx * dx + dy * dy);
      double nx = -dy / (len == 0 ? 1 : len);
      double ny = dx / (len == 0 ? 1 : len);

      double textX = midX + nx * 0.15;
      double textY = midY + ny * 0.15;

      // TEXT-Entität in die DXF schreiben
      dxf.write("  0\nTEXT\n  8\nBESCHRIFTUNG\n");
      dxf.write(" 10\n$textX\n"); // X-Koordinate
      dxf.write(" 20\n$textY\n"); // Y-Koordinate
      dxf.write(" 40\n0.12\n");   // Texthöhe (12 cm im CAD)
      dxf.write("  1\nWand ${_getWallLetter(i)}\n"); // Der eigentliche Textinhalt
    }

    // 3. Dateiende
    dxf.write("  0\nENDSEC\n  0\nEOF\n");

    final bytes = utf8.encode(dxf.toString());
    await Printing.sharePdf(
      bytes: Uint8List.fromList(bytes), 
      filename: '${name}_plan.dxf',
    );
  }
}
