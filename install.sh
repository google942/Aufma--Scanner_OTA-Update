#!/bin/bash

# 1. Pakete in die pubspec.yaml schreiben
cat << 'EOF' > pubspec.yaml
name: aufmass_scanner
description: A new Flutter project.
publish_to: 'none'
version: 1.0.0+1
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  flutter_bluetooth_serial: any
  shared_preferences: ^2.2.0
  pdf: ^3.10.0
  printing: ^5.11.0
dev_dependencies:
  flutter_test:
    sdk: flutter
flutter:
  uses-material-design: true
EOF

# 2. App-Code in die main.dart schreiben
cat << 'EOF' > lib/main.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
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

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _autoConnect();
  }

  void _autoConnect() async {
    try {
      List<BluetoothDevice> devices = await FlutterBluetoothSerial.instance.getBondedDevices();
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
          connection!.input!.listen(_onDataReceived).onDone(() {
            setState(() {
              isConnected = false;
              statusMessage = "Verbindung verloren";
            });
          });
        });
      } else {
        setState(() => statusMessage = "Gerät nicht gekoppelt (BT-Menü prüfen)");
      }
    } catch (e) {
      setState(() => statusMessage = "Verbindungsfehler");
    }
  }

  void _onDataReceived(Uint8List data) {
    String msg = utf8.decode(data).trim();
    if (msg == "STATUS:SCANNING") {
      setState(() {
        isScanning = true;
        statusMessage = "SCAN LÄUFT...";
      });
    } else if (msg.startsWith("RESULT:")) {
      List<String> parts = msg.substring(7).split(',');
      if (parts.length == 3) {
        setState(() {
          isScanning = false;
          laenge = double.parse(parts[0]);
          breite = double.parse(parts[1]);
          flaeche = double.parse(parts[2]);
          statusMessage = "MESSUNG FERTIG";
        });
        _saveToHistory();
      }
    }
  }

  void _startScan() {
    if (connection != null && isConnected) {
      connection!.output.add(utf8.encode("START_SCAN\n"));
      connection!.output.allSent;
    }
  }

  void _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _history = prefs.getStringList('scans') ?? []);
  }

  void _saveToHistory() async {
    final prefs = await SharedPreferences.getInstance();
    String name = _roomController.text.isEmpty ? "Unbenannter Raum" : _roomController.text;
    String entry = "$name|${laenge.toStringAsFixed(2)}|${breite.toStringAsFixed(2)}|${flaeche.toStringAsFixed(2)}|${DateTime.now().toString().substring(0, 10)}";
    _history.insert(0, entry);
    await prefs.setStringList('scans', _history);
    setState(() {});
  }

  void _shareAsPDF() async {
    final pdf = pw.Document();
    String name = _roomController.text.isEmpty ? "Projekt-Aufmaß" : _roomController.text;
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Padding(
            padding: const pw.EdgeInsets.all(30),
            child: pw.Column(
              cross: pw.CrossAxisAlignment.start,
              children: [
                pw.Text("DIGITALES RAUM-AUFMAẞ", style: pw.TextStyle(fontSize: 26, fontWeight: pw.FontWeight.bold)),
                pw.Divider(),
                pw.SizedBox(height: 20),
                pw.Text("Raumbezeichnung: $name", style: const pw.TextStyle(fontSize: 18)),
                pw.Text("Datum: ${DateTime.now().toString().substring(0, 10)}", style: const pw.TextStyle(fontSize: 14)),
                pw.SizedBox(height: 30),
                pw.Table(
                  border: pw.TableBorder.all(),
                  children: [
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("Eigenschaft", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("Messwert", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("Länge")),
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("${laenge.toStringAsFixed(2)} m")),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("Breite")),
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("${breite.toStringAsFixed(2)} m")),
                    ]),
                    pw.TableRow(children: [
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("Grundfläche", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                      pw.Padding(padding: const pw.EdgeInsets.all(10), child: pw.Text("${flaeche.toStringAsFixed(2)} m²", style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
                    ]),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
    await Printing.sharePdf(bytes: await pdf.save(), filename: '${name}_aufmass.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Aufmaß-Scanner Pro v1.0'), backgroundColor: Colors.blueGrey),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              Card(
                color: Colors.blueGrey.withOpacity(0.2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    children: [
                      Text(statusMessage, style: TextStyle(color: isConnected ? Colors.green : Colors.orange, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 15),
                      TextField(
                        controller: _roomController,
                        decoration: const InputDecoration(labelText: 'Raum-Bezeichnung (z.B. Küche EG)', border: OutlineInputBorder()),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildValueTile("Länge", "${laenge.toStringAsFixed(2)} m"),
                          _buildValueTile("Breite", "${breite.toStringAsFixed(2)} m"),
                          _buildValueTile("Fläche", "${flaeche.toStringAsFixed(2)} m²", color: Colors.green),
                        ],
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: isConnected && !isScanning ? _startScan : null,
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), minimumSize: const Size.fromHeight(50)),
                        child: const Text("MESSUNG STARTEN", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: flaeche > 0 ? _shareAsPDF : null,
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.lightBlue, minimumSize: const Size.fromHeight(50)),
                        child: const Text("ALS PDF SPEICHERN / TEILEN", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Align(alignment: Alignment.centerLeft, child: Text("PROJEKT-VERLAUF", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
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
                      title: Text(hParts, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("Datum: ${hParts}"),
                      trailing: Text("${hParts}m x ${hParts}m = ${hParts}m²", style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color ?? Colors.white)),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
EOF

# 3. Den Namespace-Fehler im Bluetooth-Modul patchen
printf "\nsubprojects { subproject -> if (subproject.name == 'flutter_bluetooth_serial') { subproject.evaluationDependsOn(':app') } }" >> android/build.gradle

# 4. Den finalen Android-Kompiliervorgang starten
/workspaces/codespaces-blank/flutter/bin/flutter build apk --release --target-platform android-arm64
