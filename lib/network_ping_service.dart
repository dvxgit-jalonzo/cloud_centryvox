class NetworkPingService {
  static final NetworkPingService _instance = NetworkPingService._internal();
  factory NetworkPingService() => _instance;

  NetworkPingService._internal();
}
