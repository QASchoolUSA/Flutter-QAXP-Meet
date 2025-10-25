import 'package:flutter/widgets.dart';
import 'rtc_session.dart';

class RtcSessionProvider extends InheritedNotifier<RtcSession> {
  const RtcSessionProvider({super.key, required super.notifier, required super.child});

  static RtcSession of(BuildContext context) {
    final provider = context.dependOnInheritedWidgetOfExactType<RtcSessionProvider>();
    assert(provider != null, 'RtcSessionProvider not found in context');
    return provider!.notifier!;
  }

  @override
  bool updateShouldNotify(covariant InheritedNotifier<RtcSession> oldWidget) => true;
}