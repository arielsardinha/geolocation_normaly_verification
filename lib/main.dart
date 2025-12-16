import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:geolocation_anomaly/brazil_border_data.dart';
import 'package:geolocation_anomaly/physics_detector.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'package:detect_fake_location/detect_fake_location.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SecureLocationScreen(),
    ),
  );
}

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

class HybridLocationGuard {
  final LocationAnomalyDetector _heuristicDetector = LocationAnomalyDetector();
  final PhysicsMovementDetector _physicsDetector = PhysicsMovementDetector();
  final DetectFakeLocation _detector = DetectFakeLocation();

  StreamSubscription<Position>? _geoLocatorSubscription;
  Timer? _nativeCheckTimer;
  Timer? _territoryCheckTimer;
  bool _isOutsideTerritory = false;

  final Function(Position) onLocationUpdate;
  final Function(String) onFraudDetected;

  HybridLocationGuard({
    required this.onLocationUpdate,
    required this.onFraudDetected,
  });

  Future<void> start() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    _physicsDetector.start();

    _nativeCheckTimer?.cancel();
    _nativeCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        bool isFake = await _detector.detectFakeLocation();

        if (isFake) {
          onFraudDetected(
            "FRAUDE: Mock Location detectado (Lib detect_fake_location).",
          );
        }
      } catch (e) {
        print("Erro ao verificar fake location: $e");
      }
    });

    _territoryCheckTimer?.cancel();
    _territoryCheckTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) async {
      try {
        Position? position = await Geolocator.getLastKnownPosition();
        if (position != null) {
          // Usa o algoritmo matemático offline
          bool isInsideBrazil = BrazilBorderValidator.isPointInPolygon(
            position,
          );

          if (!isInsideBrazil) {
            _isOutsideTerritory = true;
            onFraudDetected(
              "FRAUDE: Coordenada fora das fronteiras brasileiras.",
            );
          } else {
            _isOutsideTerritory = false;
          }
        }
      } catch (e) {
        print("Erro validação território: $e");
      }
    });

    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _geoLocatorSubscription = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(_processGeolocatorPosition);
  }

  void _processGeolocatorPosition(Position position) {
    if (position.isMocked) {
      onFraudDetected("FRAUDE: Geolocator.isMocked retornou true.");
      return;
    }

    if (_isOutsideTerritory) {
      return;
    }

    if (_physicsDetector.isPhysicallyImpossible(position.speed)) {
      onFraudDetected(
        "FRAUDE: Movimento GPS detectado sem vibração física correspondente (Joystick?).",
      );
      return;
    }

    final anomaly = _heuristicDetector.analyze(position);

    if (anomaly != LocationAnomalyType.none) {
      _traduzirAnomalia(anomaly);
    } else {
      onLocationUpdate(position);
    }
  }

  void _traduzirAnomalia(LocationAnomalyType anomaly) {
    switch (anomaly) {
      case LocationAnomalyType.teleportation:
        onFraudDetected("HEURÍSTICA: Teletransporte detectado.");
        break;
      case LocationAnomalyType.artificialStatic:
        onFraudDetected("HEURÍSTICA: GPS Congelado artificialmente (Coords).");
        break;
      case LocationAnomalyType.staticAccuracy:
        onFraudDetected(
          "HEURÍSTICA: Precisão Artificial (Sem variação natural).",
        );
        break;
      case LocationAnomalyType.altitudeZero:
        onFraudDetected("HEURÍSTICA: Altitude 0.0 suspeita.");
        break;
      case LocationAnomalyType.none:
        break;
    }
  }

  void stop() {
    _geoLocatorSubscription?.cancel();
    _nativeCheckTimer?.cancel();
    _heuristicDetector.reset();
    _territoryCheckTimer?.cancel();
    _physicsDetector.stop();
  }
}

class SecureLocationScreen extends StatefulWidget {
  const SecureLocationScreen({super.key});

  @override
  State<SecureLocationScreen> createState() => _SecureLocationScreenState();
}

class _SecureLocationScreenState extends State<SecureLocationScreen> {
  HybridLocationGuard? _guard;
  bool _isMonitoring = false;
  bool _isCompromised = false;
  Position? _currentPosition;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  Future<void> abrirOpcoesDesenvolvedor() async {
    if (Platform.isAndroid) {
      const intent = AndroidIntent(
        action: 'android.settings.APPLICATION_DEVELOPMENT_SETTINGS',
        flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
      );
      await intent.launch();
    }
  }

  @override
  void dispose() {
    _guard?.stop();
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String message, {bool isError = false}) {
    if (!mounted) return;
    final time = DateFormat('HH:mm:ss').format(DateTime.now());
    setState(() {
      _logs.insert(0, "[$time] $message");
      if (isError) _isCompromised = true;
    });
  }

  void _iniciarMonitoramento() {
    if (_isMonitoring) return;

    setState(() {
      _isMonitoring = true;
      _isCompromised = false;
      _logs.clear();
      _addLog("Iniciando Guardião...");
    });

    _guard = HybridLocationGuard(
      onLocationUpdate: (position) {
        if (!mounted) return;
        setState(() => _currentPosition = position);
      },
      onFraudDetected: (reason) {
        _addLog(reason, isError: true);

        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("AÇÃO BLOQUEADA: $reason"),
              backgroundColor: Colors.red[800],
              duration: const Duration(seconds: 10),
              action: SnackBarAction(
                label: 'RESOLVER',
                textColor: Colors.white,
                onPressed: () {
                  abrirOpcoesDesenvolvedor();
                },
              ),
            ),
          );
        }
      },
    );

    _guard?.start();
  }

  void _pararMonitoramento() {
    _guard?.stop();
    if (mounted) {
      setState(() {
        _isMonitoring = false;
        _addLog("Monitoramento pausado.");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Solarius GPS Guard"),
        backgroundColor: _isCompromised ? Colors.red : Colors.indigo,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _logs.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            color: _isCompromised ? Colors.red[50] : Colors.indigo[50],
            width: double.infinity,
            child: Column(
              children: [
                Icon(
                  _isCompromised ? Icons.gpp_bad : Icons.shield,
                  size: 64,
                  color: _isCompromised ? Colors.red : Colors.indigo,
                ),
                const SizedBox(height: 10),
                Text(
                  _isCompromised ? "SISTEMA COMPROMETIDO" : "SISTEMA SEGURO",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _isCompromised
                        ? Colors.red[900]
                        : Colors.indigo[900],
                  ),
                ),
                const SizedBox(height: 10),
                if (_currentPosition != null)
                  Text(
                    "Lat: ${_currentPosition!.latitude}\n"
                    "Lng: ${_currentPosition!.longitude}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontFamily: 'monospace'),
                  )
                else
                  const Text(
                    "Aguardando GPS...",
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];
                final isError =
                    log.contains("FRAUDE") ||
                    log.contains("SISTEMA") ||
                    log.contains("HEURÍSTICA");
                return ListTile(
                  leading: Icon(
                    isError ? Icons.warning : Icons.check_circle_outline,
                    color: isError ? Colors.red : Colors.green,
                  ),
                  title: Text(log, style: const TextStyle(fontSize: 12)),
                  dense: true,
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isMonitoring ? _pararMonitoramento : _iniciarMonitoramento,
        backgroundColor: _isMonitoring ? Colors.orange[800] : Colors.indigo,
        icon: Icon(_isMonitoring ? Icons.pause : Icons.play_arrow),
        label: Text(_isMonitoring ? "Pausar" : "Iniciar"),
      ),
    );
  }
}
