import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaxp_flutter_meet/widgets/controls.dart';
import 'package:qaxp_flutter_meet/rtc_session.dart';
import 'package:qaxp_flutter_meet/session_provider.dart';

class FakeSession extends RtcSession {
  bool micToggled = false;
  bool videoToggled = false;
  bool hungUp = false;

  @override
  Future<void> toggleMic() async {
    micToggled = true;
  }

  @override
  Future<void> toggleVideo() async {
    videoToggled = true;
  }

  @override
  Future<void> hangup() async {
    hungUp = true;
  }
}

void main() {
  testWidgets('CallControls consumes session from provider', (WidgetTester tester) async {
    final session = FakeSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RtcSessionProvider(
            notifier: session,
            child: const CallControls(),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(session.micToggled, isTrue);

    await tester.tap(find.byIcon(Icons.videocam));
    await tester.pump();
    expect(session.videoToggled, isTrue);

    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(session.hungUp, isTrue);
  });
}