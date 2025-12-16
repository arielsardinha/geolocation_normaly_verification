import 'package:flutter/material.dart';
import 'package:geolocation_anomaly/hybrid_location_guard.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: SecureLocationScreen(),
    ),
  );
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

  double _currentVariance = 0.0;
  double _currentSpeed = 0.0;

  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();

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
      _addLog("Iniciando Validação de Prova de Vida...");
    });

    _guard = HybridLocationGuard(
      onLocationUpdate: (position, variance, speed) {
        if (!mounted) return;
        setState(() {
          _currentPosition = position;
          _currentVariance = variance;
          _currentSpeed = speed;
        });
      },
      onFraudDetected: (reason) {
        _addLog("FRAUDE: $reason", isError: true);
        if (mounted) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(reason), backgroundColor: Colors.red[800]),
          );
        }
      },
    );
    _guard?.start();
  }

  void _pararMonitoramento() {
    _guard?.stop();
    if (mounted) setState(() => _isMonitoring = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Validação de Localização"),
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
          _buildHeader(),
          _buildPhysicsTelemetry(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final log = _logs[index];
                final isError =
                    log.contains("FRAUDE") || log.contains("SISTEMA");
                return ListTile(
                  leading: Icon(
                    isError ? Icons.warning : Icons.check_circle,
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
        label: Text(_isMonitoring ? "Parar" : "Validar"),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: _isCompromised ? Colors.red[50] : Colors.indigo[50],
      width: double.infinity,
      child: Column(
        children: [
          Text(
            _isCompromised ? "AMBIENTE NÃO SEGURO" : "AMBIENTE SEGURO",
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _isCompromised ? Colors.red[900] : Colors.indigo[900],
            ),
          ),
          const SizedBox(height: 8),
          if (_currentPosition != null)
            Text(
              "Lat: ${_currentPosition!.latitude} | Lng: ${_currentPosition!.longitude}",
              style: const TextStyle(fontFamily: 'monospace'),
            ),
        ],
      ),
    );
  }

  Widget _buildPhysicsTelemetry() {
    // 1. AJUSTE DE LIMIAR:
    // Agora usamos 0.002 conforme calibrado no PhysicsMovementDetector.
    // Qualquer valor acima disso é considerado tremor natural de mão.
    bool isNaturalShake = _currentVariance > 0.001;
    Color shakeColor = isNaturalShake ? Colors.green : Colors.orange;

    bool isMoving = _currentSpeed > 0.4;

    return Card(
      margin: const EdgeInsets.all(12),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Telemetria de Prova de Vida (Liveness)",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Velocidade GPS:"),
                Text(
                  // Formatado para 1 casa decimal para ficar limpo na UI
                  "${(_currentSpeed * 3.6)} km/h",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: isMoving ? Colors.blue : Colors.grey,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            const Text("Sensor de Mão (Micro-tremores):"),
            const SizedBox(height: 5),
            LinearProgressIndicator(
              // 2. AJUSTE DE ESCALA VISUAL:
              // Como os valores são muito baixos (ex: 0.003), multiplicamos por 100.
              // Assim, 0.003 vira 0.3 (30% da barra) e 0.01 vira 1.0 (barra cheia).
              // Isso permite ver a barra "viva" mesmo com tremores sutis.
              value: (_currentVariance * 100).clamp(0.0, 1.0),
              backgroundColor: Colors.grey[200],
              color: shakeColor,
              minHeight: 10,
            ),
            const SizedBox(height: 5),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  // Formatado para 5 casas para visualizar os micro-valores (ex: 0.00254)
                  "Var: $_currentVariance",
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  isNaturalShake ? "HUMANO (NATURAL)" : "ESTÁVEL (SUSPEITO)",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: shakeColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
