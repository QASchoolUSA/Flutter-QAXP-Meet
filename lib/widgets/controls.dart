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
    return Row(
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
    );
  }
}