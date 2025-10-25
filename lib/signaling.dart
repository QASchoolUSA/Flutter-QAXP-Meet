import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
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

  void _log(String message) {
    final msg = '[Signaling] $message';
    developer.log(msg, name: 'signaling');
    // ignore: avoid_print
    print(msg);
  }

  Future<void> connect() async {
    _log('Connecting to $uri');
    _channel = _connectFactory(uri);
    _connected = true;
    _sub = _channel!.stream.listen((event) {
      try {
        final data = event is String ? jsonDecode(event) : event;
        if (data is Map<String, dynamic>) {
          _log('Recv: ${data['type']}');
          _messages.add(data);
        }
      } catch (e) {
        _log('Recv parse error: $e');
        // ignore malformed messages
      }
    }, onDone: () {
      _connected = false;
      _stopHeartbeat();
      _log('WS closed');
      _messages.add({'type': 'ws_closed'});
    }, onError: (error, stack) {
      _connected = false;
      _stopHeartbeat();
      _log('WS error: $error');
      _messages.add({'type': 'ws_error', 'error': error.toString()});
    });

    if (_buffer.isNotEmpty) {
      _log('Flushing ${_buffer.length} buffered messages');
      for (final m in _buffer) {
        send(m);
      }
      _buffer.clear();
    }

    _startHeartbeat();
    _log('Heartbeat started');
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_connected && _channel != null) {
        _log('Ping');
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
      _log('Send: ${message['type']}');
      _channel!.sink.add(payload);
    } else {
      _log('Buffering: ${message['type']}');
      _buffer.add(message);
    }
  }

  void join(String room) {
    _log('Join room: $room');
    send({'type': 'join', 'room': room});
  }

  Future<void> close() async {
    _log('Closing signaling');
    await _sub?.cancel();
    await _channel?.sink.close();
    _stopHeartbeat();
    _connected = false;
  }
}