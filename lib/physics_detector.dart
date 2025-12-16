import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

class PhysicsMovementDetector {
  // Limiar de variância para considerar que o dispositivo está em uma "mão humana".
  // Valores abaixo disso indicam que o dispositivo está em um suporte fixo, mesa ou é um emulador.
  // Uma mão humana tentando ficar parada geralmente gera > 0.05 de variância.
  static const double _minHumanVariance = 0.02;

  // Se o GPS diz que está andando (mesmo devagar, tipo 1.5 km/h ~ 0.4 m/s),
  // o acelerômetro PRECISA registrar o balanço do passo.
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

            // Janela de análise: ~2 segundos de dados (assumindo ~16 leituras/seg em UI interval)
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

  /// Retorna TRUE se detectarmos que o usuário está usando um Joystick para "caminhar".
  /// Lógica: GPS diz que move (> 0.4 m/s) MAS Acelerômetro diz que está estático (Mesa/Tripé).
  bool isJoystickWalk(double gpsSpeedMetersPerSecond) {
    if (_accelerometerReadings.length < 10) return false; // Dados insuficientes

    // 1. Calcular a Variância (O quanto o celular está chacoalhando)
    double variance = _lastCalculatedVariance;

    // 2. Análise de Fraude de "Caminhada Falsa"
    // O GPS diz que o usuário está andando (ex: simulando ir até o local da biometria)
    if (gpsSpeedMetersPerSecond > _minGpsWalkingSpeed) {
      // Mas o celular está estável demais (Mesa/Suporte)
      if (variance < _minHumanVariance) {
        print(
          "ALERTA: Joystick Walk! GPS Speed: $gpsSpeedMetersPerSecond m/s, Variância Sensor: ${variance.toStringAsFixed(5)}",
        );
        return true;
      }
    }
    return false;
  }

  /// Retorna TRUE se o dispositivo estiver "morto" (estabilidade mecânica perfeita).
  /// Útil para saber se é um emulador ou se o usuário largou o celular na mesa para enganar.
  bool isMechanicallyStable() {
    if (_accelerometerReadings.length < 10) return false;
    double variance = _calculateVariance(_accelerometerReadings);

    // Variância extremamente baixa (< 0.005) é quase impossível na mão.
    return variance < 0.005;
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
