import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Trusted "now" for the whole game.
///
/// The device clock is never trusted. [sync] asks Firestore for the server
/// time once, then [now] = that server time + a monotonic [Stopwatch].
/// A Stopwatch is not affected by the player changing the date/time in
/// settings, so moving the clock forward no longer produces free gold.
class ServerClock with WidgetsBindingObserver {
  ServerClock._();

  static final ServerClock _instance = ServerClock._();
  static bool _observing = false;

  static DateTime? _anchor; // server time at the moment of sync
  static final Stopwatch _watch = Stopwatch();

  /// Server-based current time. Falls back to the device clock only if
  /// [sync] has never succeeded (writes need a connection anyway).
  static DateTime now() {
    final anchor = _anchor;
    if (anchor == null) return DateTime.now();
    return anchor.add(_watch.elapsed);
  }

  /// Call once after sign-in. Also re-syncs whenever the app resumes.
  static Future<void> init() async {
    if (!_observing) {
      WidgetsBinding.instance.addObserver(_instance);
      _observing = true;
    }
    await sync();
  }

  static Future<void> sync() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final ref = FirebaseFirestore.instance.collection('serverClock').doc(uid);
      final before = Stopwatch()..start();
      await ref.set({'t': FieldValue.serverTimestamp()});
      final snap = await ref.get(const GetOptions(source: Source.server));
      before.stop();
      final t = snap.data()?['t'];
      if (t is! Timestamp) return;
      // Server time was taken roughly mid round-trip.
      final server = t.toDate().add(before.elapsed ~/ 2);
      _anchor = server;
      _watch
        ..reset()
        ..start();
    } catch (e) {
      debugPrint('ServerClock sync failed: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) sync();
  }
}