// lib/main.dart
import 'package:flutter/material.dart';
import 'main_screen.dart'; // Importiert die ausgelagerte UI

void main() {
  runApp(const AufmassScannerApp());
}

class AufmassScannerApp extends StatelessWidget {
  const AufmassScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP32 Aufmaß Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const MainScreen(), // Startet direkt Deinen Hauptbildschirm
    );
  }
}
