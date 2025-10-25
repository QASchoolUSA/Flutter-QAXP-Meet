import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'signaling.dart';

class RtcSession extends ChangeNotifier {
  // Renderers
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // WebRTC state
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  RTCPeerConnection? _pc;
  RTCIceConnectionState? iceState;

  // Signaling
  SignalingClient? _sig;
  String? _roomName;

  // Connection and error state
  bool wsConnected = false;
  String? lastError;
  String? mediaError; // new: user media error surface

  // Peer state
  bool peerJoined = false;
  int renegotiationAttempts = 0;

  // Device selection state
  List<MediaDeviceInfo> audioInputs = [];
  List<MediaDeviceInfo> videoInputs = [];
  String? selectedAudioInputId;
  String? selectedVideoInputId;

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  Future<void> _setupPeerConnection() async {
    final configuration = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
      'sdpSemantics': 'unified-plan',
    };
    _pc = await createPeerConnection(configuration);

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      iceState = state;
      notifyListeners();
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _restartIceAndRenegotiate('ice_failed');
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      _sig?.send({'type': 'ice', 'candidate': c.toMap()});
    };

    _pc!.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        _remoteStream = e.streams.first;
        remoteRenderer.srcObject = _remoteStream;
        notifyListeners();
      }
    };

    // Attach existing local tracks if media already started
    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }
    }
  }

  Future<void> _setupLocalMedia({bool audio = true, bool video = true}) async {
    final audioConstraints = selectedAudioInputId == null
        ? (audio ? true : false)
        : {
            'deviceId': selectedAudioInputId,
          };
    final isMobile = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    final videoConstraints = video
        ? (kIsWeb
            ? (selectedVideoInputId == null
                ? {'facingMode': 'user'}
                : {
                    'deviceId': selectedVideoInputId,
                  })
            : (isMobile ? {'facingMode': 'user'} : true))
        : false;

    final constraints = {
      'audio': audioConstraints,
      'video': videoConstraints,
    };

    try {
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      mediaError = null; // clear previous error on success
      _localStream = stream;
      localRenderer.srcObject = _localStream;

      for (final track in stream.getTracks()) {
        await _pc?.addTrack(track, stream);
      }
      // Refresh device list after permissions to reveal full set and labels
      await loadDevices();
      notifyListeners();
    } catch (e) {
      // Capture error for UI surfaces; common causes: permission denied, insecure context
      mediaError = e.toString();
      notifyListeners();
    }
  }

  Future<void> join(String roomName, {SignalingClient? client}) async {
    _roomName = roomName;
    _sig = client ?? SignalingClient.fromEnv();
    await _sig!.connect();
    wsConnected = _sig!.isConnected;
    notifyListeners();

    await _setupPeerConnection();
    await _setupLocalMedia();

    _sig!.messages.listen(_onSignal);
    _sig!.join(roomName);
  }

  Future<void> _onSignal(Map<String, dynamic> msg) async {
    switch (msg['type']) {
      case 'joined':
        peerJoined = true;
        notifyListeners();
        break;
      case 'offer':
        if (msg['sdp'] != null) {
          await _pc?.setRemoteDescription(
              RTCSessionDescription(msg['sdp'], 'offer'));
          final answer = await _pc!.createAnswer();
          await _pc!.setLocalDescription(answer);
          _sig?.send({'type': 'answer', 'sdp': answer.sdp});
        }
        break;
      case 'answer':
        if (msg['sdp'] != null) {
          await _pc?.setRemoteDescription(
              RTCSessionDescription(msg['sdp'], 'answer'));
        }
        break;
      case 'ice':
      case 'candidate':
        final c = msg['candidate'];
        if (c != null) {
          try {
            await _pc?.addCandidate(RTCIceCandidate(
                c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
          } catch (_) {}
        }
        break;
      case 'ready':
      case 'start_negotiation':
        _startCall();
        break;
      case 'ws_closed':
        wsConnected = false;
        notifyListeners();
        break;
      case 'ws_error':
        wsConnected = false;
        lastError = msg['error'] as String?;
        notifyListeners();
        break;
    }
  }

  Future<void> _startCall() async {
    if (_pc == null) return;
    try {
      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      _sig?.send({'type': 'offer', 'sdp': offer.sdp});
    } catch (_) {}
  }

  Future<void> _restartIceAndRenegotiate(String reason) async {
    renegotiationAttempts++;
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      _sig?.send({'type': 'offer', 'sdp': offer.sdp, 'reason': reason});
    } catch (_) {}
  }

  bool get micEnabled {
    final tracks = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    return tracks.isEmpty ? true : tracks.first.enabled;
  }

  bool get videoEnabled {
    final tracks = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    return tracks.isEmpty ? true : tracks.first.enabled;
  }

  Future<void> toggleMic() async {
    final tracks = _localStream?.getAudioTracks() ?? [];
    for (final t in tracks) {
      t.enabled = !t.enabled;
    }
    notifyListeners();
  }

  Future<void> toggleVideo() async {
    final tracks = _localStream?.getVideoTracks() ?? [];
    for (final t in tracks) {
      t.enabled = !t.enabled;
    }
    notifyListeners();
  }

  Future<void> addIceCandidate(Map<String, dynamic> candidate) async {
    try {
      await _pc?.addCandidate(RTCIceCandidate(
          candidate['candidate'], candidate['sdpMid'], candidate['sdpMLineIndex']));
    } catch (_) {}
  }

  Future<void> hangup() async {
    try {
      await _sig?.close();
      await _pc?.close();
      await localRenderer.dispose();
      await remoteRenderer.dispose();
    } catch (_) {}
  }

  Future<void> reconnect() async {
    if (_roomName == null) return;
    try {
      _sig ??= SignalingClient.fromEnv();
      await _sig!.connect();
      wsConnected = _sig!.isConnected;
      if (wsConnected) {
        _sig!.join(_roomName!);
      }
    } catch (_) {}
    notifyListeners();
  }

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  void clearMediaError() {
    mediaError = null;
    notifyListeners();
  }

  // Device enumeration and selection
  Future<void> loadDevices() async {
    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
      videoInputs = devices.where((d) => d.kind == 'videoinput').toList();
      selectedAudioInputId ??= audioInputs.isNotEmpty ? audioInputs.first.deviceId : null;
      selectedVideoInputId ??= videoInputs.isNotEmpty ? videoInputs.first.deviceId : null;
      notifyListeners();
    } catch (_) {
      // ignore enumeration errors
    }
  }

  Future<void> setAudioInput(String deviceId) async {
    selectedAudioInputId = deviceId;
    await _restartLocalMedia();
  }

  Future<void> setVideoInput(String deviceId) async {
    selectedVideoInputId = deviceId;
    await _restartLocalMedia();
  }

  Future<void> _restartLocalMedia() async {
    // Stop existing tracks
    try {
      for (final t in _localStream?.getTracks() ?? []) {
        await t.stop();
      }
      await _localStream?.dispose();
    } catch (_) {}

    await _setupLocalMedia(audio: true, video: true);

    // Replace tracks in senders if possible
    final senders = await _pc?.getSenders() ?? [];
    final audioTracks = _localStream?.getAudioTracks() ?? [];
    final videoTracks = _localStream?.getVideoTracks() ?? [];
    final newAudio = audioTracks.isNotEmpty ? audioTracks.first : null;
    final newVideo = videoTracks.isNotEmpty ? videoTracks.first : null;
    for (final s in senders) {
      final kind = s.track?.kind;
      if (kind == 'audio' && newAudio != null) {
        try {
          await s.replaceTrack(newAudio);
        } catch (_) {}
      } else if (kind == 'video' && newVideo != null) {
        try {
          await s.replaceTrack(newVideo);
        } catch (_) {}
      }
    }

    // Re-enumerate devices after switching to ensure menu stays accurate
    await loadDevices();
    notifyListeners();
  }
}