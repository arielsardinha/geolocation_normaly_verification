// brazil_border_data.dart
import 'package:geolocator/geolocator.dart';

class BrazilBorderValidator {
  /// Verifica se o ponto está dentro do polígono do Brasil usando algoritmo Ray Casting.
  /// https://brasilemsintese.ibge.gov.br/territorio/dados-geograficos.html
  static bool isPointInPolygon(Position point) {
    // Polígono simplificado do Brasil (Coordenadas Lat/Lng extraídas de dados geográficos)
    // Sentido anti-horário cobrindo o contorno grosseiro do país.
    final List<List<double>> polygon = [
      [5.27178, -60.21161], // Monte Caburaí (Norte)
      [4.5, -51.0], // Amapá Coast
      [0.0, -47.0], // Foz do Amazonas
      [-2.5, -40.0], // Ceará
      [-5.0, -35.0], // RN (Ponta do Seixas - Extremo Leste)
      [-10.0, -35.5], // Alagoas/Sergipe
      [-18.0, -39.0], // Bahia Coast
      [-23.0, -41.0], // Rio de Janeiro (Cabo Frio)
      [-25.5, -48.0], // Paraná Coast
      [-33.75, -53.0], // Chuí (Extremo Sul)
      [-30.0, -57.5], // Fronteira Argentina/Uruguai
      [-25.5, -54.5], // Foz do Iguaçu
      [-22.5, -58.0], // MS / Paraguai
      [-19.0, -57.5], // Pantanal
      [-16.0, -60.0], // Mato Grosso / Bolívia
      [-12.0, -65.0], // Rondônia
      [-10.0, -70.0], // Acre
      [-7.5, -73.9], // Serra da Contamana (Extremo Oeste)
      [-4.0, -70.0], // Amazonas / Colômbia
      [1.0, -67.0], // Cabeça do Cachorro
      [5.27178, -60.21161], // Fecha o polígono no Norte
    ];

    bool isInside = false;
    int i, j = polygon.length - 1;

    for (i = 0; i < polygon.length; i++) {
      // Vértices do polígono (Lat, Long)
      double lat1 = polygon[i][0];
      double lng1 = polygon[i][1];
      double lat2 = polygon[j][0];
      double lng2 = polygon[j][1];

      // Ponto do usuário
      double x = point.latitude;
      double y = point.longitude;

      // Algoritmo Ray Casting
      bool intersect =
          ((lng1 > y) != (lng2 > y)) &&
          (x < (lat2 - lat1) * (y - lng1) / (lng2 - lng1) + lat1);

      if (intersect) {
        isInside = !isInside;
      }
      j = i;
    }

    return isInside;
  }
}
