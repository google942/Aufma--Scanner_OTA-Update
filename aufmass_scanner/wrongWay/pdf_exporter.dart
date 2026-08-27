// lib/pdf_exporter.dart
import 'dart:math';
import 'package:flutter/material.dart' as fm;
import 'package:pdf/pdf.dart';
import 'package:pdf/src/pdf/obj/font.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class PdfExporter {
  static const List<PdfColor> _wallColors = [
    PdfColors.blue800,
    PdfColors.red800,
    PdfColors.green800,
    PdfColors.orange800,
    PdfColors.purple800,
    PdfColors.teal800,
    PdfColors.brown800,
    PdfColors.pink,
  ];

  static String _getWallLetter(int index) {
    return String.fromCharCode(65 + (index % 26));
  }

  static Future<void> generateAndPreview({
    required String roomName,
    required List<fm.Offset> filteredPoints,
    required double roomArea,
    required double totalPerimeter,
  }) async {
    final pdf = pw.Document();

    // ABSOLUT SICHER: Holt sich die native Helvetica direkt aus dem zugrundeliegenden PdfDocument-Core
    final PdfFont nativePdfFont = PdfFont.helvetica(pdf.document);

    final List<PdfPoint> pdfPoints = filteredPoints
        .map((p) => PdfPoint(p.dx, p.dy))
        .toList();

    List<double> wallLengths = [];
    if (pdfPoints.length > 1) {
      for (int i = 0; i < pdfPoints.length - 1; i++) {
        double dx = pdfPoints[i + 1].x - pdfPoints[i].x;
        double dy = pdfPoints[i + 1].y - pdfPoints[i].y;
        wallLengths.add(sqrt(dx * dx + dy * dy));
      }
    }

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Padding(
            padding: const pw.EdgeInsets.all(24),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Digitale Raum-Einmessung (Farbcodiert)', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800)),
                pw.SizedBox(height: 6),
                pw.Divider(thickness: 1.5, color: PdfColors.grey400),
                pw.SizedBox(height: 12),

                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text('Raum: ${roomName.isEmpty ? "Unbenannt" : roomName}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                        pw.Text('Datum: ${DateTime.now().day}.${DateTime.now().month}.${DateTime.now().year}', style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text('Grundfläche: ${roomArea.toStringAsFixed(2)} m²', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.green800)),
                        pw.Text('Maximale Ausdehnung: ${totalPerimeter.toStringAsFixed(2)} m', style: const pw.TextStyle(fontSize: 10)),
                        pw.Text('Wände gesamt: ${wallLengths.length}', style: const pw.TextStyle(fontSize: 10)),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 20),

                pw.Text('Grundriss-Skizze (Wand-Zuordnung):', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 8),
                
                _buildPdfPlanContainer(pdfPoints, wallLengths, nativePdfFont),
                
                pw.SizedBox(height: 20),

                pw.Text('Wand-Bemaßung (Farbcodierte Legende):', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 6),
                
                _buildPdfTable(wallLengths),
                
                pw.Spacer(),
                pw.Divider(thickness: 0.5, color: PdfColors.grey400),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Erstellt mit dem ESP32-Lidar-Scanner.', style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                    pw.Text('Seite 1 von 1', style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );

    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'Aufmass_${roomName.isEmpty ? "Raum" : roomName}.pdf',
    );
  }

  static pw.Widget _buildPdfPlanContainer(List<PdfPoint> pdfPoints, List<double> wallLengths, PdfFont nativeFont) {
    return pw.Container(
      height: 260,
      width: double.infinity,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300, width: 1),
      ),
      child: pw.Center(
        child: pw.CustomPaint(
          size: const PdfPoint(350, 240),
          painter: (PdfGraphics canvas, PdfPoint size) {
            if (pdfPoints.isEmpty) return;

            double minX = pdfPoints.map((p) => p.x).reduce(min);
            double maxX = pdfPoints.map((p) => p.x).reduce(max);
            double minY = pdfPoints.map((p) => p.y).reduce(min);
            double maxY = pdfPoints.map((p) => p.y).reduce(max);

            double w = max(0.1, maxX - minX);
            double h = max(0.1, maxY - minY);

            double scale = min((size.x - 60) / w, (size.y - 60) / h);
            double offsetX = size.x / 2 - ((minX + maxX) / 2) * scale;
            double offsetY = size.y / 2 - ((minY + maxY) / 2) * scale;

            double transformY(double rawY) {
              double pdfY = rawY * scale + offsetY;
              return size.y - pdfY;
            }

            for (int i = 0; i < pdfPoints.length - 1; i++) {
              PdfColor currentWallColor = _wallColors[i % _wallColors.length];
              canvas.setStrokeColor(currentWallColor);
              canvas.setLineWidth(3);

              double x1 = pdfPoints[i].x * scale + offsetX;
              double y1 = transformY(pdfPoints[i].y);
              double x2 = pdfPoints[i + 1].x * scale + offsetX;
              double y2 = transformY(pdfPoints[i + 1].y);

              canvas.moveTo(x1, y1);
              canvas.lineTo(x2, y2);
              canvas.strokePath();

              double midX = (x1 + x2) / 2;
              double midY = (y1 + y2) / 2;

              double dx = x2 - x1;
              double dy = y2 - y1;
              double len = sqrt(dx * dx + dy * dy);
              double nx = -dy / (len == 0 ? 1 : len);
              double ny = dx / (len == 0 ? 1 : len);

              double textX = midX + nx * 12;
              double textY = midY + ny * 12;

              canvas.setFillColor(currentWallColor);
              
              canvas.drawString(
                nativeFont,
                12, 
                _getWallLetter(i),
                textX - 4,
                textY - 4,
              );
            }

            canvas.setFillColor(PdfColors.grey700);
            for (var p in pdfPoints) {
              canvas.drawEllipse(p.x * scale + offsetX, transformY(p.y), 2, 2);
              canvas.fillPath();
            }
          },
        ),
      ),
    );
  }

  static pw.Widget _buildPdfTable(List<double> wallLengths) {
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Wand Bezeichn.', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Länge (Meter)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
            pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text('Länge (Zentimeter)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10))),
          ],
        ),
        ...List.generate(wallLengths.length, (index) {
          double currentLength = wallLengths[index];
          PdfColor rowColor = _wallColors[index % _wallColors.length];

          return pw.TableRow(
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text('Wand ${_getWallLetter(index)}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: rowColor)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text('${currentLength.toStringAsFixed(2)} m', style: pw.TextStyle(fontSize: 10, color: rowColor)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(5),
                child: pw.Text('${(currentLength * 100).toStringAsFixed(0)} cm', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: rowColor)),
              ),
            ],
          );
        }),
      ],
    );
  }
}
