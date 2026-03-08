import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/eraser_mode.dart';

void main() {
  group('EraserMode', () {
    test('has 2 modes', () {
      expect(EraserMode.values.length, equals(2));
    });

    test('standard has correct label', () {
      expect(EraserMode.standard.label, equals('Standard'));
    });

    test('history has correct label', () {
      expect(EraserMode.history.label, equals('History'));
    });
  });
}
