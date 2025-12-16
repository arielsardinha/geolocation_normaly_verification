import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class PhysicsMovementDetector {
  // Limiar de variância para considerar que o dispositivo está em uma "mão humana".
  // Valores abaixo disso indicam que o dispositivo está em um suporte fixo, mesa ou é um emulador.
  // Testes mostraram que uma mão humana firme varia entre 0.003 e 0.1.
  // Definimos 0.002 como margem de segurança mínima.
  static const double _minHumanVariance = 0.001;

  // Limiar para considerar que o dispositivo está mecanicamente travado (Emulador/Mesa Perfeita).
  // Deve ser menor que a variância humana mínima (0.02).
  static const double _minWalkingVariance = 0.02;

  // Velocidade mínima para considerar caminhada (GPS)
  static const double _minGpsWalkingSpeed = 0.4;

  final List<double> _accelerometerReadings = [];
  StreamSubscription? _sensorSubscription;

  double _lastCalculatedVariance = 0.0;
  double get currentVariance => _lastCalculatedVariance;

  void start() {
    _accelerometerReadings.clear();
    // Usamos 'gameInterval' (20ms) ou 'uiInterval' (60ms) para capturar micro-tremores.
    // 'normalInterval' pode ser muito lento para detectar tremor de mão.
    _sensorSubscription =
        userAccelerometerEventStream(
          samplingPeriod: SensorInterval.uiInterval,
        ).listen(
          (UserAccelerometerEvent event) {
            // Magnitude da aceleração (removendo gravidade, pois é UserAccelerometer)
            final double magnitude = sqrt(
              pow(event.x, 2) + pow(event.y, 2) + pow(event.z, 2),
            );
            _accelerometerReadings.add(magnitude);

            // Janela de análise: ~3 segundos de dados (50 amostras a ~60ms)
            if (_accelerometerReadings.length > 50) {
              _accelerometerReadings.removeAt(0);
            }

            if (_accelerometerReadings.length > 10) {
              _lastCalculatedVariance = _calculateVariance(
                _accelerometerReadings,
              );
            }
          },
          onError: (e) => print("Erro sensor: $e"),
          cancelOnError: false,
        );
  }

  /// Retorna TRUE se for fraude de CAMINHADA (Joystick).
  /// GPS: Movendo | Sensor: Muito estático (Mão parada ou mesa)
  bool isJoystickWalk(double gpsSpeedMetersPerSecond) {
    if (_accelerometerReadings.length < 10) return false;

    if (gpsSpeedMetersPerSecond > _minGpsWalkingSpeed) {
      // Exige variância de caminhada (0.02)
      if (_lastCalculatedVariance < _minWalkingVariance) {
        return true;
      }
    }
    return false;
  }

  /// Retorna TRUE se o dispositivo estiver "morto" (estabilidade mecânica perfeita).
  /// Útil para saber se é um emulador ou se o usuário largou o celular na mesa para enganar.
  bool isStaticFake(double gpsSpeedMetersPerSecond) {
    if (_accelerometerReadings.length < 10) return false;

    // Se o usuário está teoricamente parado (fazendo a biometria)
    if (gpsSpeedMetersPerSecond <= _minGpsWalkingSpeed) {
      // O sensor precisa mostrar pelo menos o tremor vital humano (0.001)
      // Se for menor, ele não está segurando o celular (está na mesa/tripé).
      if (_lastCalculatedVariance < _minHumanVariance) {
        return true;
      }
    }
    return false;
  }

  double _calculateVariance(List<double> values) {
    if (values.isEmpty) return 0.0;
    final double mean = values.reduce((a, b) => a + b) / values.length;
    final double sumSquaredDiff = values.fold(
      0.0,
      (sum, val) => sum + pow(val - mean, 2),
    );
    return sumSquaredDiff / values.length;
  }

  void stop() {
    _sensorSubscription?.cancel();
    _accelerometerReadings.clear();
    _lastCalculatedVariance = 0.0;
  }
}
