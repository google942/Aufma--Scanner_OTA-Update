// lib/widgets/expert_panel.dart
import 'package:flutter/material.dart';

class ExpertPanel extends StatelessWidget {
  final int maxWalls;
  final double clusterTolerance;
  final ValueChanged<int> onMaxWallsChanged;
  final ValueChanged<double> onToleranceChanged;

  const ExpertPanel({
    super.key,
    required this.maxWalls,
    required this.clusterTolerance,
    required this.onMaxWallsChanged,
    required this.onToleranceChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.construction, color: Colors.blue, size: 18),
              SizedBox(width: 8),
              Text('Filter-Feineinstellung (Live)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          Text('Maximale Wandanzahl (N): $maxWalls', style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Slider(
            value: maxWalls.toDouble(),
            min: 4,
            max: 10,
            divisions: 6,
            label: maxWalls.toString(),
            onChanged: (val) => onMaxWallsChanged(val.toInt()),
          ),
          Text('Möbel-Filtertoleranz: ${(clusterTolerance * 100).toStringAsFixed(0)} cm', style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Slider(
            value: clusterTolerance,
            min: 0.05,
            max: 0.35,
            divisions: 6,
            label: "${(clusterTolerance * 100).toStringAsFixed(0)} cm",
            onChanged: (val) => onToleranceChanged(val),
          ),
        ],
      ),
    );
  }
}
