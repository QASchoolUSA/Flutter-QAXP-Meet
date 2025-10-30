import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web/web.dart' as web;
import 'dart:js_interop';
import 'dart:js_util' as js_util;

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
  String? role; // 'caller' | 'callee' | null

  // Device selection state
  List<MediaDeviceInfo> audioInputs = [];
  List<MediaDeviceInfo> videoInputs = [];
  String? selectedAudioInputId;
  String? selectedVideoInputId;

  // Performance/guard flags
  bool _ensureRemoteReceivingRunning = false;
  bool _proactiveTransceiversAdded = false;
  bool _renegotiationRunning = false;
  bool _sendersTuned = false;
  // Call-wide audio recording (via flutter_webrtc MediaRecorder)
  MediaStream? _mixStream;
  MediaRecorder? _recorder;
  // Web recording pipeline (WebAudio + MediaRecorder)
  web.AudioContext? _audioCtx;
  web.MediaStreamAudioDestinationNode? _destNode;
  web.MediaRecorder? _webRecorder;
  web.Blob? _lastBlob;
  // Fallback composite stream for recording without WebAudio mix
  web.MediaStream? _compositeStream;
  bool isRecording = false;
  bool _hangupCalled = false; // guard to avoid double-stop/upload
  bool uploadInProgress = false;
  double uploadProgress = 0.0; // 0.0..1.0
  String? recordingStatus; // human-readable state
  Uri? recordUploadUrl; // set by app for server upload
  bool _webRecorderStartRetryScheduled = false; // throttle deferred starts

  // lightweight logger to surface messages in release builds and web console
  void _log(String message) {
    final msg = '[RtcSession] $message';
    developer.log(msg, name: 'rtc');
    // Always print; on Flutter web this shows in DevTools console
    // ignore: avoid_print
    print(msg);
  }

  // Attempt to resume the WebAudio context if it is suspended (requires a user gesture on some browsers)
  void resumeWebAudioIfNeeded() {
    if (!kIsWeb) return;
    try {
      if (_audioCtx != null) {
        final state = _audioCtx!.state;
        _log('AudioContext state before resume: $state');
        // On Chrome/Safari, state is 'suspended' until resumed after a user gesture
        if (state == 'suspended') {
          _audioCtx!.resume();
          // Re-check shortly after attempting resume
          Future.delayed(const Duration(milliseconds: 100), () {
            try {
              _log('AudioContext state after resume: ${_audioCtx!.state}');
            } catch (_) {}
          });
        }
      }
    } catch (_) {}
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
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
      'iceCandidatePoolSize': 10,
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
        _tuneSenderEncodings();
        _ensureRemoteReceiving();
      }
    };

    _pc!.onIceCandidate = (RTCIceCandidate c) {
      _log('Local ICE candidate: mid=${c.sdpMid} mline=${c.sdpMLineIndex}');
      // Send using server's expected signal wrapper with explicit fields
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {
          'type': 'candidate',
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        }
      });
    };

    _pc!.onTrack = (RTCTrackEvent e) async {
      final kind = e.track.kind;
      _log('onTrack: kind=$kind id=${e.track.id} streams=${e.streams.length}');

      // Prefer the peer-provided stream; otherwise merge into a single remote container
      MediaStream? target;
      if (e.streams.isNotEmpty) {
        target = e.streams.first;
        // Guard: do not attach our own local stream as remote
        if (_localStream != null && target.id == _localStream!.id) {
          _log('onTrack guard: peer-provided stream matches local; using synthetic remote container');
          _remoteStream ??= await createLocalMediaStream('remote');
          final exists = _remoteStream!.getTracks().any((t) => t.id == e.track.id);
          if (!exists) {
            await _remoteStream!.addTrack(e.track);
          }
          target = _remoteStream;
        } else {
          _remoteStream = target;
          _log('Remote stream attached (from peer): id=${target.id}');
        }
      } else {
        _remoteStream ??= await createLocalMediaStream('remote');
        final exists = _remoteStream!.getTracks().any((t) => t.id == e.track.id);
        if (!exists) {
          await _remoteStream!.addTrack(e.track);
          _log('Remote $kind track merged into synthetic stream: id=${_remoteStream!.id}');
        }
        target = _remoteStream;
      }

      remoteRenderer.srcObject = target;
      notifyListeners();
      // On some web engines, forcing a reattach helps the element start rendering
      if (kIsWeb && kind == 'video') {
        await Future.delayed(const Duration(milliseconds: 0));
        remoteRenderer.srcObject = target;
        notifyListeners();
      }
      if (kind == 'audio') {
        // Connect to web recorder destination if active
        if (kIsWeb && _destNode != null) {
          try {
            final remoteWeb = _asWebMediaStream(_remoteStream ?? target);
            if (remoteWeb != null && _audioCtx != null) {
              final src = _audioCtx!.createMediaStreamSource(remoteWeb);
              src.connect(_destNode!);
              // Ensure audio context is running so recorder receives audio
              resumeWebAudioIfNeeded();
            }
          } catch (_) {}
        }
        // If composite recorder is active, append any new audio tracks
        if (kIsWeb && _compositeStream != null) {
          try {
            final remoteWeb = _asWebMediaStream(_remoteStream ?? target);
            if (remoteWeb != null) {
              final tracks = remoteWeb.getAudioTracks().toDart;
              final existingTracks = _compositeStream!.getAudioTracks().toDart;
              for (final t in tracks) {
                // Avoid duplicates by id
                final id = js_util.getProperty(t, 'id').toString();
                final existing = existingTracks.any((et) =>
                    js_util.getProperty(et, 'id').toString() == id);
                if (!existing) {
                  _compositeStream!.addTrack(t);
                }
              }
            }
          } catch (_) {}
        }
        // Maintain mixed stream for potential native recorder
        await _ensureMixStream();
        await _maybeAddStreamToMix(_remoteStream ?? target);
      }
    };

    // Fallback for older/Plan-B style backends
    _pc!.onAddStream = (MediaStream stream) async {
      // Guard: do not attach our own local stream as remote
      if (_localStream != null && stream.id == _localStream!.id) {
        _log('onAddStream guard: incoming stream matches local; importing tracks only');
        _remoteStream ??= await createLocalMediaStream('remote');
        for (final t in stream.getTracks()) {
          final exists = _remoteStream!.getTracks().any((rt) => rt.id == t.id);
          if (!exists) {
            await _remoteStream!.addTrack(t);
          }
        }
        remoteRenderer.srcObject = _remoteStream;
        notifyListeners();
        return;
      }
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
    final audioConstraints = audio
        ? {
            if (selectedAudioInputId != null && (selectedAudioInputId?.isNotEmpty ?? false))
              'deviceId': kIsWeb ? {'exact': selectedAudioInputId} : selectedAudioInputId,
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
            'sampleRate': 48000,
            'channelCount': 2,
          }
        : false;
    final videoConstraints = video
        ? {
            if (kIsWeb && selectedVideoInputId != null && (selectedVideoInputId?.isNotEmpty ?? false))
              'deviceId': {'exact': selectedVideoInputId},
            'facingMode': 'user',
            'width': {'ideal': 1280, 'max': 1920, 'min': 640},
            'height': {'ideal': 720, 'max': 1080, 'min': 480},
            'frameRate': {'ideal': 30, 'max': 60, 'min': 15},
          }
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

      // Default video disabled; can be toggled on by UI
      final videoTracks = stream.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        try {
          videoTracks.first.enabled = false;
          await videoTracks.first.applyConstraints({
            'width': {'ideal': 1280, 'max': 1920},
            'height': {'ideal': 720, 'max': 1080},
            'frameRate': {'ideal': 30, 'max': 60},
            'advanced': [
              {'width': {'min': 640}},
              {'height': {'min': 480}},
              {'frameRate': {'min': 15}},
            ],
          });
        } catch (e) {
          _log('applyConstraints(video) not supported or failed: $e');
        }
      }

      for (final track in stream.getTracks()) {
        await _pc?.addTrack(track, stream);
      }
      await _ensureMixStream();
      await _maybeAddStreamToMix(_localStream);
      // Connect local audio to web recorder destination if active
      if (kIsWeb && _destNode != null) {
        try {
          final localWeb = _asWebMediaStream(_localStream);
          if (localWeb != null && _audioCtx != null) {
            final src = _audioCtx!.createMediaStreamSource(localWeb);
            src.connect(_destNode!);
            // Ensure audio context is running so recorder receives audio
            resumeWebAudioIfNeeded();
          }
        } catch (_) {}
      }
      // If composite recorder is active, append local audio tracks
      if (kIsWeb && _compositeStream != null) {
        try {
          final localWeb2 = _asWebMediaStream(_localStream);
          if (localWeb2 != null) {
            final tracks = localWeb2.getAudioTracks().toDart;
            final existingTracks = _compositeStream!.getAudioTracks().toDart;
            for (final t in tracks) {
              final id = js_util.getProperty(t, 'id').toString();
              final exists = existingTracks.any((et) =>
                  js_util.getProperty(et, 'id').toString() == id);
              if (!exists) {
                _compositeStream!.addTrack(t);
              }
            }
          }
        } catch (_) {}
      }
      // Refresh device list after permissions to reveal full set and labels
      await loadDevices();
      // Try resuming WebAudio after user granted media permissions
      resumeWebAudioIfNeeded();
      notifyListeners();
    } catch (e) {
      // Capture error for UI surfaces; common causes: permission denied, insecure context
      mediaError = e.toString();
      _log('getUserMedia error: $mediaError');
      // Retry without deviceId if OverconstrainedError/NotFound or empty device IDs present
      final isOver = mediaError?.contains('OverconstrainedError') == true || mediaError?.contains('NotFoundError') == true;
      final hadEmptyIds = (selectedAudioInputId != null && (selectedAudioInputId?.isEmpty ?? false)) || (selectedVideoInputId != null && (selectedVideoInputId?.isEmpty ?? false));
      if (isOver || hadEmptyIds) {
        try {
          _log('Retrying getUserMedia without deviceId constraints');
          final retryConstraints = {
            'audio': audio ? {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
              'sampleRate': 48000,
              'channelCount': 2,
            } : false,
            'video': video ? {
              'facingMode': 'user',
              'width': {'ideal': 1280, 'max': 1920, 'min': 640},
              'height': {'ideal': 720, 'max': 1080, 'min': 480},
              'frameRate': {'ideal': 30, 'max': 60, 'min': 15},
            } : false,
          };
          final stream2 = await navigator.mediaDevices.getUserMedia(retryConstraints);
          mediaError = null;
          _localStream = stream2;
          localRenderer.srcObject = _localStream;
          _log('Local media acquired on retry: id=${stream2.id}');
          final videoTracks2 = stream2.getVideoTracks();
          if (videoTracks2.isNotEmpty) {
            try {
              videoTracks2.first.enabled = false;
            } catch (_) {}
          }
          for (final track in stream2.getTracks()) {
            await _pc?.addTrack(track, stream2);
          }
          await _ensureMixStream();
          await _maybeAddStreamToMix(_localStream);
          // Connect local audio to web recorder destination if active (retry)
          if (kIsWeb && _destNode != null) {
            try {
              final localWeb2 = _asWebMediaStream(_localStream);
              if (localWeb2 != null && _audioCtx != null) {
                final src2 = _audioCtx!.createMediaStreamSource(localWeb2);
                src2.connect(_destNode!);
              }
            } catch (_) {}
          }
          // If composite recorder is active, append local audio tracks (retry)
          if (kIsWeb && _compositeStream != null) {
            try {
              final localWeb3 = _asWebMediaStream(_localStream);
              if (localWeb3 != null) {
                final tracks3 = localWeb3.getAudioTracks().toDart;
                final existingTracks3 = _compositeStream!.getAudioTracks().toDart;
                for (final t in tracks3) {
                  final id3 = js_util.getProperty(t, 'id').toString();
                  final exists3 = existingTracks3.any((et) =>
                      js_util.getProperty(et, 'id').toString() == id3);
                  if (!exists3) {
                    _compositeStream!.addTrack(t);
                  }
                }
              }
            } catch (_) {}
          }
          await loadDevices();
          notifyListeners();
        } catch (e2) {
          _log('Retry getUserMedia failed: $e2');
          notifyListeners();
        }
      } else {
        notifyListeners();
      }
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
        final sdpA = answer.sdp ?? '';
        await _pc!.setLocalDescription(RTCSessionDescription(sdpA, 'answer'));
        _log('Answer(created): sdpLen=${sdpA.length}');
        _sig?.send({
          'type': 'signal',
          'room': _roomName,
          'payload': {'type': 'answer', 'sdp': sdpA},
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
        final candAny = payload['candidate'];
        String? candStr;
        String? sdpMid;
        int? sdpMLineIndex;
        if (candAny is String) {
          candStr = candAny;
          sdpMid = payload['sdpMid'] as String?;
          sdpMLineIndex = payload['sdpMLineIndex'] as int?;
          _log('Remote ICE(candidate wrapper, flat): mid=$sdpMid mline=$sdpMLineIndex');
        } else if (candAny is Map<String, dynamic>) {
          candStr = candAny['candidate'] as String?;
          sdpMid = candAny['sdpMid'] as String?;
          sdpMLineIndex = candAny['sdpMLineIndex'] as int?;
          _log('Remote ICE(candidate wrapper, map): mid=$sdpMid mline=$sdpMLineIndex');
        }
        if (candStr != null) {
          try {
            await _pc?.addCandidate(RTCIceCandidate(candStr, sdpMid, sdpMLineIndex));
          } catch (e) {
            _log('addCandidate(wrapper) error: $e');
          }
        }
        return;
      }
    }

    // Backward compatibility for unwrapped messages
    switch (type) {
      case 'joined':
        peerJoined = true;
        role = msg['role'] as String?;
        _log('Peer joined/acknowledged; role=${role ?? 'unknown'}');
        notifyListeners();
        try {
          final ld = await _pc?.getLocalDescription();
          final rd = await _pc?.getRemoteDescription();
          if ((role == 'caller') && rd == null && (ld == null || ld.type != 'offer')) {
            _log('Joined as caller; creating offer');
            _startCall();
          }
        } catch (_) {}
        // Proactive negotiation kick for callee/unknown roles
        try {
          final ld2 = await _pc?.getLocalDescription();
          final rd2 = await _pc?.getRemoteDescription();
          if ((role != 'caller') && rd2 == null && (ld2 == null || ld2.type != 'offer')) {
            _log('Joined as callee/unknown; sending ready to prompt negotiation');
            _sig?.send({'type': 'ready', 'room': _roomName});
          }
        } catch (e) {
          _log('Joined ready send error: $e');
        }
        break;
      case 'peer_joined':
      case 'peer-joined':
        _log('Peer joined event');
        try {
          final ld = await _pc?.getLocalDescription();
          final rd = await _pc?.getRemoteDescription();
          if ((role == 'caller' || role == null) && rd == null && (ld == null || ld.type != 'offer')) {
            _log('Peer joined trigger; creating offer');
            _startCall();
          }
        } catch (e) {
          _log('Peer joined negotiation error: $e');
        }
        break;
      case 'peer_left':
      case 'peer-left':
      case 'leave':
        _log('Peer left - clearing remote renderer and stream');
        try {
          // Stop and clear any remote tracks to release the last frame
          final rs = _remoteStream;
          if (rs != null) {
            for (final t in rs.getTracks()) {
              try {
                t.stop();
              } catch (_) {}
            }
          }
          remoteRenderer.srcObject = null;
          _remoteStream = null;
          peerJoined = false;
          notifyListeners();
        } catch (e) {
          _log('Peer left cleanup error: $e');
        }
        break;
      case 'offer':
        {
          final sdpOffer = msg['sdp'] as String? ??
              (msg['offer'] is Map ? (msg['offer']['sdp'] as String?) : null);
          if (sdpOffer != null) {
            _log('Offer received: sdpLen=${sdpOffer.length}');
            await _pc?.setRemoteDescription(
                RTCSessionDescription(sdpOffer, 'offer'));
            final answer = await _pc!.createAnswer();
            var sdpA = answer.sdp ?? '';
            if (kIsWeb) {
              sdpA = _preferH264(sdpA);
            }
            await _pc!.setLocalDescription(RTCSessionDescription(sdpA, 'answer'));
            _log('Answer created: sdpLen=${sdpA.length}');
            _sig?.send({
              'type': 'signal',
              'room': _roomName,
              'payload': {'type': 'answer', 'sdp': sdpA},
            });
            _ensureRemoteReceiving();
          }
        }
        break;
      case 'answer':
        {
          final sdpAns = msg['sdp'] as String? ??
              (msg['answer'] is Map ? (msg['answer']['sdp'] as String?) : null);
          if (sdpAns != null) {
            _log('Answer received: sdpLen=${sdpAns.length}');
            await _pc?.setRemoteDescription(
                RTCSessionDescription(sdpAns, 'answer'));
            _ensureRemoteReceiving();
          }
        }
        break;
      case 'ice':
      case 'candidate':
        final candAny = msg['candidate'];
        if (candAny != null) {
          Map<String, dynamic> normalized = {};
          if (candAny is String) {
            normalized = {
              'candidate': candAny,
              'sdpMid': msg['sdpMid'],
              'sdpMLineIndex': msg['sdpMLineIndex'],
            };
            _log('Remote ICE(unwrapped, flat): mid=${normalized['sdpMid']} mline=${normalized['sdpMLineIndex']}');
          } else if (candAny is Map<String, dynamic>) {
            normalized = {
              'candidate': candAny['candidate'],
              'sdpMid': candAny['sdpMid'],
              'sdpMLineIndex': candAny['sdpMLineIndex'],
            };
            _log('Remote ICE(unwrapped, map): mid=${normalized['sdpMid']} mline=${normalized['sdpMLineIndex']}');
          }
          if (normalized['candidate'] != null) {
            await addIceCandidate(normalized);
          }
        }
        break;
      case 'ready':
      case 'start_negotiation':
        try {
          final localDesc = await _pc?.getLocalDescription();
          final remoteDesc = await _pc?.getRemoteDescription();
          if (remoteDesc == null) {
            _log('Negotiation trigger: $type - creating offer');
            _startCall();
            // Fallback: if remote desc still not set after short delay, ensure we offered
            Future.delayed(const Duration(seconds: 2), () async {
              final rd = await _pc?.getRemoteDescription();
              final ld = await _pc?.getLocalDescription();
              if (rd == null && (ld == null || ld.type != 'offer')) {
                _log('Negotiation fallback: no remote/offer after delay, creating offer');
                _startCall();
              }
            });
          } else {
            _log('Negotiation trigger: $type - skipping offer (LD=${localDesc?.type}, RD=${remoteDesc.type})');
          }
        } catch (e) {
          _log('Negotiation trigger error: $e');
        }
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
    final pc = _pc;
    if (pc == null) return;
    try {
      final receivers = await pc.getReceivers();
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
    if (_ensureRemoteReceivingRunning) {
      _log('ensureRemoteReceiving already running; skip');
      return;
    }
    _ensureRemoteReceivingRunning = true;
    try {
      final receivers = await _pc?.getReceivers() ?? [];
      final hasVideo = receivers.any((r) => r.track?.kind == 'video');
      final hasAudio = receivers.any((r) => r.track?.kind == 'audio');
      _log('Receivers count=${receivers.length} hasVideo=$hasVideo hasAudio=$hasAudio');
      if (receivers.isNotEmpty) {
        await _attachRemoteReceivers();
        return;
      }
      // If no receivers yet, proactively add recvonly transceivers to ensure m-lines exist
      try {
        if (!_proactiveTransceiversAdded) {
          await _pc?.addTransceiver(
            kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
            init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
          );
          await _pc?.addTransceiver(
            kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
            init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
          );
          _proactiveTransceiversAdded = true;
          _log('Proactively added recvonly transceivers for video/audio');
        }
      } catch (e) {
        _log('addTransceiver proactive error: $e');
      }
      await Future.delayed(const Duration(milliseconds: 600));
      final receivers2 = await _pc?.getReceivers() ?? [];
      if (receivers2.isEmpty) {
        _log('No remote receivers after delay; triggering renegotiation');
        if (!_renegotiationRunning) {
          _restartIceAndRenegotiate('no_remote_receivers');
        }
      } else {
        await _attachRemoteReceivers();
        // If video still absent, force renegotiation to propagate new m-lines
        final hasVideo2 = receivers2.any((r) => r.track?.kind == 'video');
        if (!hasVideo2) {
          _log('No video receivers after transceiver add; renegotiating');
          if (!_renegotiationRunning) {
            _restartIceAndRenegotiate('ensure_video_mline');
          }
        }
      }
    } catch (e) {
      _log('ensure remote receiving error: $e');
    } finally {
      _ensureRemoteReceivingRunning = false;
    }
  }

  Future<void> _startCall() async {
    if (_pc == null) return;
    try {
      _log('Creating offer...');
      await _ensureTransceiversForOffer();
      final offer = await _pc!.createOffer();
      final sdp = offer.sdp ?? '';
      final localOffer = RTCSessionDescription(sdp, 'offer');
      _log('Offer created: sdpLen=${sdp.length}');
      await _pc!.setLocalDescription(localOffer);
      _log('Local description set');
      // Send using server's expected signal wrapper
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {'type': 'offer', 'sdp': sdp},
      });
      _log('Offer sent');
      // Add timeout to check for answer and renegotiate if stalled
      Future.delayed(const Duration(seconds: 5), () async {
        try {
          final rd = await _pc?.getRemoteDescription();
          if (rd == null) {
            _log('No answer after timeout; triggering renegotiation');
            await _restartIceAndRenegotiate('no_answer_timeout');
          } else {
            _log('Answer received within timeout');
          }
        } catch (e) {
          _log('Timeout check error: $e');
        }
      });
    } catch (e) {
      _log('Start call error: $e');
    }
  }

  Future<void> _restartIceAndRenegotiate(String reason) async {
    if (_renegotiationRunning) {
      _log('Renegotiation already running; skip reason=$reason');
      return;
    }
    _renegotiationRunning = true;
    renegotiationAttempts++;
    try {
      _log('ICE restart + renegotiate, reason=$reason');
      await _ensureTransceiversForOffer();
      final offer = await _pc!.createOffer({'iceRestart': true});
      final sdp = offer.sdp ?? '';
      await _pc!.setLocalDescription(RTCSessionDescription(sdp, 'offer'));
      _sig?.send({
        'type': 'signal',
        'room': _roomName,
        'payload': {'type': 'offer', 'sdp': sdp, 'reason': reason},
      });
    } catch (e) {
      _log('Renegotiate error: $e');
    } finally {
      _renegotiationRunning = false;
    }
  }

  Future<void> _ensureTransceiversForOffer() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final tx = await pc.getTransceivers();
      if (tx.isEmpty) {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
        _log('Added recvonly transceivers before offer to ensure BUNDLE group');
      }
    } catch (e) {
      _log('ensureTransceiversForOffer error: $e');
    }
  }

  Future<void> _tuneSenderEncodings() async {
    final pc = _pc;
    if (pc == null || _sendersTuned) return;
    try {
      final senders = await pc.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          try {
            final params = RTCRtpParameters(
              encodings: [
                RTCRtpEncoding(
                  maxBitrate: 2500000,
                  maxFramerate: 30,
                  scaleResolutionDownBy: 1.0,
                )
              ],
            );
            await s.setParameters(params);
          } catch (e) {
            _log('setParameters(video) error: $e');
          }
        }
      }
      _sendersTuned = true;
      _log('Video sender encodings tuned (≈2.5 Mbps, 30 fps).');
    } catch (e) {
      _log('tune sender encodings error: $e');
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
    // Ensure remote can reflect new m-line state if video was added/removed
    try {
      final rd = await _pc?.getRemoteDescription();
      if (rd != null) {
        _restartIceAndRenegotiate('video_toggle');
      }
    } catch (_) {}
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
    if (_hangupCalled) return;
    _hangupCalled = true;
    try {
      _log('Hangup: closing signaling and peer connection');
      // Stop recording and finalize
      await stopRecordingWebAndUpload();
      await _stopRecorder();
      await _sig?.close();
      await _pc?.close();
      try {
        for (final t in _localStream?.getTracks() ?? []) {
          await t.stop();
        }
        await _localStream?.dispose();
      } catch (_) {}
      try {
        await _remoteStream?.dispose();
      } catch (_) {}
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

  // Ensure we maintain a mixed stream containing all audio tracks
  Future<void> _ensureMixStream() async {
    _mixStream ??= await createLocalMediaStream('mix');
  }

  Future<void> _maybeAddStreamToMix(MediaStream? stream) async {
    if (stream == null) return;
    await _ensureMixStream();
    final audioTracks = stream.getAudioTracks();
    for (final t in audioTracks) {
      final exists = _mixStream!.getTracks().any((mt) => mt.id == t.id);
      if (!exists) {
        try {
          await _mixStream!.addTrack(t);
          _log('Mix: added audio track id=${t.id}');
        } catch (e) {
          _log('Mix add track error: $e');
        }
      }
    }
  }

  // --- Web Recording (Chrome, Mobile Safari compatible path) ---
  bool _hasAnyAudioSourceForWeb() {
    if (!kIsWeb) return false;
    final localWeb = _asWebMediaStream(_localStream);
    final remoteWeb = _asWebMediaStream(_remoteStream ?? remoteRenderer.srcObject);
    final hasLocal = localWeb != null && localWeb.getAudioTracks().toDart.isNotEmpty;
    final hasRemote = remoteWeb != null && remoteWeb.getAudioTracks().toDart.isNotEmpty;
    return hasLocal || hasRemote;
  }
  // Collect underlying web.MediaStreamTracks from flutter_webrtc tracks when direct MediaStream conversion fails
  List<web.MediaStreamTrack> _collectWebAudioTracks(MediaStream? s) {
    if (!kIsWeb || s == null) return const <web.MediaStreamTrack>[];
    final out = <web.MediaStreamTrack>[];
    try {
      for (final t in s.getAudioTracks()) {
        // Try common property used by flutter_webrtc web bindings
        final jt = js_util.getProperty(t, 'jsTrack');
        if (jt is web.MediaStreamTrack) {
          out.add(jt);
          continue;
        }
        // Alternative property names
        final alt = js_util.getProperty(t, 'track');
        if (alt is web.MediaStreamTrack) {
          out.add(alt);
          continue;
        }
        // Fallback: attempt dynamic cast
        try {
          final direct = t as dynamic;
          if (direct is web.MediaStreamTrack) {
            out.add(direct);
          }
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }
  // Convert flutter_webrtc MediaStream to web.MediaStream when on web
  web.MediaStream? _asWebMediaStream(MediaStream? s) {
    if (!kIsWeb) return null;
    if (s == null) return null;
    // Try common properties used by flutter_webrtc web bindings
    final jsStream = js_util.getProperty(s, 'jsStream');
    if (jsStream is web.MediaStream) return jsStream;
    final alt = js_util.getProperty(s, 'stream');
    if (alt is web.MediaStream) return alt;
    // Some versions attach directly a JS object
    if (s is dynamic) {
      try {
        final direct = s as web.MediaStream; // may throw
        return direct;
      } catch (_) {}
    }
    return null;
  }

  Future<void> startRecordingWeb({Uri? uploadUrl, Map<String, String>? metadata}) async {
    if (!kIsWeb) return; // web-only path
    if (isRecording) return;
    try {
      recordUploadUrl = uploadUrl ?? recordUploadUrl;
      _audioCtx ??= web.AudioContext();
      _destNode = _audioCtx!.createMediaStreamDestination();
      _log('Starting web recorder; AudioContext initial state: ${_audioCtx!.state}');
      // Attempt to resume immediately; if browser requires a gesture, this is a no-op until we call again after a tap
      resumeWebAudioIfNeeded();

      final localWeb = _asWebMediaStream(_localStream);
      final remoteWeb = _asWebMediaStream(_remoteStream ?? remoteRenderer.srcObject);

      // If there are no audio tracks yet, defer starting briefly until media is ready
      final localHasAudio = localWeb != null && localWeb.getAudioTracks().toDart.isNotEmpty;
      final remoteHasAudio = remoteWeb != null && remoteWeb.getAudioTracks().toDart.isNotEmpty;
      if (!localHasAudio && !remoteHasAudio) {
        // Try extracting underlying web tracks directly from flutter_webrtc wrappers
        final fallbackLocalTracks = _collectWebAudioTracks(_localStream);
        final fallbackRemoteTracks = _collectWebAudioTracks(_remoteStream ?? remoteRenderer.srcObject);
        final anyFallback = fallbackLocalTracks.isNotEmpty || fallbackRemoteTracks.isNotEmpty;
        if (!anyFallback) {
          _log('Web recorder start deferred: no audio tracks present yet');
          if (!_webRecorderStartRetryScheduled) {
            _webRecorderStartRetryScheduled = true;
            // Single delayed retry to avoid starting on an empty stream
            Future.delayed(const Duration(milliseconds: 500), () {
              _webRecorderStartRetryScheduled = false;
              if (!isRecording) {
                try {
                  startRecordingWeb(uploadUrl: uploadUrl, metadata: metadata);
                } catch (_) {}
              }
            });
          }
          return;
        }
      }

      // Choose source: WebAudio mix when running; else fallback to composite stream of tracks
      final bool audioCtxRunning = _audioCtx!.state == 'running';
      web.MediaStream? sourceStream;
      if (audioCtxRunning && (localWeb != null || remoteWeb != null)) {
        // Connect local audio
        if (localWeb != null) {
          final localSrc = _audioCtx!.createMediaStreamSource(localWeb);
          localSrc.connect(_destNode!);
        }
        // Connect remote audio
        if (remoteWeb != null) {
          final remoteSrc = _audioCtx!.createMediaStreamSource(remoteWeb);
          remoteSrc.connect(_destNode!);
        }
        sourceStream = _destNode!.stream;
        _compositeStream = null; // not used in this mode
        _log('Recorder source: WebAudio mixed destination');
      } else {
        // Fallback: record directly from audio tracks so we don’t depend on AudioContext
        _compositeStream = web.MediaStream();
        // Add local audio tracks
        if (localWeb != null) {
          final tracks = localWeb.getAudioTracks().toDart;
          for (final t in tracks) {
            _compositeStream!.addTrack(t);
          }
        } else {
          final tracks = _collectWebAudioTracks(_localStream);
          for (final t in tracks) {
            _compositeStream!.addTrack(t);
          }
        }
        // Add remote audio tracks
        if (remoteWeb != null) {
          final tracks = remoteWeb.getAudioTracks().toDart;
          for (final t in tracks) {
            _compositeStream!.addTrack(t);
          }
        } else {
          final tracks = _collectWebAudioTracks(_remoteStream ?? remoteRenderer.srcObject);
          for (final t in tracks) {
            _compositeStream!.addTrack(t);
          }
        }
        sourceStream = _compositeStream!;
        _log('Recorder source: Composite stream (direct audio tracks)');
      }

      // Create MediaRecorder on chosen source stream
      // Prefer Opus in WebM for broad support
      final supportedType = 'audio/webm;codecs=opus';
      if (web.MediaRecorder.isTypeSupported(supportedType)) {
        _webRecorder = web.MediaRecorder(sourceStream!, web.MediaRecorderOptions(mimeType: supportedType));
      } else {
        _webRecorder = web.MediaRecorder(sourceStream!);
      }

      _webRecorder!.addEventListener('dataavailable', ((web.Event e) {
        try {
          final be = e as web.BlobEvent;
          _lastBlob = be.data;
          // Log chunk size to aid debugging of empty recordings
          final size = js_util.getProperty(be.data, 'size');
          _log('MediaRecorder dataavailable: blob size=$size bytes');
        } catch (_) {}
      }).toJS);
      _webRecorder!.addEventListener('start', ((web.Event _) {
        isRecording = true;
        _log('MediaRecorder started');
      }).toJS);
      _webRecorder!.addEventListener('stop', ((web.Event _) {
        isRecording = false;
        _log('MediaRecorder stopped');
      }).toJS);

      // Use a timeslice so we can observe periodic dataavailable for diagnostics
      _webRecorder!.start(1000);
    } catch (e) {
      // Silent error handling for background recording
      isRecording = false;
    }
  }

  Future<void> stopRecordingWebAndUpload({Map<String, String>? metadata}) async {
    if (!kIsWeb) return;
    if (_webRecorder == null) return;
    try {
      _webRecorder!.stop();
      // Give a short delay for final dataavailable
      await Future.delayed(const Duration(milliseconds: 300));

      // Assemble final blob
      if (_lastBlob == null) {
        return;
      }
      final blob = _lastBlob!;
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final room = _roomName ?? 'call';
      final filename = 'recording_${room}_$ts.webm';

      // Upload to server if configured
      if (recordUploadUrl != null) {
        uploadInProgress = true;
        uploadProgress = 0.0;

        final form = web.FormData();
        form.append('file', blob, filename);
        form.append('room', room.toJS);
        form.append('timestamp', ts.toJS);
        if (metadata != null) {
          for (final entry in metadata.entries) {
            form.append(entry.key, (entry.value).toJS);
          }
        }

        final xhr = web.XMLHttpRequest();
        xhr.open('POST', recordUploadUrl!.toString());
        final completer = Completer<void>();
        xhr.upload.addEventListener('progress', ((web.Event e) {
          try {
            final prog = e as web.ProgressEvent;
            if (prog.lengthComputable) {
              final loaded = prog.loaded ?? 0;
              final total = prog.total ?? 1;
              uploadProgress = total > 0 ? loaded / total : 0.0;
            }
          } catch (_) {}
        }).toJS);
        xhr.addEventListener('readystatechange', ((web.Event _) {
          if (xhr.readyState == web.XMLHttpRequest.DONE) {
            if (!completer.isCompleted) completer.complete();
          }
        }).toJS);
        xhr.addEventListener('error', ((web.Event _) {
          uploadInProgress = false;
          if (!completer.isCompleted) completer.complete();
        }).toJS);
        xhr.send(form);
        await completer.future;
        uploadInProgress = false;
        uploadProgress = 1.0;
      } else {
        // No upload URL configured; silently finish
      }
    } catch (e) {
      // Silent error handling
      uploadInProgress = false;
    }
  }

  Future<void> _startRecorderIfReady() async {
    if (_recorder != null) return;
    if (_mixStream == null || _mixStream!.getAudioTracks().isEmpty) return;
    try {
      _recorder = MediaRecorder();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final room = _roomName ?? 'call';
      final fileName = 'recording_${room}_$ts.mp4';
      await _recorder!.start(fileName);
      _log('Recorder started (file=$fileName)');
    } catch (e) {
      _log('Recorder start error: $e');
      _recorder = null;
    }
  }

  Future<void> _stopRecorder() async {
    try {
      if (_recorder != null) {
        await _recorder!.stop();
        _log('Recorder stopped');
      }
    } catch (e) {
      _log('Recorder stop error: $e');
    } finally {
      _recorder = null;
      try {
        await _mixStream?.dispose();
      } catch (_) {}
      _mixStream = null;
    }
  }

  String _preferH264(String sdp) {
    try {
      final lines = sdp.split('\n');
      final mVideoIndex = lines.indexWhere((l) => l.startsWith('m=video'));
      if (mVideoIndex == -1) return sdp;

      // Build rtpmap: pt -> codec name
      final rtpmap = <int, String>{};
      for (final l in lines) {
        final m = RegExp(r'^a=rtpmap:(\\d+)\\s+([A-Za-z0-9\-]+)/').firstMatch(l);
        if (m != null) {
          final pt = int.parse(m.group(1)!);
          final codec = (m.group(2) ?? '').toUpperCase();
          rtpmap[pt] = codec;
        }
      }

      // Parse payloads from m=video
      final parts = lines[mVideoIndex].split(' ');
      final header = parts.take(3).toList();
      final payloads = parts
          .skip(3)
          .map((p) => int.tryParse(p))
          .whereType<int>()
          .toList();

      // If H264 present, move preferred H264 payload to front, but keep others
      final h264Pts = payloads.where((pt) => rtpmap[pt] == 'H264').toList();
      if (h264Pts.isEmpty) {
        _log('SDP: no H264 present; leaving codec order');
        return sdp;
      }

      // Pick the first H264 payload (simple heuristic)
      final bestH264 = h264Pts.first;
      final reordered = [bestH264, ...payloads.where((pt) => pt != bestH264)];
      lines[mVideoIndex] = '${header.join(' ')} ${reordered.join(' ')}';

      _log('SDP: prefer H264 by reordering payloads, kept others intact');
      return lines.join('\n');
    } catch (_) {
      return sdp;
    }
  }
}