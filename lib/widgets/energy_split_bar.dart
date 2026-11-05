// v0.2.26+225: полоса разделения энергии — общая для карточки истории
// (EnergySplitCard в trip_detail.dart) и живой строки на экране вождения
// (TripMetricsPanel в driver_panels.dart). Цвета частей заданы здесь
// одни на оба экрана. Доли считает energySplitShares
// (energy_split_service.dart); здесь только показ.

import 'package:flutter/material.dart';

class EnergySplitBar extends StatelessWidget {
  static const Color motionColor = Colors.lightBlueAccent;
  static const Color climateColor = Colors.orangeAccent;
  static const Color otherColor = Colors.grey;

  final ({double motion, double climate, double other}) shares;
  final double height;
  const EnergySplitBar({super.key, required this.shares, this.height = 10});

  @override
  Widget build(BuildContext context) {
    // «Прочее» может быть отрицательным (модель не обрезает остаток):
    // полоса рисует только положительные части.
    final parts = <(double, Color)>[
      (shares.motion, motionColor),
      (shares.climate, climateColor),
      (shares.other, otherColor),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (final p in parts)
            if (p.$1 > 0)
              Expanded(
                flex: (p.$1 * 1000).round().clamp(1, 1000),
                child: Container(color: p.$2),
              ),
        ]),
      ),
    );
  }
}
