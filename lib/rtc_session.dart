import 'dart:async';
import 'dart:developer' as developer;
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
  MediaStream? _remoteVideoStream; // video-only container for renderer
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

  // lightweight logger to surface messages in release builds and web console
  void _log(String message) {
    final msg = '[RtcSession] $message';
    developer.log(msg, name: 'rtc');
    // Always print; on Flutter web this shows in DevTools console
    // ignore: avoid_print
    print(msg);
  }

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _log('Init: renderers initialized');
  }

  Future<void> _setupPeerConnection() async {
    _log('PeerConnection: creating with unified-plan + STUN');
    final configuration = {
      'iceServers': [
        {'urls': ['stun:stun.l.google.com:19302']},
      ],
      'sdpSemantics': 'unified-plan',
    };
    _pc = await createPeerConnection(configuration);

    // Removed explicit addTransceiver calls to avoid duplicate m-lines.
    // Local tracks will create appropriate transceivers; remote tracks are handled in onTrack/onAddStream.

    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      iceState = state;
      _log('ICE state: $state');
      notifyListeners();
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        _log('ICE failed; attempting ICE restart and renegotiation');
        _restartIceAndRenegotiate('ice_failed');
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        _ensureRemoteReceiving();
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      _log('Local ICE candidate: mid=${c.sdpMid} mline=${c.sdpMLineIndex}');
      // Send using server's expected signal wrapper
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {
          'type': 'candidate',
          'candidate': c.toMap(),
        }
      });
    };

    _pc!.onTrack = (RTCTrackEvent e) async {
      final kind = e.track.kind;
      _log('onTrack: kind=$kind id=${e.track.id} streams=${e.streams.length}');

      if (kind == 'video') {
        _remoteVideoStream ??= await createLocalMediaStream('remotev');
        final vstream = _remoteVideoStream!;
        final exists = vstream.getVideoTracks().any((t) => t.id == e.track.id);
        if (!exists) {
          await vstream.addTrack(e.track);
          _log('Remote video track attached to video-only stream: id=${e.track.id}');
        }
        remoteRenderer.srcObject = vstream;
        notifyListeners();
        return;
      }

      // Audio or other tracks
      if (e.streams.isEmpty) {
        _remoteStream ??= await createLocalMediaStream('remote');
        _remoteStream!.addTrack(e.track);
        _log('Remote ${kind} track attached via synthetic stream: id=${_remoteStream!.id}');
      } else {
        _remoteStream = e.streams.first;
        _log('Remote stream attached: id=${_remoteStream!.id}');
      }
      // Keep renderer pointed at video-only stream if present; otherwise use full stream
      if (_remoteVideoStream == null) {
        remoteRenderer.srcObject = _remoteStream;
      }
      notifyListeners();
    };

    // Fallback for older/Plan-B style backends
    _pc!.onAddStream = (MediaStream stream) {
      _remoteStream = stream;
      remoteRenderer.srcObject = _remoteStream;
      _log('onAddStream: remote stream attached: id=${_remoteStream!.id}');
      notifyListeners();
    };

    // Attach existing local tracks if media already started
    if (_localStream != null) {
      _log('Attaching existing local tracks: count=${_localStream!.getTracks().length}');
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
      _log('getUserMedia constraints: ${constraints.toString()}');
      final stream = await navigator.mediaDevices.getUserMedia(constraints);
      mediaError = null; // clear previous error on success
      _localStream = stream;
      localRenderer.srcObject = _localStream;
      _log('Local media acquired: id=${stream.id} tracks=${stream.getTracks().length}');

      for (final track in stream.getTracks()) {
        await _pc?.addTrack(track, stream);
      }
      // Refresh device list after permissions to reveal full set and labels
      await loadDevices();
      notifyListeners();
    } catch (e) {
      // Capture error for UI surfaces; common causes: permission denied, insecure context
      mediaError = e.toString();
      _log('getUserMedia error: $mediaError');
      notifyListeners();
    }
  }

  Future<void> join(String roomName, {SignalingClient? client}) async {
    _roomName = roomName;
    _sig = client ?? SignalingClient.fromEnv();
    _log('Connecting signaling at ${_sig!.uri}');
    await _sig!.connect();
    wsConnected = _sig!.isConnected;
    _log('Signaling connected: $wsConnected');
    notifyListeners();

    await _setupPeerConnection();
    await _setupLocalMedia();

    _log('Listening to signaling messages');
    _sig!.messages.listen(_onSignal);
    _log('Joining room: $roomName');
    _sig!.join(roomName);
  }

  Future<void> _onSignal(Map<String, dynamic> msg) async {
    final type = msg['type'];
    _log('Signal recv: $type ${msg.keys.toList()}');

    // Handle wrapped signal payloads from server
    if (type == 'signal') {
      final payload = msg['payload'];
      final ptype = payload is Map<String, dynamic> ? payload['type'] : null;
      _log('Signal payload: $ptype');
      if (ptype == 'offer' && payload['sdp'] != null) {
        _log('Offer(received via wrapper): sdpLen=${(payload['sdp'] as String).length}');
        await _pc?.setRemoteDescription(
            RTCSessionDescription(payload['sdp'], 'offer'));
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        _log('Answer(created): sdpLen=${answer.sdp?.length ?? 0}');
        _sig?.send({
          'type': 'signal',
          'room': _roomName,
          'payload': {'type': 'answer', 'sdp': answer.sdp},
        });
        _ensureRemoteReceiving();
        return;
      } else if (ptype == 'answer' && payload['sdp'] != null) {
        _log('Answer(received via wrapper): sdpLen=${(payload['sdp'] as String).length}');
        await _pc?.setRemoteDescription(
            RTCSessionDescription(payload['sdp'], 'answer'));
        _ensureRemoteReceiving();
        return;
      } else if ((ptype == 'candidate' || ptype == 'ice') && payload['candidate'] != null) {
        final c = payload['candidate'];
        try {
          _log('Remote ICE candidate(via wrapper): mid=${c['sdpMid']} mline=${c['sdpMLineIndex']}');
          await _pc?.addCandidate(
              RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        } catch (e) {
          _log('addCandidate error: $e');
        }
        return;
      }
    }

    // Backward compatibility for unwrapped messages
    switch (type) {
      case 'joined':
        peerJoined = true;
        _log('Peer joined/acknowledged');
        notifyListeners();
        break;
      case 'peer_joined':
        _log('Peer joined event');
        break;
      case 'offer':
        if (msg['sdp'] != null) {
          _log('Offer received: sdpLen=${(msg['sdp'] as String).length}');
          await _pc?.setRemoteDescription(
              RTCSessionDescription(msg['sdp'], 'offer'));
          final answer = await _pc!.createAnswer();
          var sdpA = answer.sdp ?? '';
          sdpA = _preferH264(sdpA);
          await _pc!.setLocalDescription(RTCSessionDescription(sdpA, 'answer'));
          _log('Answer created: sdpLen=${sdpA.length}');
          _sig?.send({
            'type': 'signal',
            'room': _roomName,
            'payload': {'type': 'answer', 'sdp': sdpA},
          });
          _ensureRemoteReceiving();
        }
        break;
      case 'answer':
        if (msg['sdp'] != null) {
          _log('Answer received: sdpLen=${(msg['sdp'] as String).length}');
          await _pc?.setRemoteDescription(
              RTCSessionDescription(msg['sdp'], 'answer'));
          _ensureRemoteReceiving();
        }
        break;
      case 'ice':
      case 'candidate':
        final c = msg['candidate'];
        if (c != null) {
          try {
            _log('Remote ICE candidate: mid=${c['sdpMid']} mline=${c['sdpMLineIndex']}');
            await _pc?.addCandidate(RTCIceCandidate(
                c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
          } catch (e) {
            _log('addCandidate error: $e');
          }
        }
        break;
      case 'ready':
      case 'start_negotiation':
        _log('Negotiation trigger: $type');
        _startCall();
        break;
      case 'ws_closed':
        wsConnected = false;
        _log('WS closed');
        notifyListeners();
        break;
      case 'ws_error':
        wsConnected = false;
        lastError = msg['error'] as String?;
        _log('WS error: $lastError');
        notifyListeners();
        break;
    }
  }

  Future<void> _attachRemoteReceivers() async {
    try {
      final receivers = await _pc?.getReceivers() ?? [];
      if (receivers.isEmpty) {
        _log('No remote receivers yet');
        return;
      }
      _remoteStream ??= await createLocalMediaStream('remote');
      final remote = _remoteStream!;
      for (final r in receivers) {
        final track = r.track;
        if (track != null) {
          final exists = remote.getTracks().any((t) => t.id == track.id);
          if (!exists) {
            await remote.addTrack(track);
            _log('Attached receiver ${track.kind} id=${track.id}');
          }
        }
      }
      if (remote.getTracks().isNotEmpty) {
        remoteRenderer.srcObject = remote;
        notifyListeners();
      }
    } catch (e) {
      _log('attach receivers error: $e');
    }
  }

  Future<void> _ensureRemoteReceiving() async {
    try {
      final receivers = await _pc?.getReceivers() ?? [];
      final hasVideo = receivers.any((r) => r.track?.kind == 'video');
      final hasAudio = receivers.any((r) => r.track?.kind == 'audio');
      _log('Receivers count=${receivers.length} hasVideo=$hasVideo hasAudio=$hasAudio');
      if (receivers.isNotEmpty) {
        await _attachRemoteReceivers();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 600));
      final receivers2 = await _pc?.getReceivers() ?? [];
      if (receivers2.isEmpty) {
        _log('No remote receivers after delay; triggering renegotiation');
        _restartIceAndRenegotiate('no_remote_receivers');
      } else {
        await _attachRemoteReceivers();
      }
    } catch (e) {
      _log('ensure remote receiving error: $e');
    }
  }

  Future<void> _startCall() async {
    if (_pc == null) return;
    try {
      _log('Creating offer...');
      final offer = await _pc!.createOffer();
      var sdp = offer.sdp ?? '';
      sdp = _preferH264(sdp);
      final mungedOffer = RTCSessionDescription(sdp, 'offer');
      _log('Offer created: sdpLen=${sdp.length}');
      await _pc!.setLocalDescription(mungedOffer);
      _log('Local description set');
      // Send using server's expected signal wrapper
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {'type': 'offer', 'sdp': sdp},
      });
      _log('Offer sent');
    } catch (e) {
      _log('Start call error: $e');
    }
  }

  Future<void> _restartIceAndRenegotiate(String reason) async {
    renegotiationAttempts++;
    try {
      _log('ICE restart + renegotiate, reason=$reason');
      final offer = await _pc!.createOffer({'iceRestart': true});
      var sdp = offer.sdp ?? '';
      sdp = _preferH264(sdp);
      await _pc!.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {'type': 'offer', 'sdp': sdp, 'reason': reason},
      });
    } catch (e) {
      _log('Renegotiate error: $e');
    }
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
    } catch (e) {
      _log('addIceCandidate error: $e');
    }
  }

  Future<void> hangup() async {
    try {
      _log('Hangup: closing signaling and peer connection');
      await _sig?.close();
      await _pc?.close();
      await localRenderer.dispose();
      await remoteRenderer.dispose();
    } catch (e) {
      _log('Hangup error: $e');
    }
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

  String _preferH264(String sdp) {
    try {
      final lines = sdp.split('\n');
      final mVideoIndex = lines.indexWhere((l) => l.startsWith('m=video'));
      if (mVideoIndex == -1) return sdp;

      // Map payload type -> codec name and params
      final rtpmap = <int, String>{};
      final fmtp = <int, String>{};
      final rtcpfb = <int, List<String>>{};
      for (final l in lines) {
        final m1 = RegExp(r'^a=rtpmap:(\\d+)\\s+([A-Za-z0-9\-]+)/').firstMatch(l);
        if (m1 != null) {
          final pt = int.parse(m1.group(1)!);
          final codec = (m1.group(2) ?? '').toUpperCase();
          rtpmap[pt] = codec;
          continue;
        }
        final m2 = RegExp(r'^a=fmtp:(\\d+)\\s+(.+)$').firstMatch(l);
        if (m2 != null) {
          final pt = int.parse(m2.group(1)!);
          fmtp[pt] = m2.group(2) ?? '';
          continue;
        }
        final m3 = RegExp(r'^a=rtcp-fb:(\\d+)\\s+(.+)$').firstMatch(l);
        if (m3 != null) {
          final pt = int.parse(m3.group(1)!);
          (rtcpfb[pt] ??= []).add(m3.group(2) ?? '');
          continue;
        }
      }

      int scorePt(int pt) {
        final params = (fmtp[pt] ?? '').toLowerCase();
        final pkt = params.contains('packetization-mode=1') ? 2 : 0;
        final profMatch = RegExp(r'profile-level-id=([0-9a-fA-F]+)').firstMatch(params);
        final prof = profMatch?.group(1)?.toLowerCase() ?? '';
        final baseline = prof.startsWith('42e0') ? 3 : 0;
        return baseline + pkt;
      }

      final parts = lines[mVideoIndex].split(' ');
      final header = parts.take(3).toList();
      final payloads = parts
          .skip(3)
          .map((p) => int.tryParse(p))
          .whereType<int>()
          .toList();

      // Collect available H264 payloads in m=video
      final h264Present = payloads.where((pt) => rtpmap[pt] == 'H264').toList();
      if (h264Present.isEmpty) {
        // No H264 in SDP; keep as-is
        return sdp;
      }

      // Choose best H264 payload (baseline + pkt-mode=1 preferred)
      h264Present.sort((a, b) => scorePt(b).compareTo(scorePt(a)));
      final bestH264 = h264Present.first;

      // Strict: advertise only best H264 payload to force compatible codec
      final newPayloads = [bestH264];
      lines[mVideoIndex] = '${header.join(' ')} ${newPayloads.join(' ')}';

      // Remove non-selected payload definitions (rtpmap/fmtp/rtcp-fb)
      final allowed = newPayloads.toSet();
      final filtered = <String>[];
      for (final l in lines) {
        // Keep all non-codec lines and codec lines for allowed payload
        final rmRtpmap = RegExp(r'^a=rtpmap:(\\d+)').firstMatch(l);
        final rmFmtp = RegExp(r'^a=fmtp:(\\d+)').firstMatch(l);
        final rmFb = RegExp(r'^a=rtcp-fb:(\\d+)').firstMatch(l);
        if (rmRtpmap != null || rmFmtp != null || rmFb != null) {
          final pt = int.parse((rmRtpmap ?? rmFmtp ?? rmFb)!.group(1)!);
          if (!allowed.contains(pt)) {
            continue; // drop lines for non-selected payloads
          }
        }
        filtered.add(l);
      }

      _log('SDP munged: forced H264 payload=${bestH264} (baseline preferred)');
      return filtered.join('\n');
    } catch (_) {
      return sdp;
    }
  }
}