import 'dart:async';
import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

// Import da nova biblioteca
import 'package:detect_fake_location/detect_fake_location.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SecureLocationScreen(),
    ),
  );
}

// ==========================================
// 1. LÓGICA DE HEURÍSTICA (Regra de Negócio)
// ==========================================

enum LocationAnomalyType { none, altitudeZero, teleportation, artificialStatic }

class LocationAnomalyDetector {
  static const double _maxSpeedMetersPerSecond = 200.0;
  static const int _maxIdenticalUpdates = 5;

  Position? _lastPosition;
  int _identicalCoordinateCount = 0;

  LocationAnomalyType analyze(Position newPosition) {
    // 1. Altitude Zero (Suspeita em alguns casos)
    if (newPosition.altitude == 0.0) {
      return LocationAnomalyType.altitudeZero;
    }

    if (_lastPosition != null) {
      // 2. Teletransporte
      final double distance = Geolocator.distanceBetween(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        newPosition.latitude,
        newPosition.longitude,
      );

      final int timeDeltaSeconds = newPosition.timestamp
          .difference(_lastPosition!.timestamp)
          .inSeconds;

      if (timeDeltaSeconds > 0) {
        final double speed = distance / timeDeltaSeconds;
        if (speed > _maxSpeedMetersPerSecond) {
          return LocationAnomalyType.teleportation;
        }
      }

      // 3. GPS Estático Artificial
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

    _lastPosition = newPosition;
    return LocationAnomalyType.none;
  }

  void reset() {
    _lastPosition = null;
    _identicalCoordinateCount = 0;
  }
}

// ==========================================
// 2. GUARDIÃO HÍBRIDO (Service Layer)
// ==========================================

class HybridLocationGuard {
  final LocationAnomalyDetector _heuristicDetector = LocationAnomalyDetector();

  // Instância da biblioteca externa
  final DetectFakeLocation _detector = DetectFakeLocation();

  StreamSubscription<Position>? _geoLocatorSubscription;
  Timer? _nativeCheckTimer;

  final Function(Position) onLocationUpdate;
  final Function(String) onFraudDetected;

  HybridLocationGuard({
    required this.onLocationUpdate,
    required this.onFraudDetected,
  });

  Future<void> start() async {
    // 1. Verificar Permissões
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    // 2. Iniciar Verificação Nativa (Polling com a Lib)
    // Verifica a cada 5 segundos se existe Mock ativado
    _nativeCheckTimer?.cancel();
    _nativeCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        // Chamada direta à biblioteca detect_fake_location
        bool isFake = await _detector.detectFakeLocation();

        if (isFake) {
          onFraudDetected(
            "SISTEMA: Mock Location detectado (Lib detect_fake_location).",
          );
        }
      } catch (e) {
        print("Erro ao verificar fake location: $e");
      }
    });

    // 3. Iniciar Geolocator (Monitoramento de Posição)
    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _geoLocatorSubscription =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (Position position) {
            _processGeolocatorPosition(position);
          },
        );
  }

  void _processGeolocatorPosition(Position position) {
    // A. Validação Nativa Básica (Android isMocked flag)
    if (position.isMocked) {
      onFraudDetected("NATIVO: Geolocator.isMocked retornou true.");
      return;
    }

    // B. Validação Heurística
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
        onFraudDetected("HEURÍSTICA: GPS Congelado artificialmente.");
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
  }
}

// ==========================================
// 3. UI (Presentation Layer)
// ==========================================

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
        _addLog("FRAUDE: $reason", isError: true);

        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("AÇÃO BLOQUEADA: $reason"),
              backgroundColor: Colors.red[800],
              duration: const Duration(
                seconds: 10,
              ), // Dura mais tempo para dar tempo de clicar
              action: SnackBarAction(
                label: 'RESOLVER',
                textColor: Colors.white,
                onPressed: () {
                  // Abre a tela de configurações para o usuário desligar o Fake GPS
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
                    "Lat: ${_currentPosition!.latitude.toStringAsFixed(5)}\n"
                    "Lng: ${_currentPosition!.longitude.toStringAsFixed(5)}",
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
