import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province.dart';
import '../models/trade_offer.dart';
import '../services/firestore_service.dart' show GameActionException;
import '../services/server_clock.dart';
import '../services/trade_service.dart';
import '../theme/conquera_theme.dart';

Color _hex(String? hex) {
  final v = int.tryParse((hex ?? '').replaceFirst('#', ''), radix: 16);
  return Color(0xFF000000 | (v ?? 0x8A8F98));
}

// ───────────────────────── model ─────────────────────────

enum NotificationKind {
  invaded,
  missile,
  tradeReceived,
  tradeAccepted,
  overthrown,
}

/// One thing that happened to the player.
class GameNotification {
  final String id;
  final NotificationKind kind;
  final DateTime at;

  /// The other player (attacker, trade sender, or the player who accepted).
  final String attackerId;
  final String? attackerName;
  final String? attackerColor;

  final String targetId;

  /// Invasion: the attacker took the territory.
  final bool won;

  /// Missile: id of the building destroyed ('none' if nothing), and whether
  /// a dome swallowed it.
  final String building;
  final bool intercepted;

  /// Trades, from the creator's point of view: the creator gives
  /// [giveProvinces] + [giveGold] and takes [takeProvinces] + [takeGold].
  final List<String> giveProvinces;
  final int giveGold;
  final List<String> takeProvinces;
  final int takeGold;

  /// Trade offers only: when the offer stops being valid.
  final DateTime? expiresAt;

  const GameNotification({
    required this.id,
    required this.kind,
    required this.at,
    required this.attackerId,
    this.targetId = '',
    this.won = false,
    this.building = 'none',
    this.intercepted = false,
    this.attackerName,
    this.attackerColor,
    this.giveProvinces = const [],
    this.giveGold = 0,
    this.takeProvinces = const [],
    this.takeGold = 0,
    this.expiresAt,
  });

  bool get isTrade =>
      kind == NotificationKind.tradeReceived ||
      kind == NotificationKind.tradeAccepted;
}

// ───────────────────────── controller ─────────────────────────

/// Collects invasions, missile hits and trade news for [uid], live. Unread
/// ones survive restarts until "Read all".
class NotificationsController {
  /// TESTING ONLY: true shows your most recent items as unread, ignoring
  /// what was already read. Set back to false when done.
  static const bool debugShowAll = false;

  final String gameId;
  final String uid;

  NotificationsController({required this.gameId, required this.uid});

  /// Unread notifications, oldest first.
  final ValueNotifier<List<GameNotification>> unread =
      ValueNotifier(const []);

  DateTime? _readAt;
  List<GameNotification> _attacks = const [];
  List<GameNotification> _missiles = const [];
  List<GameNotification> _offers = const [];
  List<GameNotification> _accepted = const [];
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _loaded = false;
  bool _disposed = false;

  String get _readKey => 'notifReadAt_${gameId}_$uid';

  DocumentReference<Map<String, dynamic>> get _game =>
      FirebaseFirestore.instance.collection('games').doc(gameId);

  static List<String> _ids(Object? v) =>
      (v as List?)?.whereType<String>().toList() ?? const [];

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_readKey);
    if (ms != null) {
      _readAt = DateTime.fromMillisecondsSinceEpoch(ms);
    } else {
      // First launch: nothing is unread yet.
      final now = ServerClock.now();
      _readAt = now;
      await prefs.setInt(_readKey, now.millisecondsSinceEpoch);
    }
    _loaded = true;
    if (_disposed) return;

    void Function(Object) onError(String what) =>
        (Object e) => debugPrint('$what: $e');

    _subs.add(
      _game
          .collection('events')
          .orderBy('at', descending: true)
          .limit(60)
          .snapshots()
          .listen((snap) {
        _attacks = [
          for (final doc in snap.docs)
            if (((doc.data()['type'] ?? 'attack') == 'attack' ||
                    doc.data()['type'] == 'overthrow') &&
                doc.data()['defenderId'] == uid &&
                doc.data()['at'] is Timestamp)
              GameNotification(
                id: 'a_${doc.id}',
                kind: doc.data()['type'] == 'overthrow'
                    ? NotificationKind.overthrown
                    : NotificationKind.invaded,
                at: (doc.data()['at'] as Timestamp).toDate(),
                attackerId: (doc.data()['attackerId'] ??
                        doc.data()['actorId']) as String? ??
                    '',
                targetId: doc.data()['targetId'] as String? ?? '',
                won: doc.data()['type'] == 'overthrow' ||
                    (doc.data()['won'] as bool? ?? false),
                attackerName: doc.data()['actorName'] as String?,
                attackerColor: doc.data()['actorColor'] as String?,
              ),
        ];
        _rebuild();
      }, onError: onError('Notifications events')),
    );

    _subs.add(
      _game
          .collection('missiles')
          .orderBy('at', descending: true)
          .limit(60)
          .snapshots()
          .listen((snap) {
        _missiles = [
          for (final doc in snap.docs)
            if (doc.data()['defenderId'] == uid &&
                doc.data()['at'] is Timestamp)
              GameNotification(
                id: 'm_${doc.id}',
                kind: NotificationKind.missile,
                at: (doc.data()['at'] as Timestamp).toDate(),
                attackerId: doc.data()['attackerId'] as String? ?? '',
                targetId: doc.data()['targetId'] as String? ?? '',
                building: doc.data()['building'] as String? ?? 'none',
                intercepted: doc.data()['intercepted'] as bool? ?? false,
              ),
        ];
        _rebuild();
      }, onError: onError('Notifications missiles')),
    );

    // Offers sent TO this player. An offer that gets accepted, declined,
    // cancelled or expires leaves the collection, so its notification goes
    // away with it.
    _subs.add(
      _game
          .collection('deals')
          .where('participants', arrayContains: uid)
          .snapshots()
          .listen((snap) {
        _offers = [
          for (final doc in snap.docs)
            if (doc.data()['toId'] == uid && doc.data()['createdAt'] is Timestamp)
              _fromOffer(TradeOffer.fromDoc(doc)),
        ];
        _rebuild();
      }, onError: onError('Notifications offers')),
    );

    // Offers this player sent that the other side accepted.
    _subs.add(
      _game
          .collection('tradeResults')
          .where('fromId', isEqualTo: uid)
          .snapshots()
          .listen((snap) {
        _accepted = [
          for (final doc in snap.docs)
            if (doc.data()['at'] is Timestamp)
              GameNotification(
                id: 'r_${doc.id}',
                kind: NotificationKind.tradeAccepted,
                at: (doc.data()['at'] as Timestamp).toDate(),
                attackerId: doc.data()['toId'] as String? ?? '',
                attackerName: doc.data()['toName'] as String?,
                attackerColor: doc.data()['toColor'] as String?,
                giveProvinces: _ids(doc.data()['giveProvinces']),
                giveGold: (doc.data()['giveGold'] as num?)?.toInt() ?? 0,
                takeProvinces: _ids(doc.data()['takeProvinces']),
                takeGold: (doc.data()['takeGold'] as num?)?.toInt() ?? 0,
              ),
        ];
        _rebuild();
      }, onError: onError('Notifications trade results')),
    );
  }

  GameNotification _fromOffer(TradeOffer o) => GameNotification(
        id: 't_${o.id}',
        kind: NotificationKind.tradeReceived,
        at: o.createdAt!,
        attackerId: o.fromId,
        attackerName: o.fromName,
        attackerColor: o.fromColor,
        giveProvinces: o.giveProvinces,
        giveGold: o.giveGold,
        takeProvinces: o.takeProvinces,
        takeGold: o.takeGold,
        expiresAt: o.expiresAt,
      );

  void _rebuild() {
    if (!_loaded || _disposed) return;
    final readAt = _readAt!;
    final now = ServerClock.now();
    final list = [
      for (final n in [..._attacks, ..._missiles, ..._offers, ..._accepted])
        if (debugShowAll || n.at.isAfter(readAt))
          if (n.expiresAt == null || n.expiresAt!.isAfter(now)) n,
    ]..sort((a, b) => a.at.compareTo(b.at));
    unread.value = list;
  }

  /// Clears every notification (and the button with them).
  Future<void> readAll() async {
    final now = ServerClock.now();
    _readAt = now;
    unread.value = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_readKey, now.millisecondsSinceEpoch);
  }

  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    unread.dispose();
  }
}

// ───────────────────────── bell button ─────────────────────────

/// Small bell resting just above the News button's top-left corner. Hidden
/// until there is at least one unread notification.
class NotificationsButton extends StatelessWidget {
  final NotificationsController controller;
  final VoidCallback onTap;

  /// Bottom offset of the bell itself (the News button's top plus a gap).
  final double bottom;

  const NotificationsButton({
    super.key,
    required this.controller,
    required this.onTap,
    required this.bottom,
  });

  static const double size = 40.5; // 75% of the 54px News button

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: ConqueraSpace.md,
      bottom: bottom,
      child: ValueListenableBuilder<List<GameNotification>>(
        valueListenable: controller.unread,
        builder: (context, list, _) {
          if (list.isEmpty) return const SizedBox.shrink();
          final count = list.length;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: ConqueraColors.surface,
                elevation: 2,
                shadowColor: const Color(0x55000000),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: ConqueraColors.divider),
                ),
                child: InkWell(
                  customBorder: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  onTap: onTap,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: Icon(
                      Icons.notifications,
                      size: 21,
                      color: ConqueraColors.ink,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: -6,
                right: -6,
                child: IgnorePointer(
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ConqueraColors.danger,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: ConqueraColors.surface,
                        width: 1.4,
                      ),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ───────────────────────── slideshow dialog ─────────────────────────

class NotificationsDialog extends StatefulWidget {
  final NotificationsController controller;
  final List<Province> provinces;
  final ValueListenable<Map<String, PlayerState>> players;

  const NotificationsDialog({
    super.key,
    required this.controller,
    required this.provinces,
    required this.players,
  });

  @override
  State<NotificationsDialog> createState() => _NotificationsDialogState();
}

class _NotificationsDialogState extends State<NotificationsDialog> {
  late List<GameNotification> _items;
  final PageController _page = PageController();
  int _index = 0;
  bool _closing = false;

  final TradeService _trades = TradeService();

  /// Id of the notification whose accept/decline is running.
  String? _busyId;
  final Map<String, String> _errors = {};

  @override
  void initState() {
    super.initState();
    // Newest first when opened; later arrivals are added at the end so the
    // slide being read never shifts under the user.
    _items = widget.controller.unread.value.reversed.toList();
    widget.controller.unread.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.unread.removeListener(_onChanged);
    _page.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_closing || !mounted) return;
    final fresh = widget.controller.unread.value;
    if (fresh.isEmpty) {
      _closing = true;
      Navigator.of(context).pop();
      return;
    }
    final byId = {for (final n in fresh) n.id: n};
    final currentId = _index < _items.length ? _items[_index].id : null;
    final kept = [
      for (final n in _items)
        if (byId.containsKey(n.id)) byId[n.id]!,
    ];
    final known = {for (final n in kept) n.id};
    final added = [
      for (final n in fresh)
        if (!known.contains(n.id)) n,
    ];
    final next = [...kept, ...added];
    var idx = currentId == null
        ? 0
        : next.indexWhere((n) => n.id == currentId);
    if (idx < 0) idx = _index.clamp(0, next.length - 1);
    setState(() {
      _items = next;
      _index = idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_page.hasClients) return;
      if ((_page.page ?? idx.toDouble()).round() != idx) {
        _page.jumpToPage(idx);
      }
    });
  }

  Province? _province(String id) {
    for (final p in widget.provinces) {
      if (p.id == id) return p;
    }
    return null;
  }

  String _nameOf(String id) => _province(id)?.name ?? id;

  /// Accepts or declines the offer behind [n] (ids look like 't_<offerId>').
  /// On success the offer leaves Firestore, so the slide disappears on its
  /// own; a refusal (expired, gold, buildings...) is shown on the slide.
  Future<void> _answer(GameNotification n, {required bool accept}) async {
    if (_busyId != null || _closing) return;
    setState(() {
      _busyId = n.id;
      _errors.remove(n.id);
    });
    final gameId = widget.controller.gameId;
    final uid = widget.controller.uid;
    final offerId = n.id.substring(2);
    try {
      if (accept) {
        await _trades.acceptOffer(gameId: gameId, uid: uid, offerId: offerId);
      } else {
        await _trades.removeOffer(gameId: gameId, uid: uid, offerId: offerId);
      }
    } on GameActionException catch (e) {
      if (mounted) setState(() => _errors[n.id] = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _errors[n.id] = 'Something went wrong. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _readAll() async {
    if (_closing) return;
    _closing = true;
    await widget.controller.readAll();
    if (mounted) Navigator.of(context).pop();
  }

  void _next() {
    if (_index >= _items.length - 1) {
      _readAll();
      return;
    }
    _page.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final last = _index >= _items.length - 1;
    return Dialog(
      backgroundColor: ConqueraColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(ConqueraSpace.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ConqueraColors.divider),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.notifications, size: 22, color: ConqueraColors.ink),
                  const SizedBox(width: ConqueraSpace.sm),
                  Expanded(
                    child: Text('Notifications', style: ConqueraText.title),
                  ),
                  Text(
                    '${_index + 1} / ${_items.length}',
                    style: ConqueraText.label.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 20),
                    color: ConqueraColors.muted,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: ConqueraSpace.sm),
              Divider(height: 1, color: ConqueraColors.divider),
              const SizedBox(height: ConqueraSpace.md),
              SizedBox(
                height: 410,
                child: ScrollConfiguration(
                  // Touch drags by default; also allow mouse / stylus (web,
                  // desktop, emulators).
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.trackpad,
                    },
                  ),
                  child: PageView.builder(
                    controller: _page,
                    physics: const BouncingScrollPhysics(),
                    itemCount: _items.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _Pamphlet(
                        key: ValueKey(_items[i].id),
                        item: _items[i],
                        province: _province(_items[i].targetId),
                        nameOf: _nameOf,
                        players: widget.players,
                        busy: _busyId == _items[i].id,
                        error: _errors[_items[i].id],
                        onAccept: _items[i].kind ==
                                NotificationKind.tradeReceived
                            ? () => _answer(_items[i], accept: true)
                            : null,
                        onDecline: _items[i].kind ==
                                NotificationKind.tradeReceived
                            ? () => _answer(_items[i], accept: false)
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: ConqueraSpace.md),
              _Dots(count: _items.length, index: _index),
              const SizedBox(height: ConqueraSpace.md),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _readAll,
                    icon: const Icon(Icons.done_all, size: 18),
                    label: const Text('Read all'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: ConqueraColors.ink,
                      side: BorderSide(color: ConqueraColors.divider),
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      backgroundColor: ConqueraColors.ink,
                      foregroundColor: ConqueraColors.onInk,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(last ? 'Done' : 'Next'),
                        if (!last) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_forward, size: 18),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int index;

  const _Dots({required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    // Long lists: a compact dot window instead of 60 dots.
    final shown = count > 9 ? 9 : count;
    final start = count > 9 ? (index - 4).clamp(0, count - 9) : 0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = start; i < start + shown; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: i == index ? 18 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? ConqueraColors.ink : ConqueraColors.divider,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

// ───────────────────────── one pamphlet ─────────────────────────

class _Pamphlet extends StatelessWidget {
  final GameNotification item;
  final Province? province;
  final String Function(String id) nameOf;
  final ValueListenable<Map<String, PlayerState>> players;

  /// Trade offers only: answer the offer right on the slide.
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;
  final bool busy;
  final String? error;

  const _Pamphlet({
    super.key,
    required this.item,
    required this.province,
    required this.nameOf,
    required this.players,
    this.onAccept,
    this.onDecline,
    this.busy = false,
    this.error,
  });

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.day} ${_months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
  }

  String _ago(DateTime t) {
    final d = ServerClock.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  String _left(DateTime end) {
    final d = end.difference(ServerClock.now());
    if (d.isNegative) return 'expired';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m < 1 ? 1 : m}m';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, PlayerState>>(
      valueListenable: players,
      builder: (context, map, _) {
        final p = map[item.attackerId];
        final name = p?.displayName ?? item.attackerName ?? 'Someone';
        final color = _hex(p?.colorHex ?? item.attackerColor);
        final territory = province?.name ?? item.targetId;
        final kind = item.kind;
        final invasion = kind == NotificationKind.invaded ||
            kind == NotificationKind.overthrown;
        final missile = kind == NotificationKind.missile;

        final building = GameRules.buildingById(item.building);
        final destroyed = missile && !item.intercepted && building != null;

        // Tint from the player's point of view: red = bad for you.
        final Color? tint;
        switch (kind) {
          case NotificationKind.invaded:
            tint = item.won ? ConqueraColors.danger : ConqueraColors.success;
          case NotificationKind.missile:
            tint = item.intercepted
                ? ConqueraColors.success
                : (building != null ? ConqueraColors.danger : null);
          case NotificationKind.tradeReceived:
            tint = ConqueraColors.accent;
          case NotificationKind.tradeAccepted:
            tint = ConqueraColors.success;
          case NotificationKind.overthrown:
            tint = ConqueraColors.danger;
        }

        final String title = switch (kind) {
          NotificationKind.invaded =>
            item.won ? ' annexed ' : ' failed to annex ',
          NotificationKind.missile => ' fired a missile at ',
          NotificationKind.tradeReceived => ' sent you a trade offer',
          NotificationKind.tradeAccepted => ' accepted your trade offer',
          NotificationKind.overthrown => ' overthrew you in ',
        };

        final String? detail = destroyed
            ? 'Destroyed ${building.name}'
            : (kind == NotificationKind.tradeReceived && item.expiresAt != null)
                ? 'Expires in ${_left(item.expiresAt!)}'
                : null;
        final detailColor = destroyed
            ? ConqueraColors.danger
            : ConqueraColors.muted;

        final tagIcon = item.isTrade
            ? Icons.swap_horiz
            : (kind == NotificationKind.overthrown
                ? Icons.local_fire_department
                : (invasion ? Icons.flag : Icons.rocket_launch));
        final tagText = switch (kind) {
          NotificationKind.invaded => 'INVASION',
          NotificationKind.missile => 'MISSILE STRIKE',
          NotificationKind.tradeReceived => 'TRADE OFFER',
          NotificationKind.tradeAccepted => 'TRADE ACCEPTED',
          NotificationKind.overthrown => 'COUP',
        };

        final Widget art;
        if (item.isTrade) {
          // Creator gives give*; the receiver (you, on an offer) gets them.
          final received = kind == NotificationKind.tradeReceived;
          art = _TradeArt(
            leftLabel: received ? 'YOU RECEIVE' : 'YOU GAVE',
            leftNames: [for (final id in item.giveProvinces) nameOf(id)],
            leftGold: item.giveGold,
            rightLabel: received ? 'YOU GIVE' : 'YOU GOT',
            rightNames: [for (final id in item.takeProvinces) nameOf(id)],
            rightGold: item.takeGold,
            accent: color,
          );
        } else if (province == null) {
          art = Center(
            child: Icon(tagIcon, size: 56, color: color),
          );
        } else {
          art = CustomPaint(
            painter: _BorderPainter(
              province!.path,
              color,
              ConqueraColors.land,
              anchor: province!.anchor,
              lostIcon: destroyed ? building.icon : null,
              muted: ConqueraColors.muted,
              cross: ConqueraColors.danger,
            ),
          );
        }

        return Container(
          decoration: BoxDecoration(
            color: tint == null
                ? ConqueraColors.land
                : Color.alphaBlend(tint.withAlpha(38), ConqueraColors.land),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: tint ?? ConqueraColors.divider,
              width: tint == null ? 1 : 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: ConqueraColors.sea.withAlpha(90),
                        child: art,
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 10,
                      child: _Tag(icon: tagIcon, text: tagText, color: color),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(ConqueraSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        style: ConqueraText.title.copyWith(fontSize: 20),
                        children: [
                          TextSpan(text: name, style: TextStyle(color: color)),
                          TextSpan(text: title),
                          if (!item.isTrade) TextSpan(text: territory),
                        ],
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: ConqueraSpace.xs),
                      Text(
                        detail,
                        style: ConqueraText.label.copyWith(
                          color: detailColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: ConqueraSpace.sm),
                    Row(
                      children: [
                        Icon(Icons.schedule, size: 14, color: ConqueraColors.muted),
                        const SizedBox(width: 4),
                        Text(
                          '${_stamp(item.at)}  ·  ${_ago(item.at)}',
                          style: ConqueraText.label,
                        ),
                      ],
                    ),
                    if (error != null) ...[
                      const SizedBox(height: ConqueraSpace.sm),
                      Text(
                        error!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: ConqueraText.label.copyWith(
                          color: ConqueraColors.danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (onAccept != null && onDecline != null) ...[
                      const SizedBox(height: ConqueraSpace.md),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: busy ? null : onDecline,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: ConqueraColors.danger,
                                side: BorderSide(
                                  color: busy
                                      ? ConqueraColors.divider
                                      : ConqueraColors.danger,
                                ),
                              ),
                              child: const Text('Decline'),
                            ),
                          ),
                          const SizedBox(width: ConqueraSpace.sm),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: busy ? null : onAccept,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: ConqueraColors.success,
                                side: BorderSide(
                                  color: busy
                                      ? ConqueraColors.divider
                                      : ConqueraColors.success,
                                ),
                              ),
                              child: busy
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: ConqueraColors.success,
                                      ),
                                    )
                                  : const Text('Accept'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _Tag({required this.icon, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: ConqueraText.label.copyWith(
              color: ConqueraColors.ink,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── trade details ─────────────────────────

/// Two panels with an arrow between them: what moves each way.
class _TradeArt extends StatelessWidget {
  final String leftLabel;
  final List<String> leftNames;
  final int leftGold;
  final String rightLabel;
  final List<String> rightNames;
  final int rightGold;
  final Color accent;

  const _TradeArt({
    required this.leftLabel,
    required this.leftNames,
    required this.leftGold,
    required this.rightLabel,
    required this.rightNames,
    required this.rightGold,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ConqueraSpace.sm,
        46,
        ConqueraSpace.sm,
        ConqueraSpace.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _TradeSide(
              label: leftLabel,
              names: leftNames,
              gold: leftGold,
              color: ConqueraColors.success,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: Icon(Icons.swap_horiz, size: 24, color: accent),
            ),
          ),
          Expanded(
            child: _TradeSide(
              label: rightLabel,
              names: rightNames,
              gold: rightGold,
              color: ConqueraColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _TradeSide extends StatelessWidget {
  final String label;
  final List<String> names;
  final int gold;
  final Color color;

  const _TradeSide({
    required this.label,
    required this.names,
    required this.gold,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final empty = names.isEmpty && gold <= 0;
    return Container(
      padding: const EdgeInsets.all(ConqueraSpace.sm),
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(150)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: ConqueraText.label.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: ConqueraSpace.sm),
          if (empty)
            Text('Nothing', style: ConqueraText.label)
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final n in names)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Icon(Icons.flag, size: 13, color: ConqueraColors.muted),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                n,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ConqueraText.name.copyWith(fontSize: 15),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (gold > 0)
                      Row(
                        children: [
                          Icon(
                            Icons.monetization_on,
                            size: 15,
                            color: ConqueraColors.brass,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$gold',
                            style: ConqueraText.name.copyWith(
                              fontSize: 15,
                              color: ConqueraColors.brass,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────── territory outline ─────────────────────────

/// Draws one territory fitted to the box: the other player's color as a soft
/// fill with a strong outline. For a destroyed building, its icon is drawn
/// greyed out with a red X on top.
class _BorderPainter extends CustomPainter {
  final Path path;
  final Color color;
  final Color land;
  final Offset anchor;

  /// Icon of the building the missile destroyed (null = nothing to draw).
  final IconData? lostIcon;
  final Color muted;
  final Color cross;

  _BorderPainter(
    this.path,
    this.color,
    this.land, {
    required this.anchor,
    required this.lostIcon,
    required this.muted,
    required this.cross,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final b = path.getBounds();
    if (b.isEmpty) return;
    const pad = 34.0;
    final sx = (size.width - pad * 2) / b.width;
    final sy = (size.height - pad * 2) / b.height;
    final scale = sx < sy ? sx : sy;
    final dx = (size.width - b.width * scale) / 2 - b.left * scale;
    final dy = (size.height - b.height * scale) / 2 - b.top * scale;
    final m = Matrix4.translationValues(dx, dy, 0) *
        Matrix4.diagonal3Values(scale, scale, 1);
    final fitted = path.transform(m.storage);

    canvas.drawPath(
      fitted.shift(const Offset(0, 3)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawPath(fitted, Paint()..color = land);
    canvas.drawPath(fitted, Paint()..color = color.withAlpha(97));
    canvas.drawPath(
      fitted,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );

    final icon = lostIcon;
    if (icon != null) {
      final c = Offset(anchor.dx * scale + dx, anchor.dy * scale + dy);
      const iconSize = 46.0;
      final tp = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontSize: iconSize,
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            color: muted.withAlpha(200),
          ),
        ),
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));

      const r = iconSize * 0.5;
      final x = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 5
        ..color = cross;
      canvas.drawLine(c + const Offset(-r, -r), c + const Offset(r, r), x);
      canvas.drawLine(c + const Offset(r, -r), c + const Offset(-r, r), x);
    }
  }

  @override
  bool shouldRepaint(_BorderPainter old) =>
      old.path != path ||
      old.color != color ||
      old.land != land ||
      old.anchor != anchor ||
      old.lostIcon != lostIcon;
}