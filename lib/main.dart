import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QAXP Meet',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _roomController = TextEditingController();

  void _enterRoom() {
    final room = _roomController.text.trim();
    if (room.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RoomPage(roomName: room)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Card(
              elevation: 10,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: const [
                        Icon(Icons.video_chat, color: Colors.indigo, size: 28),
                        SizedBox(width: 8),
                        Text('QAXP Meet', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Create or join a room with its name. No usernames needed.',
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _roomController,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _enterRoom(),
                      decoration: InputDecoration(
                        labelText: 'Room name',
                        hintText: 'e.g. standup-10am',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        prefixIcon: const Icon(Icons.meeting_room),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _enterRoom,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Enter'),
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text('Share the room name; the other peer auto-connects.',
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.black45)),

                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RoomPage extends StatefulWidget {
  final String roomName;
  const RoomPage({super.key, required this.roomName});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  // Signaling removed; local-only mode.

  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  // Accessibility focus nodes for controls
  final FocusNode _focusMicToggle = FocusNode(debugLabel: 'Mic toggle');
  final FocusNode _focusMicMenu = FocusNode(debugLabel: 'Mic menu');
  final FocusNode _focusCamToggle = FocusNode(debugLabel: 'Camera toggle');
  final FocusNode _focusCamMenu = FocusNode(debugLabel: 'Camera menu');
  final FocusNode _focusHangup = FocusNode(debugLabel: 'Hang up');

  // Signaling channel removed for web-only local preview.
  String get _wsEndpoint =>
      const String.fromEnvironment('WS_URL', defaultValue: 'wss://signal.qaxp.com/ws');
  WebSocketChannel? _channel;

  String _endpointForRoom(String room) {
    final base = _wsEndpoint;
    if (base.contains('{room}')) {
      return base.replaceAll('{room}', Uri.encodeComponent(room));
    }
    return base; // payload-based room selection
  }

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final List<Map<String, dynamic>> _pendingIce = [];

  bool _micEnabled = true;
  bool _videoEnabled = true;
  String? _role; // 'caller' | 'callee'
  bool _peerJoined = false;

  String? _expandedTarget; // 'local' | 'remote' | null

  List<MediaDeviceInfo> _audioInputs = [];
  List<MediaDeviceInfo> _videoInputs = [];
  String? _selectedMicId;
  String? _selectedCamId;
  bool _renegotiating = false;
  DateTime? _lastRenegotiateAt;
  bool _remoteVideoEnabled = true;
  bool _statsScheduled = false;

  void _debug(String message) {
    print('[meet] ' + message);
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _remoteRenderer.srcObject = null;

    await _enumerateDevices();
    await _setupMedia();
    await _setupSignalingAndRTC();
  }

  Future<void> _enumerateDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      setState(() {
        _audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
        _videoInputs = devices.where((d) => d.kind == 'videoinput').toList();
        _selectedMicId = _audioInputs.isNotEmpty ? _audioInputs.first.deviceId : null;
        _selectedCamId = _videoInputs.isNotEmpty ? _videoInputs.first.deviceId : null;
      });
    } catch (_) {}
  }

  Future<void> _setupMedia() async {
    try {
      final isMobile = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android;
      final audioConstraints = isMobile ? true : (_selectedMicId != null ? {'deviceId': _selectedMicId} : true);
      final videoConstraints = isMobile ? {'facingMode': 'user'} : (_selectedCamId != null ? {'deviceId': _selectedCamId} : true);
      final Map<String, dynamic> constraints = {
        'audio': audioConstraints,
        'video': videoConstraints,
      };
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      _localStream = stream;
      _localRenderer.srcObject = _localStream;
    } catch (e) {
      // Common causes: permissions denied or insecure context (no HTTPS)
    }
  }

  Future<void> _setupSignalingAndRTC() async {
    // Create RTCPeerConnection with a public STUN server
    final configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      'sdpSemantics': 'unified-plan',
    };
    _pc = await createPeerConnection(configuration);

    // Explicit transceivers to ensure recv slots for remote media
    try {
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      );
    } catch (_) {}

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      _debug('ICE state: ' + state.toString());
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _attachRemoteReceivers();
        if (!_statsScheduled) {
          _statsScheduled = true;
          _scheduleInboundStatsCheck();
        }
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _restartIceAndRenegotiate('ice_failed');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _statsScheduled = false;
      }
    };

    // Remove duplicate scheduling in onConnectionState
    _pc!.onConnectionState = (RTCPeerConnectionState state) {
      _debug('PC state: ' + state.toString());
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _statsScheduled = false;
      }
    };

    // Remote track handler: normalize to a single _remoteStream container
    _pc!.onTrack = (RTCTrackEvent event) async {
      _debug('onTrack kind=' + (event.track?.kind ?? 'unknown') + ' streams=' + event.streams.length.toString());
      _remoteStream ??= await createLocalMediaStream('remote');
      if (event.track != null) {
        final exists = _remoteStream!.getTracks().any((t) => t.id == event.track!.id);
        if (!exists) {
          await _remoteStream!.addTrack(event.track!);
        }
      }
      // If peer provided a stream, import its tracks into our container
      if (event.streams.isNotEmpty) {
        for (final s in event.streams) {
          for (final t in s.getTracks()) {
            final exists = _remoteStream!.getTracks().any((rt) => rt.id == t.id);
            if (!exists) {
              await _remoteStream!.addTrack(t);
            }
          }
        }
      }
      _remoteRenderer.srcObject = _remoteStream;
      setState(() {
        _peerJoined = true;
        if (event.track?.kind == 'video') {
          _remoteVideoEnabled = true;
        }
      });
    };

    // Plan-B fallback: merge incoming stream tracks into our container
    _pc!.onAddStream = (MediaStream stream) async {
      _debug('onAddStream id=' + stream.id);
      _remoteStream ??= await createLocalMediaStream('remote');
      for (final t in stream.getTracks()) {
        final exists = _remoteStream!.getTracks().any((rt) => rt.id == t.id);
        if (!exists) {
          await _remoteStream!.addTrack(t);
        }
      }
      _remoteRenderer.srcObject = _remoteStream;
      setState(() => _peerJoined = true);
    };

    // Add local tracks
    final local = _localStream;
    if (local != null) {
      for (final t in local.getTracks()) {
        await _pc!.addTrack(t, local);
      }
    }

    // Remote track handler consolidated earlier to normalize into _remoteStream.
    // Removed duplicate onTrack/onAddStream assignments.

    // ICE candidate handler: send to signaling server
    _pc!.onIceCandidate = (RTCIceCandidate candidate) {
      if (_channel != null && (candidate.candidate?.isNotEmpty ?? false)) {
        final payload = {
          'type': 'signal',
          'room': widget.roomName,
          'payload': {
            'type': 'candidate',
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        };
        _debug('send ICE');
        _send(payload);
      }
    };

    // Connect to signaling server via WebSocket
    try {
      final url = _endpointForRoom(widget.roomName);
      _debug('Connecting WS: ' + url);
      _channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _debug('WS connect error: ' + e.toString());
      // If connection fails, keep local preview
      return;
    }

    // Join the room
    _debug('Join room: ' + widget.roomName);
    _send({'type': 'join', 'room': widget.roomName});

    // Handle messages
    _channel!.stream.listen((dynamic data) async {
      Map<String, dynamic> msg;
      try {
        final text = data is String ? data.trim() : (data as String);
        msg = jsonDecode(text);
      } catch (e) {
        _debug('WS recv non-JSON or parse error: ' + e.toString());
        return;
      }

      final type = (msg['type'] ?? '').toString();
      _debug('recv: ' + type);

      switch (type) {
        case 'joined':
          _role = (msg['role'] ?? '').toString();
          _debug('joined as ' + (_role ?? ''));
          break;

        case 'signal':
          {
            final payload = msg['payload'];
            if (payload is Map<String, dynamic>) {
              final ptype = (payload['type'] ?? '').toString();
              switch (ptype) {
                case 'video_state':
                  {
                    final enabled = payload['enabled'] == true;
                    setState(() => _remoteVideoEnabled = enabled);
                    // Refresh stats check to reflect new state promptly
                    _scheduleInboundStatsCheck();
                  }
                  break;
                case 'offer':
                  {
                    final sdp = payload['sdp'] as String?;
                    if (sdp == null || _pc == null) break;
                    _debug('setRemoteDescription(offer)');
                    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
                    for (final cand in _pendingIce) {
                      await _pc!.addCandidate(RTCIceCandidate(
                        cand['candidate'] as String?,
                        cand['sdpMid'] as String?,
                        cand['sdpMLineIndex'] as int?,
                      ));
                    }
                    _pendingIce.clear();
                    await _attachRemoteReceivers();

                    final answer = await _pc!.createAnswer();
                    await _pc!.setLocalDescription(answer);
                    _debug('send answer');
                    _send({
                      'type': 'signal',
                      'room': widget.roomName,
                      'payload': {
                        'type': 'answer',
                        'sdp': answer.sdp,
                      }
                    });
                    _renegotiating = false;
                    _lastRenegotiateAt = DateTime.now();
                  }
                  break;
                case 'answer':
                  {
                    final sdp = payload['sdp'] as String?;
                    if (sdp == null || _pc == null) break;
                    final current = await _pc!.getRemoteDescription();
                    if (current != null && current.type == 'answer') {
                      _debug('skip duplicate answer');
                      break;
                    }
                    _debug('setRemoteDescription(answer)');
                    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
                    for (final cand in _pendingIce) {
                      await _pc!.addCandidate(RTCIceCandidate(
                        cand['candidate'] as String?,
                        cand['sdpMid'] as String?,
                        cand['sdpMLineIndex'] as int?,
                      ));
                    }
                    _pendingIce.clear();
                    await _attachRemoteReceivers();
                    _renegotiating = false;
                    _lastRenegotiateAt = DateTime.now();
                  }
                  break;
                case 'candidate':
                case 'ice':
                  {
                    final cand = <String, dynamic>{
                      'candidate': payload['candidate'],
                      'sdpMid': payload['sdpMid'],
                      'sdpMLineIndex': payload['sdpMLineIndex'],
                    };
                    if (_pc == null) break;
                    final remoteDesc = await _pc!.getRemoteDescription();
                    if (remoteDesc == null) {
                      _debug('buffer ICE');
                      _pendingIce.add(cand);
                    } else {
                      _debug('add ICE');
                      await _pc!.addCandidate(RTCIceCandidate(
                        cand['candidate'] as String?,
                        cand['sdpMid'] as String?,
                        cand['sdpMLineIndex'] as int?,
                      ));
                    }
                  }
                  break;
              }
            }
          }
          break;

        case 'peer-joined':
        case 'peer_joined':
          setState(() => _peerJoined = true);
          break;
        case 'ready':
        case 'nudge':
        case 'start_negotiation':
        case 'start-negotiation':
          await _maybeStartNegotiation();
          break;

        case 'peer-left':
        case 'peer_left':
          setState(() {
            _peerJoined = false;
            _remoteRenderer.srcObject = null;
            _remoteStream = null;
          });
          break;

        case 'offer':
          {
            String? sdp = msg['sdp'] as String?;
            // Fallback for nested offer objects
            sdp ??= (msg['offer'] is Map ? (msg['offer']['sdp'] as String?) : null);
            if (sdp == null || _pc == null) break;
            _debug('setRemoteDescription(offer)');
            await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
            // Flush any pending ICE received before remote description was set
            for (final cand in _pendingIce) {
              await _pc!.addCandidate(RTCIceCandidate(
                cand['candidate'] as String?,
                cand['sdpMid'] as String?,
                cand['sdpMLineIndex'] as int?,
              ));
            }
            _pendingIce.clear();

            final answer = await _pc!.createAnswer();
            await _pc!.setLocalDescription(answer);
            _debug('send answer');
            _send({
              'type': 'answer',
              'room': widget.roomName,
              'sdp': answer.sdp,
              // Fallback nested structure some servers require
              'answer': {
                'type': 'answer',
                'sdp': answer.sdp,
              }
            });
            _renegotiating = false;
            _lastRenegotiateAt = DateTime.now();
          }
          break;

        case 'answer':
          {
            String? sdp = msg['sdp'] as String?;
            // Fallback for nested answer objects
            sdp ??= (msg['answer'] is Map ? (msg['answer']['sdp'] as String?) : null);
            if (sdp == null || _pc == null) break;
            final current = await _pc!.getRemoteDescription();
            if (current != null && current.type == 'answer') {
              _debug('skip duplicate answer');
              break;
            }
            _debug('setRemoteDescription(answer)');
            await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
            // Flush pending ICE
            for (final cand in _pendingIce) {
              await _pc!.addCandidate(RTCIceCandidate(
                cand['candidate'] as String?,
                cand['sdpMid'] as String?,
                cand['sdpMLineIndex'] as int?,
              ));
            }
            _pendingIce.clear();
            _renegotiating = false;
            _lastRenegotiateAt = DateTime.now();
          }
          break;

        case 'ice':
        case 'candidate':
          {
            final candAny = msg['candidate'];
            Map<String, dynamic>? cand;
            if (candAny is Map<String, dynamic>) {
              cand = candAny;
            } else if (candAny is String) {
              cand = {
                'candidate': candAny,
                'sdpMid': msg['sdpMid'],
                'sdpMLineIndex': msg['sdpMLineIndex'],
              };
            }
            if (cand == null || _pc == null) break;
            final remoteDesc = await _pc!.getRemoteDescription();
            if (remoteDesc == null) {
              _debug('buffer ICE');
              _pendingIce.add(cand);
            } else {
              _debug('add ICE');
              await _pc!.addCandidate(RTCIceCandidate(
                cand['candidate'] as String?,
                cand['sdpMid'] as String?,
                cand['sdpMLineIndex'] as int?,
              ));
            }
          }
          break;

        case 'leave':
        case 'peer-left':
          // Remote hung up
          setState(() {
            _peerJoined = false;
            _remoteRenderer.srcObject = null;
            _remoteStream = null;
          });
          break;
      }
    }, onDone: () {
      _debug('WS closed');
      // Channel closed – keep local preview
    }, onError: (e) {
      _debug('WS error: ' + e.toString());
      // Errors – keep local preview
    });
  }

  Future<void> _startCall() async {
    if (_pc == null) return;
    // Create and send offer
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    _debug('send offer');
    _send({
      'type': 'signal',
      'room': widget.roomName,
      'payload': {
        'type': 'offer',
        'sdp': offer.sdp,
      }
    });
  }

  void _send(Map<String, dynamic> msg) {
    try {
      _channel?.sink.add(jsonEncode(msg));
    } catch (e) {
      _debug('WS send error: ' + e.toString());
    }
  }

  Future<void> _toggleMic() async {
    setState(() => _micEnabled = !_micEnabled);
    final tracks = _localStream?.getAudioTracks() ?? [];
    for (var t in tracks) {
      t.enabled = _micEnabled;
    }
  }

  Future<void> _toggleVideo() async {
    setState(() => _videoEnabled = !_videoEnabled);
    final tracks = _localStream?.getVideoTracks() ?? [];
    for (var t in tracks) {
      t.enabled = _videoEnabled;
    }
    // Signal remote to update UI immediately
    _send({
      'type': 'signal',
      'room': widget.roomName,
      'payload': {
        'type': 'video_state',
        'enabled': _videoEnabled,
      }
    });
  }

  Future<void> _switchCameraTo(String deviceId) async {
    try {
      final media = await navigator.mediaDevices.getUserMedia({'video': {'deviceId': deviceId}});
      final newVideoTrack = media.getVideoTracks().first;

      // Replace track in local stream
      final currentVideoTracks = _localStream?.getVideoTracks() ?? [];
      for (var t in currentVideoTracks) {
        await t.stop();
        _localStream?.removeTrack(t);
      }
      _localStream?.addTrack(newVideoTrack);
      _localRenderer.srcObject = _localStream;

      // Replace sender track in PeerConnection
      final senders = await _pc?.getSenders() ?? [];
      for (var s in senders) {
        if (s.track?.kind == 'video') {
          await s.replaceTrack(newVideoTrack);
        }
      }
      setState(() => _selectedCamId = deviceId);
    } catch (_) {}
  }

  Future<void> _switchMicTo(String deviceId) async {
    try {
      final media = await navigator.mediaDevices.getUserMedia({'audio': {'deviceId': deviceId}});
      final newAudioTrack = media.getAudioTracks().first;

      final currentAudioTracks = _localStream?.getAudioTracks() ?? [];
      for (var t in currentAudioTracks) {
        await t.stop();
        _localStream?.removeTrack(t);
      }
      _localStream?.addTrack(newAudioTrack);

      final senders = await _pc?.getSenders() ?? [];
      for (var s in senders) {
        if (s.track?.kind == 'audio') {
          await s.replaceTrack(newAudioTrack);
        }
      }
      setState(() => _selectedMicId = deviceId);
    } catch (_) {}
  }

  void _toggleExpand(String target) {
    setState(() {
      _expandedTarget = _expandedTarget == target ? null : target;
    });
  }

  Future<void> _hangup() async {
    _send({'type': 'leave', 'room': widget.roomName});
    await _channel?.sink.close();
    await _pc?.close();
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    await _localStream?.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _maybeStartNegotiation() async {
    if (_renegotiating) {
      _debug('skip negotiation: already in progress');
      return;
    }
    final now = DateTime.now();
    if (_lastRenegotiateAt != null && now.difference(_lastRenegotiateAt!).inSeconds < 2) {
      _debug('skip negotiation: too soon');
      return;
    }
    _renegotiating = true;
    try {
      await _startCall();
    } catch (e) {
      _debug('start negotiation error: ' + e.toString());
      _renegotiating = false;
    }
  }

  // Inbound RTP stats check and ICE-restart fallback
  void _scheduleInboundStatsCheck() {
    Future.delayed(const Duration(seconds: 2), _checkInboundMediaOnce);
  }

  Future<void> _checkInboundMediaOnce() async {
    try {
      final stats = await _pc?.getStats() ?? [];
      int videoBytes = 0;
      int audioBytes = 0;
      for (final r in stats) {
        try {
          final type = (r.type ?? '').toString();
          final values = r.values as Map?;
          if (type == 'inbound-rtp' && values != null) {
            final kind = (values['kind'] ?? values['mediaType'] ?? '').toString();
            final bytes = values['bytesReceived'] ?? 0;
            final parsed = bytes is int ? bytes : int.tryParse(bytes.toString()) ?? 0;
            if (kind == 'video') videoBytes = parsed;
            if (kind == 'audio') audioBytes = parsed;
          }
        } catch (_) {}
      }
      _debug('inbound bytes video=' + videoBytes.toString() + ' audio=' + audioBytes.toString());
      // Update remote video UI state based on inbound bytes
      if (videoBytes == 0 && audioBytes > 0) {
        setState(() => _remoteVideoEnabled = false);
      } else if (videoBytes > 0) {
        setState(() => _remoteVideoEnabled = true);
      }
      // If both are zero, attempt recovery
      if (videoBytes == 0 && audioBytes == 0) {
        _restartIceAndRenegotiate('no_inbound_media');
      }
    } catch (_) {}
  }

  Future<void> _restartIceAndRenegotiate(String reason) async {
    if (_pc == null) return;
    final now = DateTime.now();
    if (_renegotiating) return;
    if (_lastRenegotiateAt != null && now.difference(_lastRenegotiateAt!).inSeconds < 10) {
      return;
    }
    _renegotiating = true;
    _lastRenegotiateAt = now;
    try {
      _debug('Renegotiate: ' + reason);
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      _send({
        'type': 'signal',
        'room': widget.roomName,
        'payload': {
          'type': 'offer',
          'sdp': offer.sdp,
        }
      });
    } catch (e) {
      _debug('Renegotiate error: ' + e.toString());
    } finally {
      Future.delayed(const Duration(seconds: 3), () {
        _renegotiating = false;
      });
    }
  }

  Future<void> _attachRemoteReceivers() async {
    try {
      final receivers = await _pc?.getReceivers() ?? [];
      if (receivers.isEmpty) return;
      _remoteStream ??= await createLocalMediaStream('remote');
      for (final r in receivers) {
        final track = r.track;
        if (track != null) {
          final exists = _remoteStream!.getTracks().any((t) => t.id == track.id);
          if (!exists) {
            await _remoteStream!.addTrack(track);
          }
        }
      }
      if (_remoteStream!.getTracks().isNotEmpty) {
        _remoteRenderer.srcObject = _remoteStream;
        setState(() => _peerJoined = true);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _hangup();
    super.dispose();
  }

  Widget _videoView(RTCVideoRenderer renderer, String label) {
    final showOff = (label == 'remote' && !_remoteVideoEnabled) || (label == 'local' && !_videoEnabled);
    return GestureDetector(
      onDoubleTap: () => _toggleExpand(label),
      child: Container(
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(children: [
            RTCVideoView(renderer, mirror: label == 'local'),
            if (showOff)
              Container(
                color: Colors.black54,
                child: const Center(
                  child: Icon(Icons.videocam_off, size: 72, color: Colors.white70),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Build individual controls to allow grouped spacing and styling
    final micToggle = Semantics(
      label: 'Toggle microphone',
      button: true,
      child: ElevatedButton(
        focusNode: _focusMicToggle,
        onPressed: _toggleMic,
        style: ButtonStyle(
          shape: MaterialStateProperty.all(const CircleBorder()),
          padding: MaterialStateProperty.all(const EdgeInsets.all(14)),
          elevation: MaterialStateProperty.resolveWith((states) =>
              states.contains(MaterialState.hovered) ? 6 : 0),
          backgroundColor: MaterialStateProperty.resolveWith((states) =>
              states.contains(MaterialState.pressed)
                  ? Colors.white.withOpacity(0.16)
                  : Colors.white.withOpacity(0.10)),
          foregroundColor: MaterialStateProperty.all(Colors.white),
        ),
        child: Icon(_micEnabled ? Icons.mic : Icons.mic_off),
      ),
    );

    final micMenu = Semantics(
      label: 'Open microphone devices menu',
      button: true,
      child: Focus(
        focusNode: _focusMicMenu,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
            ],
          ),
          child: PopupMenuButton<String>(
            tooltip: 'Select microphone',
            icon: const Icon(Icons.keyboard_arrow_up, size: 20, color: Colors.white),
            itemBuilder: (context) {
              final entries = <PopupMenuEntry<String>>[];
              if (_selectedMicId != null) {
                entries.add(const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('Selected', style: TextStyle(fontWeight: FontWeight.bold)),
                ));
                final selected = _audioInputs.firstWhere(
                  (d) => d.deviceId == _selectedMicId,
                  orElse: () => MediaDeviceInfo(label: 'Microphone', deviceId: _selectedMicId ?? '', kind: 'audioinput'),
                );
                entries.add(PopupMenuItem<String>(
                  value: selected.deviceId,
                  child: Row(children: [
                    const Icon(Icons.check, size: 16),
                    const SizedBox(width: 6),
                    Text(selected.label.isEmpty ? 'Microphone' : selected.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ));
                entries.add(const PopupMenuDivider());
                entries.add(const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('Available'),
                ));
              }
              for (final d in _audioInputs.where((d) => d.deviceId != _selectedMicId)) {
                entries.add(PopupMenuItem<String>(value: d.deviceId, child: Text(d.label.isEmpty ? 'Microphone' : d.label)));
              }
              if (entries.isEmpty) {
                entries.add(const PopupMenuItem<String>(value: 'none', child: Text('No microphones')));
              }
              return entries;
            },
            onSelected: (id) {
              if (id != 'none') _switchMicTo(id);
            },
          ),
        ),
      ),
    );

    final camToggle = Semantics(
      label: 'Toggle camera',
      button: true,
      child: ElevatedButton(
        focusNode: _focusCamToggle,
        onPressed: _toggleVideo,
        style: ButtonStyle(
          shape: MaterialStateProperty.all(const CircleBorder()),
          padding: MaterialStateProperty.all(const EdgeInsets.all(14)),
          elevation: MaterialStateProperty.resolveWith((states) =>
              states.contains(MaterialState.hovered) ? 6 : 0),
          backgroundColor: MaterialStateProperty.resolveWith((states) =>
              states.contains(MaterialState.pressed)
                  ? Colors.white.withOpacity(0.16)
                  : Colors.white.withOpacity(0.10)),
          foregroundColor: MaterialStateProperty.all(Colors.white),
        ),
        child: Icon(_videoEnabled ? Icons.videocam : Icons.videocam_off),
      ),
    );

    final camMenu = Semantics(
      label: 'Open camera devices menu',
      button: true,
      child: Focus(
        focusNode: _focusCamMenu,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.10),
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
            ],
          ),
          child: PopupMenuButton<String>(
            tooltip: 'Select camera',
            icon: const Icon(Icons.keyboard_arrow_up, size: 20, color: Colors.white),
            itemBuilder: (context) {
              final entries = <PopupMenuEntry<String>>[];
              if (_selectedCamId != null) {
                entries.add(const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('Selected', style: TextStyle(fontWeight: FontWeight.bold)),
                ));
                final selected = _videoInputs.firstWhere(
                  (d) => d.deviceId == _selectedCamId,
                  orElse: () => MediaDeviceInfo(label: 'Camera', deviceId: _selectedCamId ?? '', kind: 'videoinput'),
                );
                entries.add(PopupMenuItem<String>(
                  value: selected.deviceId,
                  child: Row(children: [
                    const Icon(Icons.check, size: 16),
                    const SizedBox(width: 6),
                    Text(selected.label.isEmpty ? 'Camera' : selected.label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ));
                entries.add(const PopupMenuDivider());
                entries.add(const PopupMenuItem<String>(
                  enabled: false,
                  child: Text('Available'),
                ));
              }
              for (final d in _videoInputs.where((d) => d.deviceId != _selectedCamId)) {
                entries.add(PopupMenuItem<String>(value: d.deviceId, child: Text(d.label.isEmpty ? 'Camera' : d.label)));
              }
              if (entries.isEmpty) {
                entries.add(const PopupMenuItem<String>(value: 'none', child: Text('No cameras')));
              }
              return entries;
            },
            onSelected: (id) {
              if (id != 'none') _switchCameraTo(id);
            },
          ),
        ),
      ),
    );

    final hangupBtn = Semantics(
      label: 'Hang up',
      button: true,
      child: ElevatedButton(
        focusNode: _focusHangup,
        style: ButtonStyle(
          shape: MaterialStateProperty.all(const CircleBorder()),
          padding: MaterialStateProperty.all(const EdgeInsets.all(16)),
          elevation: MaterialStateProperty.resolveWith((states) =>
              states.contains(MaterialState.hovered) ? 8 : 0),
          backgroundColor: MaterialStateProperty.all(const Color(0xFFE53935)),
          foregroundColor: MaterialStateProperty.all(Colors.white),
        ),
        onPressed: _hangup,
        child: const Icon(Icons.call_end),
      ),
    );

    final controls = FocusTraversalGroup(
      child: Wrap(
        spacing: 20,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [micToggle, const SizedBox(width: 8), micMenu]),
          Row(mainAxisSize: MainAxisSize.min, children: [camToggle, const SizedBox(width: 8), camMenu]),
          hangupBtn,
        ],
      ),
    );

    final mq = MediaQuery.of(context);
    final isNarrow = mq.size.width < 680 || mq.orientation == Orientation.portrait;
    final hasRemote = _peerJoined && _remoteRenderer.srcObject != null;

    Widget videos;
    if (_expandedTarget == null) {
      final localTile = Expanded(child: _videoView(_localRenderer, 'local'));
      if (hasRemote) {
        final remoteTile = Expanded(child: _videoView(_remoteRenderer, 'remote'));
        videos = isNarrow
            ? Column(children: [localTile, remoteTile])
            : Row(children: [localTile, remoteTile]);
      } else {
        videos = isNarrow ? Column(children: [localTile]) : Row(children: [localTile]);
      }
    } else {
      videos = (_expandedTarget == 'remote' && hasRemote)
          ? _videoView(_remoteRenderer, 'remote')
          : _videoView(_localRenderer, 'local');
    }

    return Scaffold(
      appBar: AppBar(title: Text('Room: ${widget.roomName}')),
      body: Column(
        children: [
          Expanded(child: videos),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 8)),
                    ],
                  ),
                  child: controls,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
