import 'package:flutter/material.dart';

/// HSV color wheel dialog for picking colors.
class ColorWheelDialog extends StatefulWidget {
  const ColorWheelDialog({
    super.key,
    required this.initialColor,
    required this.onColorPicked,
  });

  final Color initialColor;
  final ValueChanged<Color> onColorPicked;

  @override
  State<ColorWheelDialog> createState() => _ColorWheelDialogState();
}

class _ColorWheelDialogState extends State<ColorWheelDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();

    return AlertDialog(
      title: const Text('Pick a Color'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Color preview
            Container(
              height: 40,
              width: double.infinity,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(height: 16),

            // Hue slider
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Hue')),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 12,
                      activeTrackColor:
                          HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                      inactiveTrackColor: Colors.white24,
                    ),
                    child: Slider(
                      value: _hsv.hue,
                      min: 0,
                      max: 360,
                      onChanged: (v) => setState(() {
                        _hsv = _hsv.withHue(v);
                      }),
                    ),
                  ),
                ),
              ],
            ),

            // Saturation slider
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Saturation')),
                Expanded(
                  child: Slider(
                    value: _hsv.saturation,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() {
                      _hsv = _hsv.withSaturation(v);
                    }),
                  ),
                ),
              ],
            ),

            // Value/brightness slider
            Row(
              children: [
                const SizedBox(width: 60, child: Text('Brightness')),
                Expanded(
                  child: Slider(
                    value: _hsv.value,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() {
                      _hsv = _hsv.withValue(v);
                    }),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Quick presets row
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _quickColor(Colors.black),
                _quickColor(Colors.white),
                _quickColor(Colors.red),
                _quickColor(Colors.blue),
                _quickColor(Colors.green),
                _quickColor(Colors.yellow),
                _quickColor(Colors.orange),
                _quickColor(Colors.purple),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            widget.onColorPicked(color);
            Navigator.pop(context);
          },
          child: const Text('Select'),
        ),
      ],
    );
  }

  Widget _quickColor(Color c) {
    return GestureDetector(
      onTap: () => setState(() => _hsv = HSVColor.fromColor(c)),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white38, width: 1),
        ),
      ),
    );
  }
}
