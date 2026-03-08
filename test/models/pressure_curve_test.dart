import 'package:flutter_test/flutter_test.dart';
import 'package:industrial_sketchbook/models/pressure_curve.dart';

void main() {
  group('PressureCurve', () {
    test('has 4 presets', () {
      expect(PressureCurve.values.length, equals(4));
    });

    test('linear has exponent 1.0', () {
      expect(PressureCurve.linear.exponent, equals(1.0));
      expect(PressureCurve.linear.label, equals('Linear'));
    });

    test('light has exponent 1.4', () {
      expect(PressureCurve.light.exponent, equals(1.4));
      expect(PressureCurve.light.label, equals('Light'));
    });

    test('natural has exponent 1.8 (backward compatible with Phase 2.6)', () {
      expect(PressureCurve.natural.exponent, equals(1.8));
      expect(PressureCurve.natural.label, equals('Natural'));
    });

    test('heavy has exponent 2.5', () {
      expect(PressureCurve.heavy.exponent, equals(2.5));
      expect(PressureCurve.heavy.label, equals('Heavy'));
    });

    test('exponents increase across presets', () {
      expect(PressureCurve.linear.exponent,
          lessThan(PressureCurve.light.exponent));
      expect(PressureCurve.light.exponent,
          lessThan(PressureCurve.natural.exponent));
      expect(PressureCurve.natural.exponent,
          lessThan(PressureCurve.heavy.exponent));
    });
  });
}
