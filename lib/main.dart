import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
                    const Text('Local preview only (signaling disabled).',
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
  RTCPeerConnection? _pc;
  MediaStream? _localStream;

  bool _micEnabled = true;
  bool _videoEnabled = true;
  String? _role; // 'caller' | 'callee'
  bool _peerJoined = false;

  String? _expandedTarget; // 'local' | 'remote' | null

  List<MediaDeviceInfo> _audioInputs = [];
  List<MediaDeviceInfo> _videoInputs = [];
  String? _selectedMicId;
  String? _selectedCamId;

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
    final Map<String, dynamic> constraints = {
      'audio': _selectedMicId != null ? {'deviceId': _selectedMicId} : true,
      'video': _selectedCamId != null ? {'deviceId': _selectedCamId} : true,
    };
    final stream = await navigator.mediaDevices.getUserMedia(constraints);
    _localStream = stream;
    _localRenderer.srcObject = _localStream;
  }

  Future<void> _setupSignalingAndRTC() async {
    // Local-only mode: no signaling, no remote peer connection.
    // Just keep local preview active.
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
    await _pc?.close();
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    await _localStream?.dispose();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _hangup();
    super.dispose();
  }

  Widget _videoView(RTCVideoRenderer renderer, String label) {
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
          child: RTCVideoView(renderer, mirror: label == 'local'),
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
