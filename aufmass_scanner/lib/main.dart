import 'dart:ui';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial_ble/flutter_bluetooth_serial_ble.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() => runApp(const AufmassApp());

class AufmassApp extends StatelessWidget {
  const AufmassApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aufmaß-Scanner Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: const Color(0xFF00E676),
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  BluetoothConnection? connection;
  bool isConnected = false;
  bool isScanning = false;
  String statusMessage = "Suche Scanner...";
  double laenge = 0.0, breite = 0.0, flaeche = 0.0;
  final TextEditingController _roomController = TextEditingController();
  List<String> _history = [];

  List<Offset> rawPoints = [];
  List<Offset> filteredPoints = [];
  String _currentIncomingBuffer = "";
  bool _isStandard4WallMode = true;

  double userTolerance = 0.20;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _autoConnect();
  }

  void _autoConnect() async {
    try {
      List<BluetoothDevice> devices =
          await FlutterBluetoothSerial.instance.getBondedDevices();
      BluetoothDevice? targetDevice;
      for (var d in devices) {
        if (d.name == "Aufmass-Scanner-Pro") {
          targetDevice = d;
          break;
        }
      }
      if (targetDevice != null) {
        setState(() => statusMessage = "Verbinde mit Hardware...");
        BluetoothConnection.toAddress(targetDevice.address).then((conn) {
          setState(() {
            connection = conn;
            isConnected = true;
            statusMessage = "VERBUNDEN (Bereit)";
          });
          connection!.input!.listen(_onDataChunkReceived).onDone(() {
            setState(() {
              isConnected = false;
              statusMessage = "Verbindung verloren";
            });
          });
        });
      } else {
        setState(
            () => statusMessage = "Gerät nicht gekoppelt (BT Menü prüfen)");
      }
    } catch (e) {
      setState(() => statusMessage = "Verbindungsfehler");
    }
  }

  void _onDataChunkReceived(Uint8List data) {
    _currentIncomingBuffer += utf8.decode(data);
    while (_currentIncomingBuffer.contains('\n')) {
      int lineEnd = _currentIncomingBuffer.indexOf('\n');
      String line = _currentIncomingBuffer.substring(0, lineEnd).trim();
      _currentIncomingBuffer = _currentIncomingBuffer.substring(lineEnd + 1);
      _parseProtocolLine(line);
    }
  }

  void _parseProtocolLine(String line) {
        if (line == "STATUS:SCANNING") {
      setState(() {
        isScanning = true;
        statusMessage = "SCAN LÄUFT...";
        rawPoints = [];
        filteredPoints = [];
        // NEU: Setzt die alten Text-Kacheln der UI sofort auf 0 zurück
        laenge = 0.0;
        breite = 0.0;
        flaeche = 0.0;
      });

    } else if (line.startsWith("P:")) {
      try {
        List<String> coords = line.substring(2).split(',');
        if (coords.length == 2) {
          double x = double.parse(coords.first) / 1000.0;
          double y = double.parse(coords.last) / 1000.0;

          double distToDevice = sqrt(x * x + y * y);
          if (distToDevice > 0.25) {
            setState(() {
              rawPoints = [...rawPoints, Offset(x, y)];
            });
          }
        }
      } catch (_) {}
    } else if (line.startsWith("RESULT:")) {
      if (_isStandard4WallMode) {
        _applyOrthogonalBoxFilter();
      } else {
        _applyPolygonFilter();
        // Sicherheitsnetz: Bei kollabiertem Polygon mit ausreichend Rohdaten
        // eine größere Cluster-Toleranz erzwingen, um L-/T-Formen zu retten.
        if (filteredPoints.length <= 5 && rawPoints.length > 100) {
          _applyPolygonFilter(tolerance: 0.20);
        }
      }
      setState(() {
        isScanning = false;
        statusMessage = _isStandard4WallMode
            ? "MESSUNG FERTIG (4-WAND)"
            : "MESSUNG FERTIG (POLYGON)";
      });
      _saveToHistory();

      if (connection != null && isConnected) {
        String responsePayload = "APP_RESULT:${laenge.toStringAsFixed(2)},"
            "${breite.toStringAsFixed(2)},"
            "${flaeche.toStringAsFixed(2)}\n";
        connection!.output.add(utf8.encode(responsePayload));
        connection!.output.allSent;
      }
    }
  }

  void _applyOrthogonalBoxFilter() {
    if (rawPoints.length < 15) {
      setState(() => filteredPoints = List.from(rawPoints));
      return;
    }

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
    double roomAngle =
        angles.isEmpty ? 0.0 : (angles..sort())[angles.length ~/ 2];

    List<Offset> rotated = [];
    double cosA = cos(-roomAngle), sinA = sin(-roomAngle);
    for (var p in rawPoints) {
      rotated.add(Offset(
        p.dx * cosA - p.dy * sinA,
        p.dx * sinA + p.dy * cosA,
      ));
    }

    List<double> xVals = rotated.map((p) => p.dx).toList()..sort();
    List<double> yVals = rotated.map((p) => p.dy).toList()..sort();
    // Randbereinigung anhand des physischen Wertebereichs statt der
    // Punktanzahl: Die Punktdichte sinkt mit der Entfernung zum Scanner,
    // sodass eine indexbasierte Prozent-Kürzung die weiter entfernte/längere
    // Wand überproportional stark verkürzt hat (Skalierungsfehler).
    const edgeTrimFraction = 0.01;
    double xRange = xVals.last - xVals.first;
    double yRange = yVals.last - yVals.first;
    double wallLeft = xVals.first + xRange * edgeTrimFraction;
    double wallRight = xVals.last - xRange * edgeTrimFraction;
    double wallBottom = yVals.first + yRange * edgeTrimFraction;
    double wallTop = yVals.last - yRange * edgeTrimFraction;

//hier entnommen...



      // EXAKT DIESEN ABSCHNITT AM ENDE VON _applyOrthogonalBoxFilter ANPASSEN:
    double calculatedLength = (wallRight - wallLeft).abs();
    double calculatedWidth = (wallTop - wallBottom).abs();
    
    // KORREKTUR: Logischer Tausch für absolute Konsistenz im gesamten System.
    // Das größere Hüllmaß ist IMMER die Länge, das kleinere IMMER die Breite.
    double final4WallLength = max(calculatedLength, calculatedWidth);
    double final4WallWidth = min(calculatedLength, calculatedWidth);
    
    double calculatedArea = final4WallLength * final4WallWidth;
    
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
    
    setState(() {
      filteredPoints = finalBox;
      laenge = final4WallLength; // Weist garantiert den Maximalwert zu
      breite = final4WallWidth;  // Weist garantiert den Minimalwert zu
      flaeche = calculatedArea;
    });
  }


  // TEMPORÄR: 90°-/Parallelitäts-Rekonstruktion deaktiviert, Rohpunkte werden
  // stattdessen direkt winkelbasiert um den Schwerpunkt verbunden.
  static const bool _disableOrthogonalWallReconstruction = true;

  // Verbindet die Rohpunkte in Winkelreihenfolge um den Schwerpunkt zu einem
  // geschlossenen Raumumriss, ohne 90°- oder Parallelitätsannahmen.
  void _applyRawContourFilter() {
    double centerX =
        rawPoints.map((p) => p.dx).reduce((a, b) => a + b) / rawPoints.length;
    double centerY =
        rawPoints.map((p) => p.dy).reduce((a, b) => a + b) / rawPoints.length;

    List<Offset> ordered = List.from(rawPoints)
      ..sort((a, b) => atan2(a.dy - centerY, a.dx - centerX)
          .compareTo(atan2(b.dy - centerY, b.dx - centerX)));
    ordered.add(ordered.first);

    double calculatedArea = 0.0;
    for (int i = 0; i < ordered.length - 1; i++) {
      calculatedArea +=
          ordered[i].dx * ordered[i + 1].dy - ordered[i + 1].dx * ordered[i].dy;
    }

    List<double> xVals = ordered.map((p) => p.dx).toList();
    List<double> yVals = ordered.map((p) => p.dy).toList();
    double maxLength = (xVals.reduce(max) - xVals.reduce(min)).abs();
    double maxWidth = (yVals.reduce(max) - yVals.reduce(min)).abs();
    if (maxWidth > maxLength) {
      final temporary = maxLength;
      maxLength = maxWidth;
      maxWidth = temporary;
    }

    setState(() {
      filteredPoints = ordered;
      laenge = maxLength;
      breite = maxWidth;
      flaeche = calculatedArea.abs() / 2.0;
    });
  }

  void _applyPolygonFilter({double tolerance = 0.15}) {
    if (rawPoints.length < 15) {
      setState(() => filteredPoints = List.from(rawPoints));
      return;
    }

    if (_disableOrthogonalWallReconstruction) {
      _applyRawContourFilter();
      _applyUniversalPolygonSanitization();
      return;
    }

    List<double> angles = [];
    for (int k = 0; k < rawPoints.length - 8; k += 2) {
      double dx = rawPoints[k + 8].dx - rawPoints[k].dx;
      double dy = rawPoints[k + 8].dy - rawPoints[k].dy;
      if (sqrt(dx * dx + dy * dy) > 0.40) {
        double angle = atan2(dy, dx) % (pi / 2);
        if (angle < 0) angle += pi / 2;
        angles.add(angle);
      }
    }
    const angleTolerance = pi / 20;
    double roomAngle =
        angles.isEmpty ? 0.0 : (angles..sort())[angles.length ~/ 2];
    if (angles.length > 1) {
      final consistentAngles = angles.where((angle) {
        final difference = (angle - roomAngle).abs();
        return difference <= angleTolerance ||
            difference >= pi / 2 - angleTolerance;
      }).toList();
      if (consistentAngles.isNotEmpty) {
        consistentAngles.sort();
        roomAngle = consistentAngles[consistentAngles.length ~/ 2];
      }
    }

    double cosA = cos(-roomAngle), sinA = sin(-roomAngle);
    List<Offset> rotated = rawPoints
        .map((point) => Offset(
              point.dx * cosA - point.dy * sinA,
              point.dx * sinA + point.dy * cosA,
            ))
        .toList();

    final densityThreshold = rotated.length / 12;
    List<double> xWalls = [];
    List<double> yWalls = [];
    for (final point in rotated) {
      final xCount = rotated
          .where((other) => (other.dx - point.dx).abs() < tolerance)
          .length;
      if (xCount > densityThreshold &&
          !xWalls.any((x) => (x - point.dx).abs() < tolerance)) {
        xWalls.add(point.dx);
      }

      final yCount = rotated
          .where((other) => (other.dy - point.dy).abs() < tolerance)
          .length;
      if (yCount > densityThreshold &&
          !yWalls.any((y) => (y - point.dy).abs() < tolerance)) {
        yWalls.add(point.dy);
      }
    }
    xWalls.sort();
    yWalls.sort();
    xWalls = _mergeNearbyLines(xWalls, tolerance);
    yWalls = _mergeNearbyLines(yWalls, tolerance);

    const maxWallLines = 30;
    if (xWalls.length + yWalls.length > maxWallLines) {
      final maxXWalls = min(xWalls.length, maxWallLines ~/ 2);
      final maxYWalls = min(yWalls.length, maxWallLines - maxXWalls);
      xWalls = _selectOuterLines(xWalls, maxXWalls);
      yWalls = _selectOuterLines(yWalls, maxYWalls);
    }

    if (xWalls.length < 2) {
      xWalls = [
        rotated.map((point) => point.dx).reduce(min),
        rotated.map((point) => point.dx).reduce(max),
      ];
    }
    if (yWalls.length < 2) {
      yWalls = [
        rotated.map((point) => point.dy).reduce(min),
        rotated.map((point) => point.dy).reduce(max),
      ];
    }

    final double xMin = xWalls.first;
    final double xMax = xWalls.last;
    final double yMin = yWalls.first;
    final double yMax = yWalls.last;
    List<Offset> rotPolygon = [Offset(xMin, yMin)];
    for (final x in xWalls.skip(1)) {
      rotPolygon.add(Offset(x, yMin));
    }
    for (final y in yWalls.skip(1)) {
      rotPolygon.add(Offset(xMax, y));
    }
    for (final x in xWalls.reversed.skip(1)) {
      rotPolygon.add(Offset(x, yMax));
    }
    for (final y in yWalls.reversed.skip(1)) {
      rotPolygon.add(Offset(xMin, y));
    }

    double calculatedArea = 0.015;
    for (int i = 0; i < rotPolygon.length - 1; i++) {
      calculatedArea += rotPolygon[i].dx * rotPolygon[i + 1].dy -
          rotPolygon[i + 1].dx * rotPolygon[i].dy;
    }

    double maxLength = (xMax - xMin).abs();
    double maxWidth = (yMax - yMin).abs();
    if (maxWidth > maxLength) {
      final temporary = maxLength;
      maxLength = maxWidth;
      maxWidth = temporary;
    }

    double cosR = cos(roomAngle), sinR = sin(roomAngle);
    List<Offset> finalPolygon = rotPolygon
        .map((point) => Offset(
              point.dx * cosR - point.dy * sinR,
              point.dx * sinR + point.dy * cosR,
            ))
        .toList();

    setState(() {
      filteredPoints = finalPolygon;
      laenge = maxLength;
      breite = maxWidth;
      flaeche = calculatedArea.abs() / 2.0;
    });
  }

void _applyUniversalPolygonSanitization() {
  // Geometrie-Vorgabe kommt vom Polygon, der Winkel stabil aus den rawPoints
  final List<Offset> basePolygon = filteredPoints.isNotEmpty ? filteredPoints : rawPoints;
  if (basePolygon.length < 4 || rawPoints.length < 15) return;

  // 1. SCHRITT: ROTATIONSWINKEL STABIL AUS DEN RAWPOINTS ABLEITEN (Unverändert)
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
  double mainRoomAngle = angles.isEmpty ? 0.0 : (angles..sort())[angles.length ~/ 2];

  // 2. SCHRITT: GEOMETRIE-POLYGON REIN PARALLEL ZU DEN REELLEN ACHSEN DREHEN (Unverändert)
  double cosA = cos(-mainRoomAngle), sinA = sin(-mainRoomAngle);
  List<Offset> rotatedRawPolygon = basePolygon.map((Offset p) => Offset(
    p.dx * cosA - p.dy * sinA,
    p.dx * sinA + p.dy * cosA,
  )).toList();

    // 3. SCHRITT: OPTIMIERT MIT RICHTUNGS-VETO GEGEN ECKEN-ARTEFAKTE
  // 'userTolerance' wird später durch den UI-Slider dynamisch übergeben
  double minWallLength = userTolerance; 
  List<Offset> sanitizedRotated = [];
  sanitizedRotated.add(rotatedRawPolygon.first);
  
  bool isCurrentlyHorizontal = true;
  if (rotatedRawPolygon.length > 1) {
    double dx = rotatedRawPolygon[1].dx - rotatedRawPolygon[0].dx;
    double dy = rotatedRawPolygon[1].dy - rotatedRawPolygon[0].dy;
    isCurrentlyHorizontal = dx.abs() > dy.abs();
  }

  // NEU: Ein Flag, das signalisiert, dass gerade eben eine Ecke gebaut wurde
  bool justCreatedCorner = false;

  for (int i = 1; i < rotatedRawPolygon.length; i++) {
    Offset lastValid = sanitizedRotated.last;
    Offset currentRaw = rotatedRawPolygon[i];
    
    double dx = currentRaw.dx - lastValid.dx;
    double dy = currentRaw.dy - lastValid.dy;
    double distance = sqrt(dx * dx + dy * dy);

    // KORREKTUR: Wenn gerade eine Ecke gebaut wurde, MUSS das Folgesegment 
    // ungeachtet der Mindestlänge akzeptiert werden, um die neue Wandlinie zu starten!
    if (distance >= minWallLength || justCreatedCorner) {
      bool newSegmentIsHorizontal = dx.abs() > dy.abs();
      
      if (newSegmentIsHorizontal != isCurrentlyHorizontal) {
        // Echte 90°-Ecke fixieren
        Offset cornerPoint = isCurrentlyHorizontal 
            ? Offset(currentRaw.dx, lastValid.dy)
            : Offset(lastValid.dx, currentRaw.dy);
            
        sanitizedRotated.add(cornerPoint);
        isCurrentlyHorizontal = newSegmentIsHorizontal;
        justCreatedCorner = true; // Flag setzen für die nächste Iteration
        continue;
      }
      
      Offset straightPoint = isCurrentlyHorizontal
          ? Offset(currentRaw.dx, sanitizedRotated.last.dy)
          : Offset(sanitizedRotated.last.dx, currentRaw.dy);
          
      sanitizedRotated.add(straightPoint);
      justCreatedCorner = false; // Zurücksetzen, da wir uns auf einer Geraden bewegen
    }
  }

  if (sanitizedRotated.isNotEmpty && sanitizedRotated.first != sanitizedRotated.last) {
    Offset pPenultimate = sanitizedRotated.last;
    Offset pStart = sanitizedRotated.first;
    Offset finalCorner = isCurrentlyHorizontal 
        ? Offset(pStart.dx, pPenultimate.dy)
        : Offset(pPenultimate.dx, pStart.dy);
        
    sanitizedRotated.add(finalCorner);
    sanitizedRotated.add(pStart);
  }

  // =========================================================================
  // NEU - SCHRITT 3b: KOLLINEARE WAND-KONSOLIDIERUNG (Segment-Verschmelzung)
  // =========================================================================
  List<Offset> consolidatedRotated = [];
  if (sanitizedRotated.length > 3) {
    consolidatedRotated.add(sanitizedRotated.first);
    
    for (int i = 1; i < sanitizedRotated.length - 1; i++) {
      Offset pPrev = consolidatedRotated.last;
      Offset pCurr = sanitizedRotated[i];
      Offset pNext = sanitizedRotated[i + 1];
      
      double dx1 = pCurr.dx - pPrev.dx;
      double dy1 = pCurr.dy - pPrev.dy;
      double dx2 = pNext.dx - pCurr.dx;
      double dy2 = pNext.dy - pCurr.dy;
      
      bool firstIsHorizontal = dx1.abs() > dy1.abs();
      bool secondIsHorizontal = dx2.abs() > dy2.abs();
      
      // Wenn zwei aufeinanderfolgende Wände dieselbe Ausrichtung haben (0° oder 180° Spurt)
      if (firstIsHorizontal == secondIsHorizontal) {
        // Hysterese-Abstandsprüfung (z.B. max 15 cm Abweichung auf der Querachse)
        double laneOffset = firstIsHorizontal ? (pCurr.dy - pPrev.dy).abs() : (pCurr.dx - pPrev.dx).abs();
        
        if (laneOffset < 0.15) {
          // Die Segmente gehören zu einer Wand! Wir überspringen den Knickpunkt pCurr.
          // Dadurch wird die Wand direkt von pPrev bis pNext durchgezogen.
          continue;
        }
      }
      consolidatedRotated.add(pCurr);
    }
    consolidatedRotated.add(sanitizedRotated.last);
  } else {
    consolidatedRotated = List.from(sanitizedRotated);
  }
  
  // Ringschluss für das konsolidierte Polygon absichern
  if (consolidatedRotated.first != consolidatedRotated.last) {
    consolidatedRotated.add(consolidatedRotated.first);
  }
  
  // 4. SCHRITT: IN DEN PHYSISCHEN RAUMWINKEL ZURÜCKDREHEN (Nutzt konsolidierte Punkte)
  double cosR = cos(mainRoomAngle), sinR = sin(mainRoomAngle);
  List<Offset> finalOrthogonalPolygon = consolidatedRotated.map((Offset p) => Offset(
    p.dx * cosR - p.dy * sinR,
    p.dx * sinR + p.dy * cosR,
  )).toList();

  if (finalOrthogonalPolygon.length < 3) return;

    // =========================================================================
  // SCHRITT 5: DYNAMISCHE, ROTATIONSFREIE PROJEKTIONS-MESSUNG (Universell)
  // =========================================================================
  double minXProj = 9999.0;
  double maxXProj = -9999.0;
  double minYProj = 9999.0;
  double maxYProj = -9999.0;

  // Wir projizieren die realen Ecken des finalen Polygons auf die ermittelte Hauptachse.
  // Das eliminiert den Diagonaleffekt vollständig und liefert die echten Hüllmaße 
  // parallel zu den tatsächlichen Wänden – für jeden Raum weltweit.
  double cosProj = cos(-mainRoomAngle);
  double sinProj = sin(-mainRoomAngle);

  for (var p in finalOrthogonalPolygon) {
    double projX = p.dx * cosProj - p.dy * sinProj;
    double projY = p.dx * sinProj + p.dy * cosProj;

    if (projX < minXProj) minXProj = projX;
    if (projX > maxXProj) maxXProj = projX;
    if (projY < minYProj) minYProj = projY;
    if (projY > maxYProj) maxYProj = projY;
  }

  // Die echten, reellen Abmessungen des Raumes parallel zu den Wänden (rein dynamisch)
  double absoluteLength = (maxXProj - minXProj).abs();
  double absoluteWidth = (maxYProj - minYProj).abs();

  // Logische Zuordnung für die UI: Das größere Hüllmaß ist immer die Länge, das kleinere die Breite
  double finalLength = max(absoluteLength, absoluteWidth);
  double finalWidth = min(absoluteLength, absoluteWidth);

  // Echte Fläche über Shoelace-Algorithmus (Bleibt absolut unberührt und dynamisch)
  double calculatedArea = 0.0;
  for (int i = 0; i < finalOrthogonalPolygon.length - 1; i++) {
    calculatedArea += finalOrthogonalPolygon[i].dx * finalOrthogonalPolygon[i + 1].dy -
                      finalOrthogonalPolygon[i + 1].dx * finalOrthogonalPolygon[i].dy;
  }
  calculatedArea = calculatedArea.abs() / 2.0;

  // Zustand rein aus den dynamischen Messdaten an die App übergeben
  setState(() {
    filteredPoints = finalOrthogonalPolygon;
    laenge = finalLength;  
    breite = finalWidth;   
    flaeche = calculatedArea;
  });
}




  List<double> _mergeNearbyLines(List<double> lines, double tolerance) {
    if (lines.length < 2) return List.from(lines);

    final merged = <double>[];
    var cluster = <double>[lines.first];
    for (final line in lines.skip(1)) {
      if ((line - cluster.last).abs() <= tolerance) {
        cluster.add(line);
      } else {
        merged.add(cluster.reduce((a, b) => a + b) / cluster.length);
        cluster = [line];
      }
    }
    merged.add(cluster.reduce((a, b) => a + b) / cluster.length);
    return merged;
  }

  List<double> _selectOuterLines(List<double> lines, int limit) {
    if (lines.length <= limit) return List.from(lines);
    if (limit < 2) return [lines.first];

    final selected = <double>[lines.first];
    final interiorCount = limit - 2;
    for (int i = 1; i <= interiorCount; i++) {
      final index = (i * (lines.length - 1) / (interiorCount + 1)).round();
      selected.add(lines[index]);
    }
    selected.add(lines.last);
    return selected;
  }

  void _startScan() {
    if (connection != null && isConnected) {
      connection!.output.add(utf8.encode("START_SCAN\n"));
      connection!.output.allSent;
    }
  }

  void _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    // Löscht den alten Speicher-Schlüssel komplett von der Festplatte
    await prefs.remove('scans'); 
    
    setState(() {
      _history = []; // Startet die App immer mit einer absolut leeren Sitzungs-Liste
    });
  }

  void _saveToHistory() {
    String name = _roomController.text.isEmpty ? "Unbenannter Raum" : _roomController.text;
    String modeTag = _isStandard4WallMode ? "4W" : "Poly";
    
    // Erzeugt den Eintrag für die temporäre Liste während der Laufzeit
    String entry = "$name ($modeTag)|${laenge.toStringAsFixed(2)}|${breite.toStringAsFixed(2)}|${flaeche.toStringAsFixed(2)}|${DateTime.now().toString().substring(0, 10)}";
    
    setState(() {
      _history.insert(0, entry); // Fügt das Ergebnis der aktuellen Sitzungs-Liste hinzu
    });
  }

  // Generiert die CAD-Textdatei im Industriestandard DXF R12 mit perfektem 90-Grad-Raumschluss
  void _exportAsDXF() async {
    if (filteredPoints.isEmpty) return;

    String name = _roomController.text.isEmpty ? "Aufmass" : _roomController.text;
    final exportPoints = [...rawPoints, ...filteredPoints];
    final exportMinY = exportPoints.map((point) => point.dy).reduce(min);
    final exportMaxY = exportPoints.map((point) => point.dy).reduce(max);

    double exportY(double y) => exportMinY + exportMaxY - y;

    StringBuffer dxf = StringBuffer();
    dxf.write("  0\nSECTION\n  2\nHEADER\n  0\nENDSEC\n");
    dxf.write("  0\nSECTION\n  2\nTABLES\n  0\nTABLE\n  2\nLAYER\n");

    // Erweiterte Palette (1=Rot, 2=Gelb, 3=Grün, 4=Cyan, 5=Blau, 6=Magenta, 7=Weiß/Schwarz, 20=Orange, 30=Hellgrün, 40=Mint, 50=Hellblau, 80=Lila, 150=Dunkelgrün, 210=Pink)
    final List<int> cadColors = List.from({1, 2, 3, 4, 5, 6, 7, 20, 30, 40, 50, 80, 150, 210});

    // =========================================================================
    // STRIKTE TRENNUNG DER LAYER-GENERIERUNG
    // =========================================================================
    if (_isStandard4WallMode) {
      // 4-Wand-Standard-Modus
      dxf.write("  0\nLAYER\n  2\nWAND_01_A_BREITE\n 70\n0\n  62\n1\n"); // Rot
      dxf.write("  0\nLAYER\n  2\nWAND_02_B_LAENGE\n 70\n0\n  62\n5\n"); // Blau
      dxf.write("  0\nLAYER\n  2\nWAND_03_C_BREITE\n 70\n0\n  62\n3\n"); // Grün
      dxf.write("  0\nLAYER\n  2\nWAND_04_D_LAENGE\n 70\n0\n  62\n6\n"); // Magenta
    } else {
      // Polygon-Modus: Generiere Layer mit führenden Nullen
      for (int i = 0; i < filteredPoints.length - 1; i++) {
        int colorCode = cadColors[i % cadColors.length];
        String wallNumberStr = (i + 1).toString().padLeft(2, '0');
        dxf.write("  0\nLAYER\n  2\nWAND_${wallNumberStr}_POLYGON\n 70\n0\n  62\n$colorCode\n");
      }
    }
    
    // Lidar-Hintergrund-Layer (Immer Grau = 8)
    dxf.write("  0\nLAYER\n  2\nLIDAR_ROHDATEN\n 70\n0\n  62\n8\n");
    dxf.write("  0\nENDTAB\n  0\nENDSEC\n  0\nSECTION\n  2\nENTITIES\n");
    // =========================================================================
    // STRIKTE TRENNUNG DER ENTITIES-AUSGABE MIT FÜHRENDEN NULLEN (01, 02...)
    // =========================================================================
    if (_isStandard4WallMode) {
      // 1. Schleife für den 4-Wand-Standard-Modus
      const wallNames = ['A_BREITE', 'B_LAENGE', 'C_BREITE', 'D_LAENGE'];
      final wallMeasurements = [breite, laenge, breite, laenge];

      for (int i = 0; i < filteredPoints.length - 1; i++) {
        Offset p1 = filteredPoints[i];
        Offset p2 = filteredPoints[i + 1];
        
        // Führende Null für die Wandnummer erzeugen (z.B. 01, 02)
        String wallNumberStr = (i + 1).toString().padLeft(2, '0');
        String layerName = 'WAND_${wallNumberStr}_${wallNames[i % 4]}';
        double currentMeasure = wallMeasurements[i % 4];
        
        int measureInCm = (currentMeasure * 100).round();
        String labelText = 'Wand $wallNumberStr - ${wallNames[i % 4]}: ${currentMeasure.toStringAsFixed(2)} m ($measureInCm cm)';

        // Linie auf spezifischen Wand-Layer schreiben
        dxf.write("  0\nLINE\n  8\n$layerName\n"
            " 10\n${p1.dx}\n 20\n${exportY(p1.dy)}\n 30\n0.0\n"
            " 11\n${p2.dx}\n 21\n${exportY(p2.dy)}\n 31\n0.0\n");

        // Beschriftungstext mittig platzieren
        double midpointX = (p1.dx + p2.dx) / 2;
        double midpointY = exportY((p1.dy + p2.dy) / 2);
        dxf.write("  0\nTEXT\n  8\n$layerName\n"
            " 10\n$midpointX\n 20\n$midpointY\n 30\n0.0\n"
            " 40\n0.08\n  1\n$labelText\n");
      }
    } else {
      // 2. Schleife für den Polygon-Modus (Jede Wand auf eigenem Farb-Layer)
      for (int i = 0; i < filteredPoints.length - 1; i++) {
        Offset p1 = filteredPoints[i];
        Offset p2 = filteredPoints[i + 1];
        
        double segmentDistance = sqrt(pow(p2.dx - p1.dx, 2) + pow(p2.dy - p1.dy, 2));
        int segmentInCm = (segmentDistance * 100).round();
        
        // Führende Null für das Polygon-Wandsegment erzeugen (z.B. 01, 02... 10, 11)
        String wallNumberStr = (i + 1).toString().padLeft(2, '0');
        String layerName = 'WAND_${wallNumberStr}_POLYGON';
        String labelText = 'Wand $wallNumberStr - POLYGON: ${segmentDistance.toStringAsFixed(2)} m ($segmentInCm cm)';

        // Linie auf den dynamischen durchnummerierten Layer schreiben
        dxf.write("  0\nLINE\n  8\n$layerName\n"
            " 10\n${p1.dx}\n 20\n${exportY(p1.dy)}\n 30\n0.0\n"
            " 11\n${p2.dx}\n 21\n${exportY(p2.dy)}\n 31\n0.0\n");

        // Beschriftungstext mittig platzieren
        double midpointX = (p1.dx + p2.dx) / 2;
        double midpointY = exportY((p1.dy + p2.dy) / 2);
        dxf.write("  0\nTEXT\n  8\n$layerName\n"
            " 10\n$midpointX\n 20\n$midpointY\n 30\n0.0\n"
            " 40\n0.08\n  1\n$labelText\n");
      }
    }

    // Lidar-Rohdatenpunkte im Hintergrund ausgeben (Unverändert)
    for (final point in rawPoints) {
      dxf.write("  0\nPOINT\n  8\nLIDAR_ROHDATEN\n"
          " 10\n${point.dx}\n 20\n${exportY(point.dy)}\n 30\n0.0\n");
    }

    dxf.write("  0\nENDSEC\n  0\nEOF\n");

    // DXF abspeichern und teilen (Unverändert)
    final bytes = utf8.encode(dxf.toString());
    await Printing.sharePdf(
        bytes: Uint8List.fromList(bytes), filename: '${name}_ortho_plan.dxf');
  }


  // Generiert das PDF-Aufmassblatt inklusive des idealisierten 90-Grad-Grundrisses
  void _shareAsPDF() async {
    final pdf = pw.Document();
    String name = _roomController.text.isEmpty ? "Projekt Aufmass" : _roomController.text;
    List<Offset> planPoints = filteredPoints.isNotEmpty ? filteredPoints : rawPoints;
    List<Offset> allPoints = [...rawPoints, ...planPoints];

    final List<PdfColor> pdfColors = List<PdfColor>.from({
      PdfColors.red,
      PdfColors.yellow,
      PdfColors.green,
      PdfColors.cyan,
      PdfColors.blue,
      PdfColors.pink,
      PdfColors.black,
      PdfColors.orange,
      PdfColors.lime,
      PdfColors.teal,
      PdfColors.lightBlue,
      PdfColors.indigo,
      PdfColors.green700,
      PdfColors.pink300,
    });

    // =========================================================================
    // SEITE 1: STAMMDATEN, GEOMETRISCHE METRIKEN & FIXIERTE SKIZZE
    // =========================================================================
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(30),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _isStandard4WallMode
                    ? "DIGITALES RAUM AUFMASS (4-WAND)"
                    : "DIGITALES RAUM AUFMASS (POLYGON-GEFILTERT)",
                style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
              ),
              pw.Divider(),
              pw.SizedBox(height: 10),
              pw.Text("Raumbezeichnung: $name", style: const pw.TextStyle(fontSize: 14)),
              pw.Text("Datum: ${DateTime.now().toString().substring(0, 10)}", style: const pw.TextStyle(fontSize: 11)),
              pw.SizedBox(height: 15),
              
              // Haupttabelle für globale Metriken
              pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey),
                children: [
                  pw.TableRow(children: [
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("Eigenschaft", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("Gefilterter Messwert (App)", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  ]),
                  pw.TableRow(children: [
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(_isStandard4WallMode ? "Länge (bereinigt)" : "Maximal-Länge (Hüllmaß)")),
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("${laenge.toStringAsFixed(2)} m")),
                  ]),
                  pw.TableRow(children: [
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(_isStandard4WallMode ? "Breite (bereinigt)" : "Maximal-Breite (Hüllmaß)")),
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("${breite.toStringAsFixed(2)} m")),
                  ]),
                  pw.TableRow(children: [
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("Grundfläche", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                    pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text("${flaeche.toStringAsFixed(2)} m²", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                  ]),
                ],
              ),
              pw.SizedBox(height: 20),
              pw.Text("GEOMETRISCHE SKIZZE (90° GRUNDRISS BEREINIGT):", style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              
              // Plan-Container mit FIXIERTER, garantierter Größe (360x360 pt)
              pw.Container(
                height: 360,
                width: double.infinity,
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
                child: pw.Center(
                  child: pw.CustomPaint(
                    size: const PdfPoint(340, 340),
                    painter: (PdfGraphics canvas, PdfPoint size) {
                      if (allPoints.isEmpty) return;
                      double minX = 999, maxX = -999, minY = 999, maxY = -999;
                      for (var p in allPoints) {
                        if (p.dx < minX) minX = p.dx;
                        if (p.dx > maxX) maxX = p.dx;
                        if (p.dy < minY) minY = p.dy;
                        if (p.dy > maxY) maxY = p.dy;
                      }
                      double roomW = maxX - minX;
                      double roomH = maxY - minY;
                      if (roomW == 0) roomW = 1;
                      if (roomH == 0) roomH = 1;
                      
                      double scale = min((size.x - 30) / roomW, (size.y - 30) / roomH);
                      PdfPoint center = PdfPoint(size.x / 2, size.y / 2);
                      PdfPoint roomCenter = PdfPoint(minX + roomW / 2, minY + roomH / 2);
                      
                      // Lidar-Rohdatenpunkte im Hintergrund zeichnen
                      canvas.setFillColor(PdfColors.grey500);
                      for (final point in rawPoints) {
                        double cX = center.x + (point.dx - roomCenter.x) * scale;
                        double cY = center.y - (point.dy - roomCenter.y) * scale;
                        canvas.drawRect(cX - 1.0, cY - 1.0, 2, 2);
                        canvas.fillPath();
                      }
                      
                      // Bereinigte 90°-Wände im Vordergrund zeichnen
                      canvas.setLineWidth(2.5);
                      for (int i = 0; i < planPoints.length - 1; i++) {
                        double cX1 = center.x + (planPoints[i].dx - roomCenter.x) * scale;
                        double cY1 = center.y - (planPoints[i].dy - roomCenter.y) * scale;
                        double cX2 = center.x + (planPoints[i + 1].dx - roomCenter.x) * scale;
                        double cY2 = center.y - (planPoints[i + 1].dy - roomCenter.y) * scale;
                        
                        if (_isStandard4WallMode) {
                          final wallColors = [PdfColors.red, PdfColors.blue, PdfColors.orange, PdfColors.purple];
                          canvas.setStrokeColor(wallColors[i % 4]);
                        } else {
                          canvas.setStrokeColor(pdfColors[i % pdfColors.length]);
                        }
                        
                        canvas.moveTo(cX1, cY1);
                        canvas.lineTo(cX2, cY2);
                        canvas.strokePath();
                      }
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
    // =========================================================================
    // SEITE 2: DYNAMISCHE WAND-LISTE / LEGENDE (MultiPage-sicher)
    // =========================================================================
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(30),
        build: (pw.Context context) {
          return [
            pw.Text(
              "WAND-SPEZIFIKATIONEN / EINZELMASSE:",
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              _isStandard4WallMode 
                  ? "Modus: Orthogonalisiertes 4-Wand-Rechteck." 
                  : "Modus: Multi-Wand-Polygon (90° Hysterese-bereinigt). Anzahl Segmente: ${planPoints.length - 1}",
              style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 15),

            // Generierung der Zeilen je nach Modus
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: _isStandard4WallMode
                  ? [
                      _buildWallLegendRow("Wand 1 - A (Breite)", "${breite.toStringAsFixed(2)} m (${(breite * 100).round()} cm)", PdfColors.red),
                      _buildWallLegendRow("Wand 2 - B (Länge)", "${laenge.toStringAsFixed(2)} m (${(laenge * 100).round()} cm)", PdfColors.blue),
                      _buildWallLegendRow("Wand 3 - C (Breite)", "${breite.toStringAsFixed(2)} m (${(breite * 100).round()} cm)", PdfColors.orange),
                      _buildWallLegendRow("Wand 4 - D (Länge)", "${laenge.toStringAsFixed(2)} m (${(laenge * 100).round()} cm)", PdfColors.purple),
                      _buildWallLegendRow("Lidar-Rohdaten", "${rawPoints.length} Punkte", PdfColors.grey700),
                    ]
                  : [
                      ...List.generate(planPoints.length - 1, (index) {
                        Offset p1 = planPoints[index];
                        Offset p2 = planPoints[index + 1];
                        double segmentDistance = sqrt(pow(p2.dx - p1.dx, 2) + pow(p2.dy - p1.dy, 2));
                        int segmentInCm = (segmentDistance * 100).round();
                        
                        PdfColor activeColor = pdfColors[index % pdfColors.length];
                        return _buildWallLegendRow(
                          "Wand ${(index + 1).toString().padLeft(2, '0')} - POLYGON",
                          "${segmentDistance.toStringAsFixed(2)} m ($segmentInCm cm)", 
                          activeColor
                        );
                      }),
                      _buildWallLegendRow("Lidar-Rohdaten", "${rawPoints.length} Punkte", PdfColors.grey700),
                    ],
            ),
          ];
        },
      ),
    );

    // Speicher- und Teilen-Prozess ausführen
    await Printing.sharePdf(bytes: await pdf.save(), filename: '${name}_aufmass.pdf');
  }


  pw.Widget _buildWallLegendRow(
      String label, String measurement, PdfColor color) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        children: [
          pw.Container(width: 12, height: 12, color: color),
          pw.SizedBox(width: 6),
          pw.Text('$label: $measurement'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Aufmaß-Scanner V1.5'),
          backgroundColor: Colors.blueGrey),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              Card(
                color: Colors.blueGrey.withOpacity(0.2),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      Text(statusMessage,
                          style: TextStyle(
                              color: isConnected ? Colors.green : Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                      const SizedBox(height: 15),
                      TextField(
                        controller: _roomController,
                        decoration: const InputDecoration(
                            labelText: 'Raum-Bezeichnung (z.B. Küche EG)',
                            border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 15),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text("4-Wand Standard"),
                              selected: _isStandard4WallMode,
                              onSelected: (selected) {
                                if (!selected) return;
                                setState(() => _isStandard4WallMode = true);
                                if (rawPoints.isNotEmpty) {
                                  _applyOrthogonalBoxFilter();
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text("Polygone Wände"),
                              selected: !_isStandard4WallMode,
                              onSelected: (selected) {
                                if (!selected) return;
                                setState(() => _isStandard4WallMode = false);
                                if (rawPoints.isNotEmpty) {
                                  _applyPolygonFilter();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      
                      // Der bedingte Hysterese-Block (Öffnet sich nur im Polygon-Modus)
                      if (!_isStandard4WallMode) ...[
                        const SizedBox(height: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text("Kantenglättung / Hysterese:", style: TextStyle(fontSize: 13, color: Colors.grey)),
                                Text("${(userTolerance * 100).toStringAsFixed(0)} cm", 
                                     style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 14)),
                              ],
                            ),
                            Slider(
                              value: userTolerance,
                              min: 0.05,  
                              max: 0.60,  
                              divisions: 11,
                              activeColor: Colors.orange,
                              inactiveColor: Colors.grey.withOpacity(0.3),
                              onChanged: (double newValue) {
                                setState(() {
                                  userTolerance = newValue;
                                  if (rawPoints.isNotEmpty) {
                                    _applyUniversalPolygonSanitization();
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ],
                      
                      const SizedBox(height: 15),
                      Container(
                        height: 220,
                        width: double.infinity,
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: CustomPaint(
                            painter: PlanPainter(
                                points: filteredPoints.isNotEmpty
                                    ? filteredPoints
                                    : rawPoints,
                                rawPoints: rawPoints,
                                isPolygonMode: !_isStandard4WallMode),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildValueTile(
                              "Länge", "${laenge.toStringAsFixed(2)} m"),
                          _buildValueTile(
                              "Breite", "${breite.toStringAsFixed(2)} m"),
                          _buildValueTile(
                              "Fläche", "${flaeche.toStringAsFixed(2)} m²",
                              color: Colors.green),
                        ],
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed:
                            isConnected && !isScanning ? _startScan : null,
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00E676),
                            minimumSize: const Size.fromHeight(50)),
                        child: const Text("MESSUNG STARTEN",
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: flaeche > 0 ? _shareAsPDF : null,
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.lightBlue),
                              child: const Text("PDF EXPORT",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: filteredPoints.isNotEmpty
                                  ? _exportAsDXF
                                  : null,
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange),
                              child: const Text("DXF PLAN EXPORT",
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Align(
                  alignment: Alignment.centerLeft,
                  child: Text("PROJEKT-VERLAUF",
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold))),
              const SizedBox(height: 10),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _history.length,
                itemBuilder: (context, index) {
                  List<String> hParts = _history[index].split('|');
                  return Card(
                    color: Colors.blueGrey.withOpacity(0.1),
                    child: ListTile(
                      title: Text(hParts.first,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("Datum: ${hParts.last}"),
                      trailing: Text(
                          "${hParts.elementAt(1)}m x ${hParts.elementAt(2)}m = ${hParts.elementAt(3)}m²",
                          style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold)),
                    ),
                  );
                },
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildValueTile(String label, String value, {Color? color}) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color ?? Colors.white)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}

class PlanPainter extends CustomPainter {
  final List<Offset> points;
  final List<Offset> rawPoints;
  final bool isPolygonMode;

  PlanPainter({
    required this.points,
    this.rawPoints = const [],
    this.isPolygonMode = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final allPoints = [...rawPoints, ...points];
    if (allPoints.isEmpty) {
      final textPainter = TextPainter(
        text: const TextSpan(
            text: "Keine Plandaten vorhanden\n(Messung starten)",
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
          canvas,
          Offset((size.width - textPainter.width) / 2,
              (size.height - textPainter.height) / 2));
      return;
    }

    double minX = 999, maxX = -999, minY = 999, maxY = -999;
    for (var p in allPoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    double roomW = maxX - minX;
    double roomH = maxY - minY;
    if (roomW == 0) roomW = 1;
    if (roomH == 0) roomH = 1;

    double scale = min((size.width - 40) / roomW, (size.height - 40) / roomH);
    Offset center = Offset(size.width / 2, size.height / 2);
    Offset roomCenter = Offset(minX + roomW / 2, minY + roomH / 2);

    final rawPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.55)
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    for (final point in rawPoints) {
      canvas.drawPoints(
          PointMode.points, [center + (point - roomCenter) * scale], rawPaint);
    }

    final wallPaint = Paint()
      ..color = isPolygonMode ? Colors.orange : const Color(0xFF00E676)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < points.length - 1; i++) {
      Offset p1 = points[i];
      Offset p2 = points[i + 1];

      Offset screenP1 = center + (p1 - roomCenter) * scale;
      Offset screenP2 = center + (p2 - roomCenter) * scale;

      canvas.drawLine(screenP1, screenP2, wallPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PlanPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.rawPoints != rawPoints ||
      oldDelegate.isPolygonMode != isPolygonMode;
}

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

    double scale =
        min((size.width - 40) / roomWidth, (size.height - 40) / roomHeight);
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
      path.moveTo(filteredPoints.first.dx * scale + center.dx,
          filteredPoints.first.dy * scale + center.dy);

      for (int i = 1; i < filteredPoints.length; i++) {
        path.lineTo(filteredPoints[i].dx * scale + center.dx,
            filteredPoints[i].dy * scale + center.dy);
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
