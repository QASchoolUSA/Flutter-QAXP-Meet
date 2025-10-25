import 'package:flutter/widgets.dart';
import 'rtc_session.dart';

class RtcSessionProvider extends InheritedNotifier<RtcSession> {
  const RtcSessionProvider({super.key, required RtcSession notifier, required Widget child})
      : super(notifier: notifier, child: child);

  static RtcSession of(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<RtcSessionProvider>();
    assert(provider != null, 'RtcSessionProvider not found in context');
    return provider!.notifier!;
  }

  @override
  bool updateShouldNotify(covariant InheritedNotifier<RtcSession> oldWidget) => true;
}