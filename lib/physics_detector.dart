// physics_detector.dart
import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class PhysicsMovementDetector {
  // Limiar de movimento do acelerômetro.
  // < 0.5: Repouso absoluto (Mesa)
  // > 1.0: Movimento leve (Mão/Carro)
  static const double _minMovementThreshold = 1.0;

  // Se o GPS diz que está acima dessa velocidade (m/s), exigimos movimento físico.
  // 3 m/s = ~11 km/h.
  static const double _minGpsSpeedForCheck = 3.0;

  final List<double> _accelerometerReadings = [];
  StreamSubscription? _sensorSubscription;

  void start() {
    _accelerometerReadings.clear();
    _sensorSubscription =
        userAccelerometerEventStream(
          samplingPeriod: SensorInterval.normalInterval,
        ).listen(
          (UserAccelerometerEvent event) {
            // Calculamos a magnitude do vetor de aceleração (X, Y, Z)
            final double magnitude = sqrt(
              pow(event.x, 2) + pow(event.y, 2) + pow(event.z, 2),
            );
            _accelerometerReadings.add(magnitude);

            // Mantemos apenas as últimas leituras para economizar memória (janela deslizante)
            if (_accelerometerReadings.length > 100) {
              _accelerometerReadings.removeAt(0);
            }
          },
          onError: (e) {
            // Tratamento para dispositivos que não tenham acelerômetro (raro, mas possível)
            print("Erro no sensor de aceleração: $e");
          },
          cancelOnError: true,
        );
  }

  /// Retorna TRUE se houver uma inconsistência física (GPS diz que move, Sensor diz que para).
  bool isPhysicallyImpossible(double gpsSpeedMetersPerSecond) {
    // Se o GPS diz que estamos parados ou lentos, ignoramos.
    if (gpsSpeedMetersPerSecond < _minGpsSpeedForCheck) {
      return false;
    }

    if (_accelerometerReadings.isEmpty) return false;

    // Calcular a média de movimento físico recente
    double totalAcceleration = _accelerometerReadings.reduce((a, b) => a + b);
    double averageAcceleration =
        totalAcceleration / _accelerometerReadings.length;

    // A MÁGICA:
    // GPS rápido (>11km/h) + Acelerômetro Quieto (<1.0) = Fake GPS Joystick
    if (averageAcceleration < _minMovementThreshold) {
      print(
        "ALERTA FÍSICO: Velocidade GPS: $gpsSpeedMetersPerSecond m/s, mas Aceleração média: $averageAcceleration",
      );
      return true;
    }

    return false;
  }

  void stop() {
    _sensorSubscription?.cancel();
    _accelerometerReadings.clear();
  }
}
