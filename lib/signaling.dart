import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class SignalingClient {
  final Uri uri;
  final WebSocketChannel Function(Uri) _connectFactory;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  bool _connected = false;
  final List<Map<String, dynamic>> _buffer = [];
  Timer? _heartbeat;

  SignalingClient(this.uri, {WebSocketChannel Function(Uri)? connectFactory})
      : _connectFactory = connectFactory ?? WebSocketChannel.connect;

  static SignalingClient fromEnv({WebSocketChannel Function(Uri)? connectFactory}) {
    const defaultUrl = String.fromEnvironment('WS_URL', defaultValue: 'wss://signal.qaxp.com/ws');
    final u = Uri.parse(defaultUrl);
    return SignalingClient(u, connectFactory: connectFactory);
  }

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  bool get isConnected => _connected;

  Future<void> connect() async {
    _channel = _connectFactory(uri);
    _connected = true;
    _sub = _channel!.stream.listen((event) {
      try {
        final data = event is String ? jsonDecode(event) : event;
        if (data is Map<String, dynamic>) {
          _messages.add(data);
        }
      } catch (_) {
        // ignore malformed messages
      }
    }, onDone: () {
      _connected = false;
      _stopHeartbeat();
      _messages.add({'type': 'ws_closed'});
    }, onError: (error, stack) {
      _connected = false;
      _stopHeartbeat();
      _messages.add({'type': 'ws_error', 'error': error.toString()});
    });

    if (_buffer.isNotEmpty) {
      for (final m in _buffer) {
        send(m);
      }
      _buffer.clear();
    }

    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected && _channel != null) {
        _channel!.sink.add(jsonEncode({'type': 'ping'}));
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void send(Map<String, dynamic> message) {
    final payload = jsonEncode(message);
    if (_connected && _channel != null) {
      _channel!.sink.add(payload);
    } else {
      _buffer.add(message);
    }
  }

  void join(String room) {
    send({'type': 'join', 'room': room});
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    _stopHeartbeat();
    _connected = false;
  }
}