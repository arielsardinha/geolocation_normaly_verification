import 'package:geolocator/geolocator.dart';

enum LocationAnomalyType {
  none,
  altitudeZero,
  teleportation,
  artificialStatic,
  staticAccuracy,
}

class LocationAnomalyDetector {
  /// Limite máximo de velocidade (200 m/s = 720 km/h).
  /// * Usado para detectar "Teletransporte". Se a distância entre duas atualizações
  /// dividida pelo tempo decorrido resultar em uma velocidade superior a essa,
  /// assumimos que é fisicamente impossível e, portanto, uma fraude (o usuário
  /// saltou de um local para outro instantaneamente).
  static const double _maxSpeedMetersPerSecond = 200.0;

  /// Limite de atualizações com coordenadas EXATAMENTE idênticas (Lat/Long).
  /// * Usado para detectar "GPS Estático Artificial". O hardware de GPS real possui
  /// um "ruído" natural (jitter); mesmo parado, as últimas casas decimais flutuam.
  /// Apps de Fake GPS mal configurados enviam a mesma coordenada repetidamente.
  /// Se repetirmos a mesma posição 5 vezes seguidas, consideramos suspeito.
  static const int _maxIdenticalUpdates = 5;

  /// Limite de atualizações com valor de precisão (Accuracy) idêntico.
  /// * Usado para detectar "Precisão Congelada". Assim como a posição, a precisão
  /// do sinal (ex: 12.4m, 5.1m) flutua constantemente no mundo real.
  /// Ferramentas de Mock costumam fixar esse valor (ex: 5.0m) permanentemente.
  /// Se a precisão não variar por 8 leituras seguidas, é um forte indício de emulação.
  static const int _maxIdenticalAccuracy = 8;

  Position? _lastPosition;
  int _identicalCoordinateCount = 0;
  int _identicalAccuracyCount = 0;

  /// Analisa a nova posição recebida em busca de padrões anômalos que indicam fraude (Mock Location).
  ///
  /// Retorna [LocationAnomalyType.none] se a posição parecer legítima, ou o tipo de fraude detectada.
  LocationAnomalyType analyze(Position newPosition) {
    // 1. ANÁLISE DE ALTITUDE ZERO
    // Muitos emuladores e apps de Fake GPS simples não simulam a altitude, enviando 0.0.
    // Embora possível ao nível do mar, é estatisticamente raro ser exato 0.000000.
    // Nota: Em dispositivos sem barômetro, isso pode gerar falsos positivos, use com cautela.
    if (newPosition.altitude == 0.0) {
      return LocationAnomalyType.altitudeZero;
    }

    // Só podemos analisar anomalias de movimento/comportamento se tivermos um histórico (última posição).
    if (_lastPosition != null) {
      // 2. ANÁLISE DE PRECISÃO CONGELADA (Static Accuracy)
      // O GPS real sofre interferência atmosférica constante, fazendo a precisão (accuracy)
      // flutuar levemente (ex: 5.1m -> 5.3m -> 4.9m), mesmo parado.
      // Ferramentas de fraude costumam fixar esse valor (ex: 5.0m cravados) para todas as leituras.
      if (newPosition.accuracy == _lastPosition!.accuracy) {
        _identicalAccuracyCount++;

        // Se a precisão for idêntica por muitas vezes seguidas (definido em _maxIdenticalAccuracy),
        // assumimos que é uma simulação artificial.
        if (_identicalAccuracyCount >= _maxIdenticalAccuracy) {
          _identicalAccuracyCount = 0; // Reset para evitar spam de alertas
          return LocationAnomalyType.staticAccuracy;
        }
      } else {
        // Se houve variação natural, resetamos o contador. O comportamento é legítimo.
        _identicalAccuracyCount = 0;
      }

      // Cálculo da distância física (em metros) entre o ponto anterior e o atual.
      final double distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      // Cálculo do tempo decorrido (em segundos) entre as duas leituras.
      final int timeDeltaSeconds = newPosition.timestamp
          .difference(_lastPosition!.timestamp)
          .inSeconds;

      // 3. ANÁLISE DE TELETRANSPORTE (Impossible Speed)
      // Evita divisão por zero.
      if (timeDeltaSeconds > 0) {
        final double speed = distance / timeDeltaSeconds;

        // Se a velocidade calculada for maior que o limite físico humanamente possível
        // (definido em _maxSpeedMetersPerSecond, ex: 720km/h), o usuário "saltou" de lugar.
        if (speed > _maxSpeedMetersPerSecond) {
          return LocationAnomalyType.teleportation;
        }
      }

      // 4. ANÁLISE DE GPS ESTÁTICO ARTIFICIAL (No Jitter)
      // O hardware de GPS real possui um "ruído" (jitter) natural. Mesmo com o celular
      // parado em cima da mesa, as coordenadas variam nas últimas casas decimais.
      // Se as coordenadas (Lat/Long) forem EXATAMENTE iguais às anteriores repetidas vezes,
      // é um forte indício de que um software está injetando valores constantes.
      if (_lastPosition!.latitude == newPosition.latitude &&
          _lastPosition!.longitude == newPosition.longitude) {
        _identicalCoordinateCount++;

        if (_identicalCoordinateCount >= _maxIdenticalUpdates) {
          return LocationAnomalyType.artificialStatic;
        }
      } else {
        _identicalCoordinateCount = 0;
      }
    }

    // Atualiza o estado para a próxima análise.
    _lastPosition = newPosition;

    // Nenhuma anomalia detectada.
    return LocationAnomalyType.none;
  }

  void reset() {
    _lastPosition = null;
    _identicalCoordinateCount = 0;
    _identicalAccuracyCount = 0;
  }
}
