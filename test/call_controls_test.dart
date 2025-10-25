import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qaxp_flutter_meet/widgets/controls.dart';
import 'package:qaxp_flutter_meet/rtc_session.dart';

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
  testWidgets('CallControls triggers session actions', (WidgetTester tester) async {
    final session = FakeSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallControls(session: session),
        ),
      ),
    );

    // Tap mic
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    expect(session.micToggled, isTrue);

    // Tap video
    await tester.tap(find.byIcon(Icons.videocam));
    await tester.pump();
    expect(session.videoToggled, isTrue);

    // Tap hangup
    await tester.tap(find.byIcon(Icons.call_end));
    await tester.pump();
    expect(session.hungUp, isTrue);
  });
}