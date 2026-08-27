import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial_ble/flutter_bluetooth_serial_ble.dart';

class BluetoothScannerManager {
  BluetoothConnection? _connection;
  bool isConnected = false;
  String _incomingBuffer = "";

  // Callbacks an die UI
  final Function(String message, bool scanning, bool connected) onStatusChanged;
  final Function(Offset point) onPointReceived;
  final VoidCallback onScanFinished;

  BluetoothScannerManager({
    required this.onStatusChanged,
    required this.onPointReceived,
    required this.onScanFinished,
  });

  /// Sucht im Bluetooth-Speicher nach der Hardware und koppelt vollautomatisch
  void autoConnect() async {
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
        onStatusChanged("Verbinde mit Hardware...", false, false);
        BluetoothConnection.toAddress(targetDevice.address).then((conn) {
          _connection = conn;
          isConnected = true;
          onStatusChanged("VERBUNDEN (Bereit)", false, true);

          _connection!.input!.listen(_onDataChunkReceived).onDone(() {
            isConnected = false;
            onStatusChanged("Verbindung verloren", false, false);
          });
        }).catchError((e) {
          onStatusChanged("Verbindungsfehler", false, false);
        });
      } else {
        onStatusChanged("Scanner nicht gekoppelt (BT Menü prüfen)", false, false);
      }
    } catch (e) {
      onStatusChanged("Verbindungsfehler", false, false);
    }
  }

  void _onDataChunkReceived(Uint8List data) {
    _incomingBuffer += utf8.decode(data);
    while (_incomingBuffer.contains('\n')) {
      int lineEnd = _incomingBuffer.indexOf('\n');
      String line = _incomingBuffer.substring(0, lineEnd).trim();
      _incomingBuffer = _incomingBuffer.substring(lineEnd + 1);
      _parseProtocolLine(line);
    }
  }

    void _parseProtocolLine(String line) {
    if (line == "STATUS:SCANNING") {
      onStatusChanged("SCAN LÄUFT...", true, true);
    } 
    // NEU HINZUGEFÜGT/ANGEPASST: Der ESP32 beendet die Übertragung mit "RESULT:"
    else if (line == "STATUS:FINISHED" || line.startsWith("RESULT:")) {
      // Schaltet isScanning auf false und gibt die Benutzeroberfläche frei
      onStatusChanged("MESSUNG FERTIG", false, true); 
      onScanFinished();
    } else if (line.startsWith("P:")) {
      try {
        List<String> coords = line.substring(2).split(',');
        if (coords.length == 2) {
          double x = double.parse(coords.first) / 1000.0;
          double y = double.parse(coords.last) / 1000.0;
          
          if (sqrt(x * x + y * y) > 0.45) {
            onPointReceived(Offset(x, y));
          }
        }
      } catch (_) {}
    }
  }



  /// Sendet das Startsignal an die Hardware
  bool startHardwareScan() {
    if (_connection != null && isConnected) {
      _connection!.output.add(utf8.encode("START_SCAN\n"));
      _connection!.output.allSent;
      return true; // Signal gesendet
    }
    return false; // Keine Hardware da -> UI wechselt in Simulation
  }

  /// Schließt die Verbindung beim Beenden der App
  void dispose() {
    _connection?.dispose();
  }
}
