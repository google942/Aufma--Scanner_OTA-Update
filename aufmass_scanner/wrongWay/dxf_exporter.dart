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

  /// Generiert die CAD-Datei, spiegelt die Y-Achse für die Draufsicht und packt die Rohdaten für FreeCAD mit rein
  static Future<void> generateAndShare({
    required String roomName,
    required List<Offset> filteredPoints,
    required List<Offset> rawPoints,
  }) async {
    String name = roomName.trim().isEmpty ? "Diagnose_Aufmass" : roomName.trim();
    StringBuffer dxf = StringBuffer();

    // 1. Header & Layer-Definitionen (Erweitert um DIAGNOSE-Layer in Rot)
    dxf.write("  0\nSECTION\n  2\nHEADER\n  0\nENDSEC\n");
    dxf.write("  0\nSECTION\n  2\nTABLES\n  0\nTABLE\n  2\nLAYER\n");
    dxf.write("  0\nLAYER\n  2\nWAENDE\n 70\n0\n 62\n3\n"); // Berechnetes Polygon (Grün)
    dxf.write("  0\nLAYER\n  2\nBESCHRIFTUNG\n 70\n0\n 62\n7\n"); // Wand-Buchstaben (Weiß)
    dxf.write("  0\nLAYER\n  2\nROHDATEN_DIAGNOSE\n 70\n0\n 62\n1\n"); // Diagnose-Layer (Rot)
    dxf.write("  0\nENDTAB\n  0\nENDSEC\n  0\nSECTION\n  2\nENTITIES\n");

    // KORREKTUR: Hilfsfunktion zur Invertierung der Y-Achse für die korrekte Draufsicht
    double transformY(double rawY) => -rawY;

    // ==========================================
    // LAYER A: Das berechnete Multi-Wand-Polygon
    // ==========================================
    if (filteredPoints.isNotEmpty) {
      for (int i = 0; i < filteredPoints.length - 1; i++) {
        Offset p1 = filteredPoints[i];
        Offset p2 = filteredPoints[i + 1];
        
        double y1 = transformY(p1.dy);
        double y2 = transformY(p2.dy);

        // Wand-Linie schreiben (Lagerichtig gespiegelt)
        dxf.write("  0\nLINE\n  8\nWAENDE\n 10\n${p1.dx}\n 20\n$y1\n 11\n${p2.dx}\n 21\n$y2\n");

        // Text-Label (A, B, C...) mittig platzieren
        double midX = (p1.dx + p2.dx) / 2;
        double midY = (y1 + y2) / 2;
        double dx = p2.dx - p1.dx;
        double dy = y2 - y1;
        double len = sqrt(dx * dx + dy * dy);
        double nx = -dy / (len == 0 ? 1 : len);
        double ny = dx / (len == 0 ? 1 : len);

        double textX = midX + nx * 0.15;
        double textY = midY + ny * 0.15;

        dxf.write("  0\nTEXT\n  8\nBESCHRIFTUNG\n 10\n$textX\n 20\n$textY\n 40\n0.12\n 1\nWand ${_getWallLetter(i)}\n");
      }
    }

    // ==========================================
    // LAYER B: Die unfiltrierten ESP32-Rohdaten
    // ==========================================
    // Zeichnet jeden Rohpunkt als kleines Kreuz, ebenfalls über transformY gespiegelt
    for (var rp in rawPoints) {
      double r = 0.01; // 1 cm Radius für das CAD-Kreuz
      double ry = transformY(rp.dy); // Auch die Rohdaten-Y-Achse spiegeln!
      
      // Horizontale Linie des Punktes
      dxf.write("  0\nLINE\n  8\nROHDATEN_DIAGNOSE\n 10\n${rp.dx - r}\n 20\n$ry\n 11\n${rp.dx + r}\n 21\n$ry\n");
      // Vertikale Linie des Punktes
      dxf.write("  0\nLINE\n  8\nROHDATEN_DIAGNOSE\n 10\n${rp.dx}\n 20\n${ry - r}\n 11\n${rp.dx}\n 21\n${ry + r}\n");
    }

    // 3. Dateiende
    dxf.write("  0\nENDSEC\n  0\nEOF\n");

    final bytes = utf8.encode(dxf.toString());
    await Printing.sharePdf(
      bytes: Uint8List.fromList(bytes), 
      filename: '${name}_diagnose.dxf',
    );
  }
}
