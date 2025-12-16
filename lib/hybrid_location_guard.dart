import 'dart:async';
import 'package:detect_fake_location/detect_fake_location.dart';
import 'package:geolocation_anomaly/brazil_border_data.dart';
import 'package:geolocation_anomaly/location_anomaly_detector.dart';
import 'package:geolocation_anomaly/physics_detector.dart';
import 'package:geolocator/geolocator.dart';

/// O Guardião Híbrido de Localização.
///
/// Esta classe gerencia o ciclo de vida da detecção de fraudes. Ela combina:
/// 1. Detecção Nativa (Via SO).
/// 2. Detecção Física (Via Acelerômetro).
/// 3. Detecção Heurística (Padrões de dados).
/// 4. Detecção Territorial (Fronteiras).
class HybridLocationGuard {
  // ==========================================
  // DEPENDÊNCIAS (Os especialistas)
  // ==========================================

  /// Responsável por analisar padrões numéricos nos dados do GPS (Teletransporte, GPS Congelado, etc).
  final LocationAnomalyDetector _heuristicDetector = LocationAnomalyDetector();

  /// Biblioteca externa que pergunta ao Android/iOS se existe configuração de Mock ativada.
  final DetectFakeLocation _detector = DetectFakeLocation();

  /// Responsável pela "Prova de Vida" (Liveness).
  /// Analisa se o movimento reportado pelo GPS condiz com a vibração física do celular.
  final PhysicsMovementDetector _physicsDetector = PhysicsMovementDetector();

  // ==========================================
  // ESTADO & CONTROLE
  // ==========================================

  /// Mantém a conexão aberta com o fluxo de dados do GPS.
  StreamSubscription<Position>? _geoLocatorSubscription;

  /// Timer para consultar a biblioteca nativa periodicamente (Polling).
  /// Motivo: Algumas detecções nativas não funcionam por evento (stream), precisam ser perguntadas.
  Timer? _nativeCheckTimer;

  /// Timer para verificar fronteiras.
  /// Motivo: O cálculo matemático de polígonos pode ser custoso, então não rodamos a cada segundo,
  /// mas sim a cada 30s.
  Timer? _territoryCheckTimer;

  /// Flag de bloqueio rápido. Se for true, ignoramos qualquer update de GPS para economizar processamento.
  bool _isOutsideTerritory = false;

  // ==========================================
  // CALLBACKS (Comunicação com a UI)
  // ==========================================

  /// Chamado quando uma localização é considerada VÁLIDA e SEGURA.
  /// Retorna:
  /// - [position]: A coordenada.
  /// - [variance]: O nível de tremor da mão (para feedback visual de liveness).
  /// - [speed]: A velocidade atual.
  final Function(Position position, double variance, double speed)
  onLocationUpdate;

  /// Chamado imediatamente quando qualquer camada de segurança detecta um problema.
  final Function(String) onFraudDetected;

  HybridLocationGuard({
    required this.onLocationUpdate,
    required this.onFraudDetected,
  });

  /// Permite que a UI acesse dados brutos do sensor físico (ex: para desenhar gráficos).
  PhysicsMovementDetector get physics => _physicsDetector;

  // ==========================================
  // LÓGICA PRINCIPAL (O Motor)
  // ==========================================

  /// Inicia todos os monitores de segurança.
  Future<void> start() async {
    // 1. Garante permissões básicas antes de começar qualquer lógica complexa.
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    // 2. Acorda o detector físico (Acelerômetro) para começar a ouvir a "mão" do usuário.
    _physicsDetector.start();

    // -----------------------------------------------------------
    // CAMADA A: Validação Territorial (Geo-Fencing Nacional)
    // -----------------------------------------------------------
    _territoryCheckTimer?.cancel();
    _territoryCheckTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) async {
      try {
        // Obtém a última posição conhecida sem forçar uma nova leitura de GPS (economiza bateria)
        Position? position = await Geolocator.getLastKnownPosition();
        if (position != null) {
          // Usa o algoritmo Ray-Casting (Matemática Offline) para ver se está no Brasil.
          bool isInsideBrazil = BrazilBorderValidator.isPointInPolygon(
            position,
          );

          if (!isInsideBrazil) {
            _isOutsideTerritory = true;
            onFraudDetected("TERRITÓRIO: Fora do Brasil.");
          } else {
            _isOutsideTerritory = false;
          }
        }
      } catch (e) {
        print(e);
      }
    });

    // -----------------------------------------------------------
    // CAMADA B: Validação de Sistema (Mock Settings)
    // -----------------------------------------------------------
    _nativeCheckTimer?.cancel();
    // Pergunta ao Android a cada 5 segundos: "O usuário ativou o Fake GPS nas configurações?"
    _nativeCheckTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        if (await _detector.detectFakeLocation()) {
          onFraudDetected("SISTEMA: Mock Location detectado (Lib).");
        }
      } catch (e) {
        print(e);
      }
    });

    // -----------------------------------------------------------
    // CAMADA C: Fluxo Contínuo de GPS (Real-time)
    // -----------------------------------------------------------
    final locationSettings = const LocationSettings(
      accuracy:
          LocationAccuracy.bestForNavigation, // Exige GPS de alta precisão
      distanceFilter:
          0, // Notifica qualquer mudança mínima (necessário para pegar micro-movimentos)
    );

    _geoLocatorSubscription =
        Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen((Position position) {
          // 1. Filtro Rápido: Se já sabemos que está fora do país, nem processa o resto.
          if (_isOutsideTerritory) return;

          // 2. Validação Física (Joystick Walk / Liveness)
          // "O GPS diz que ele está andando, mas o acelerômetro diz que o celular está na mesa?"
          if (_physicsDetector.isJoystickWalk(position.speed)) {
            onFraudDetected("FÍSICA: Movimento GPS sem tremor de mão.");
            // Nota: Dependendo da regra de negócio, poderíamos dar um 'return' aqui.
          }

          // 3. Validação Nativa do Pacote Geolocator
          // O próprio Android às vezes marca a coordenada com a flag 'isMock'.
          if (position.isMocked) {
            onFraudDetected("NATIVO: Geolocator isMocked.");
            return;
          }

          // 4. Validação Heurística (Análise de Dados)
          // "A precisão está perfeita demais? A altitude é zero? Ele se teletransportou?"
          final anomaly = _heuristicDetector.analyze(position);

          if (anomaly != LocationAnomalyType.none) {
            // Se encontrou anomalia matemática, traduz para mensagem de erro.
            _traduzirAnomalia(anomaly);
          } else {
            // === SUCESSO ===
            // Se passou por:
            // - Fronteira (Timer A)
            // - Configuração de Sistema (Timer B)
            // - Física (Passo 2)
            // - Flag Nativa (Passo 3)
            // - Heurística (Passo 4)
            // Então a localização é confiável. Enviamos para a tela.
            onLocationUpdate(
              position,
              _physicsDetector
                  .currentVariance, // Envia vibração para o gráfico UI
              position.speed,
            );
          }
        });
  }

  /// Traduz o código de erro (Enum) para uma mensagem legível para o usuário/log.
  void _traduzirAnomalia(LocationAnomalyType anomaly) {
    switch (anomaly) {
      case LocationAnomalyType.teleportation:
        onFraudDetected("HEURÍSTICA: Teletransporte.");
        break;
      case LocationAnomalyType.artificialStatic:
        onFraudDetected("HEURÍSTICA: GPS Congelado.");
        break;
      case LocationAnomalyType.staticAccuracy:
        onFraudDetected("HEURÍSTICA: Precisão Artificial.");
        break;
      case LocationAnomalyType.altitudeZero:
        onFraudDetected("HEURÍSTICA: Altitude 0.0.");
        break;
      case LocationAnomalyType.none:
        break;
    }
  }

  /// Para todos os listeners e timers para evitar vazamento de memória (Memory Leaks)
  /// Deve ser chamado no dispose() da tela.
  void stop() {
    _geoLocatorSubscription?.cancel();
    _nativeCheckTimer?.cancel();
    _territoryCheckTimer?.cancel();
    _physicsDetector.stop(); // Desliga o acelerômetro
    _heuristicDetector.reset(); // Limpa o histórico de posições anteriores
  }
}
