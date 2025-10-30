import 'package:flutter/material.dart';
import '../rtc_session.dart';
import '../session_provider.dart';

class CallControls extends StatelessWidget {
  final RtcSession? session;
  const CallControls({super.key, this.session});

  @override
  Widget build(BuildContext context) {
    final s = session ?? RtcSessionProvider.of(context);
    final micIcon = s.micEnabled ? Icons.mic : Icons.mic_off;
    final videoIcon = s.videoEnabled ? Icons.videocam : Icons.videocam_off;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status message: recording/uploading/error
        if (s.mediaError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Mic error: ${s.mediaError}',
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              s.uploadInProgress
                  ? 'Uploading ${(s.uploadProgress * 100).toStringAsFixed(0)}%'
                  : (s.isRecording ? 'Recording' : 'Ready'),
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
        ElevatedButton(
          onPressed: s.toggleMic,
          style: ButtonStyle(
            shape: WidgetStateProperty.all(const CircleBorder()),
            padding: WidgetStateProperty.all(const EdgeInsets.all(14)),
            elevation: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? 6 : 0),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.pressed)
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.10)),
            foregroundColor: WidgetStateProperty.all(Colors.white),
          ),
          child: Icon(micIcon),
        ),
        const SizedBox(width: 12),
        // Mic level bar
        SizedBox(
          width: 80,
          height: 8,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: (s.micLevel.clamp(0.0, 1.0) * 80).toDouble(),
                  height: 8,
                  decoration: BoxDecoration(
                    color: s.micLevel > 0.6
                        ? Colors.greenAccent
                        : (s.micLevel > 0.2 ? Colors.lightGreen : Colors.green.withValues(alpha: 0.6)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        ElevatedButton(
          onPressed: s.toggleVideo,
          style: ButtonStyle(
            shape: WidgetStateProperty.all(const CircleBorder()),
            padding: WidgetStateProperty.all(const EdgeInsets.all(14)),
            elevation: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? 6 : 0),
            backgroundColor: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.pressed)
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.10)),
            foregroundColor: WidgetStateProperty.all(Colors.white),
          ),
          child: Icon(videoIcon),
        ),
        const SizedBox(width: 12),
        ElevatedButton(
          onPressed: () async {
            final nav = Navigator.of(context);
            await s.hangup();
            nav.pop();
          },
          style: ButtonStyle(
            shape: WidgetStateProperty.all(const CircleBorder()),
            padding: WidgetStateProperty.all(const EdgeInsets.all(16)),
            elevation: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.hovered) ? 8 : 0),
            backgroundColor: WidgetStateProperty.all(const Color(0xFFE53935)),
            foregroundColor: WidgetStateProperty.all(Colors.white),
          ),
          child: const Icon(Icons.call_end),
        ),
          ],
        ),
      ],
    );
  }
}