import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';
import '../models/trade_offer.dart';
import '../services/firestore_service.dart'
    show FirestoreService, GameActionException;
import '../services/server_clock.dart';
import '../services/trade_service.dart';
import '../theme/conquera_theme.dart';
import '../widgets/gold_amount.dart';
import '../widgets/player_tag.dart';

// ───────────────────────── helpers ─────────────────────────

Color _hex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x457B9D;
  return Color(0xFF000000 | v);
}

String _left(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m left' : '${m < 1 ? 1 : m}m left';
}

String _n(int v) {
  final s = v.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _summary(List<String> ids, int gold, String Function(String) name) {
  final parts = <String>[];
  if (ids.length == 1) {
    parts.add(name(ids.first));
  } else if (ids.length == 2) {
    parts.add('${name(ids[0])}, ${name(ids[1])}');
  } else if (ids.length > 2) {
    parts.add('${name(ids.first)} +${ids.length - 1} more');
  }
  if (gold > 0) parts.add('${_n(gold)} gold');
  return parts.isEmpty ? 'nothing' : parts.join(' + ');
}

Color get _cardColor => Color.alphaBlend(
      ConqueraColors.ink.withOpacity(ConqueraColors.dark ? 0.07 : 0.05),
      ConqueraColors.surface,
    );

Color get _lineColor => ConqueraColors.divider.withOpacity(0.5);

/// Rounded card used for every block on this screen.
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? borderColor;

  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor ?? _lineColor),
      ),
      child: child,
    );
  }
}

/// Small tinted label.
class _Pill extends StatelessWidget {
  final String text;
  final Color color;

  const _Pill(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: ConqueraText.label.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Round icon badge ("give" arrow / "get" arrow).
class _Badge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final double size;

  const _Badge(this.icon, this.color, {this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: size * 0.58, color: color),
    );
  }
}

// ───────────────────────── screen ─────────────────────────

/// Private trades with other players. "Received" are offers sent to you,
/// "Sent" are yours. The big + button opens ONE sheet where you pick the
/// player, fill in what you give / get, and send.
class TradeScreen extends StatefulWidget {
  final String gameId;
  final String? myUid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;

  /// province id -> country name.
  final Map<String, String> provinceNames;

  const TradeScreen({
    super.key,
    required this.gameId,
    required this.myUid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
  });

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  final TradeService _service = TradeService();
  final FirestoreService _game = FirestoreService();
  StreamSubscription<List<TradeOffer>>? _sub;
  Timer? _tick;
  List<TradeOffer> _offers = const [];
  bool _sent = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final uid = widget.myUid;
    if (uid != null) {
      _sub = _service.watchOffers(gameId: widget.gameId, uid: uid).listen(
        (list) {
          if (mounted) setState(() => _offers = list);
        },
        onError: (_) {},
      );
    }
    // Keeps "time left" and expiry fresh.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  String _name(String id) => widget.provinceNames[id] ?? id;

  void _toast(String message) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _run(Future<void> Function() job, String done) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await job();
      if (mounted) _toast(done);
      return true;
    } on GameActionException catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  static const _sheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
  );

  Future<void> _newTrade(String uid) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: ConqueraColors.surface,
      shape: _sheetShape,
      builder: (_) => _BuilderSheet(
        gameId: widget.gameId,
        myUid: uid,
        service: _service,
        players: widget.players,
        provinces: widget.provinces,
        provinceNames: widget.provinceNames,
      ),
    );
    if (sent == true && mounted) {
      setState(() => _sent = true);
      _toast('Offer sent.');
    }
  }

  void _open(TradeOffer o, String uid) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: ConqueraColors.surface,
      shape: _sheetShape,
      builder: (sheet) => _OfferSheet(
        offer: o,
        uid: uid,
        players: widget.players,
        provinces: widget.provinces,
        provinceNames: widget.provinceNames,
        onAccept: () async {
          Navigator.of(sheet).pop();
          await _run(
            () => _service.acceptOffer(
                gameId: widget.gameId, uid: uid, offerId: o.id),
            'Trade completed.',
          );
        },
        onRemove: () async {
          Navigator.of(sheet).pop();
          await _run(
            () => _service.removeOffer(
                gameId: widget.gameId, uid: uid, offerId: o.id),
            o.fromId == uid ? 'Offer cancelled.' : 'Offer declined.',
          );
        },
        onDestroy: (provinceId) => _game.destroyBuilding(
          gameId: widget.gameId,
          provinceId: provinceId,
          uid: uid,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.myUid;
    return Scaffold(
      backgroundColor: ConqueraColors.surface,
      appBar: AppBar(
        backgroundColor: ConqueraColors.surface,
        foregroundColor: ConqueraColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('Trade', style: ConqueraText.title.copyWith(fontSize: 22)),
      ),
      floatingActionButton: uid == null
          ? null
          : FloatingActionButton.large(
              tooltip: 'New trade',
              elevation: 5,
              backgroundColor: ConqueraColors.ink,
              foregroundColor: ConqueraColors.onInk,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              onPressed: _busy ? null : () => _newTrade(uid),
              child: const Icon(Icons.add, size: 42),
            ),
      body: uid == null
          ? Center(
              child: Text('Join the world to trade.', style: ConqueraText.label))
          : AnimatedBuilder(
              animation: Listenable.merge([widget.provinces, widget.players]),
              builder: (context, _) => _body(uid),
            ),
    );
  }

  Widget _body(String uid) {
    final provs = widget.provinces.value;
    final players = widget.players.value;
    final now = ServerClock.now();
    final received = _offers.where((o) => o.toId == uid).toList();
    final sent = _offers.where((o) => o.fromId == uid).toList();
    int live(List<TradeOffer> l) => l
        .where((o) => TradeService.problem(o, provs, players, now) == null)
        .length;
    final rows = _sent ? sent : received;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ConqueraSpace.md),
          child: _Balance(players: widget.players, uid: uid),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ConqueraSpace.md),
          child: _Segments(
            leftLabel: 'Received',
            leftCount: live(received),
            rightLabel: 'Sent',
            rightCount: live(sent),
            rightOn: _sent,
            onChanged: (right) => setState(() => _sent = right),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.isEmpty
              ? _Empty(sent: _sent)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                      ConqueraSpace.md, 0, ConqueraSpace.md, 130),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) =>
                      _card(rows[i], uid, provs, players, now),
                ),
        ),
      ],
    );
  }

  Widget _card(
    TradeOffer o,
    String uid,
    Map<String, ProvinceState> provs,
    Map<String, PlayerState> players,
    DateTime now,
  ) {
    final mine = o.fromId == uid;
    final problem = TradeService.problem(o, provs, players, now);
    final giveIds = mine ? o.giveProvinces : o.takeProvinces;
    final giveGold = mine ? o.giveGold : o.takeGold;
    final getIds = mine ? o.takeProvinces : o.giveProvinces;
    final getGold = mine ? o.takeGold : o.giveGold;
    // Only the receiver may know about buildings on their own territories.
    final toClear = (!mine && problem == null)
        ? TradeService.buildingsToClear(o, provs).length
        : 0;

    final String status;
    final Color statusColor;
    if (problem == null) {
      status = _left(o.timeLeft(now));
      statusColor = ConqueraColors.muted;
    } else if (problem == TradeProblem.expired) {
      status = 'Expired';
      statusColor = ConqueraColors.danger;
    } else {
      status = 'Unavailable';
      statusColor = ConqueraColors.danger;
    }

    return Opacity(
      opacity: problem == null ? 1 : 0.55,
      child: Material(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(o, uid),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _lineColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: PlayerTag(
                          name: mine ? o.toName : o.fromName,
                          color: _hex(mine ? o.toColor : o.fromColor),
                          style: ConqueraText.name,
                        ),
                      ),
                    ),
                    Text(status,
                        style: ConqueraText.label.copyWith(color: statusColor)),
                    Icon(Icons.chevron_right,
                        color: ConqueraColors.muted, size: 20),
                  ],
                ),
                const SizedBox(height: 12),
                _Line(
                  icon: Icons.north_east,
                  color: ConqueraColors.danger,
                  label: 'You give',
                  text: _summary(giveIds, giveGold, _name),
                ),
                const SizedBox(height: 8),
                _Line(
                  icon: Icons.south_west,
                  color: ConqueraColors.success,
                  label: 'You get',
                  text: _summary(getIds, getGold, _name),
                ),
                if (toClear > 0) ...[
                  const SizedBox(height: 10),
                  _Pill(
                    toClear == 1
                        ? 'Destroy 1 building to accept'
                        : 'Destroy $toClear buildings to accept',
                    ConqueraColors.brass,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String text;

  const _Line({
    required this.icon,
    required this.color,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Badge(icon, color, size: 24),
        const SizedBox(width: 10),
        SizedBox(width: 58, child: Text(label, style: ConqueraText.label)),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.value,
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  final bool sent;

  const _Empty({required this.sent});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 100),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              sent ? Icons.outbox_outlined : Icons.inbox_outlined,
              size: 56,
              color: ConqueraColors.muted.withOpacity(0.6),
            ),
            const SizedBox(height: 12),
            Text(
              sent ? 'Nothing sent yet' : 'No offers for you',
              style: ConqueraText.name,
            ),
            const SizedBox(height: 4),
            Text(
              sent
                  ? 'Tap the + button to start a trade.'
                  : 'Offers other players send you show up here.',
              textAlign: TextAlign.center,
              style: ConqueraText.label,
            ),
          ],
        ),
      ),
    );
  }
}

/// Two-way pill switch: Received | Sent.
class _Segments extends StatelessWidget {
  final String leftLabel;
  final int leftCount;
  final String rightLabel;
  final int rightCount;
  final bool rightOn;
  final ValueChanged<bool> onChanged;

  const _Segments({
    required this.leftLabel,
    required this.leftCount,
    required this.rightLabel,
    required this.rightCount,
    required this.rightOn,
    required this.onChanged,
  });

  Widget _seg(String label, int count, bool on, VoidCallback tap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: tap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: on ? ConqueraColors.ink : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: Text(
            count > 0 ? '$label · $count' : label,
            style: ConqueraText.value.copyWith(
              color: on ? ConqueraColors.onInk : ConqueraColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _lineColor),
      ),
      child: Row(
        children: [
          _seg(leftLabel, leftCount, !rightOn, () => onChanged(false)),
          _seg(rightLabel, rightCount, rightOn, () => onChanged(true)),
        ],
      ),
    );
  }
}

/// Your gold, ticking live.
class _Balance extends StatefulWidget {
  final ValueListenable<Map<String, PlayerState>> players;
  final String uid;

  const _Balance({required this.players, required this.uid});

  @override
  State<_Balance> createState() => _BalanceState();
}

class _BalanceState extends State<_Balance> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gold =
        widget.players.value[widget.uid]?.goldAt(ServerClock.now()) ?? 0;
    return _Panel(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text('Your gold', style: ConqueraText.label),
          const Spacer(),
          GoldAmount(gold.floor(), style: ConqueraText.figure, iconSize: 18),
        ],
      ),
    );
  }
}

// ───────────────────────── offer sheet ─────────────────────────

/// An offer in detail, with accept / decline / cancel. The receiver also
/// sees which of THEIR territories have a building and can destroy it here.
class _OfferSheet extends StatefulWidget {
  final TradeOffer offer;
  final String uid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;
  final VoidCallback onAccept;
  final VoidCallback onRemove;
  final Future<void> Function(String provinceId) onDestroy;

  const _OfferSheet({
    required this.offer,
    required this.uid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.onAccept,
    required this.onRemove,
    required this.onDestroy,
  });

  @override
  State<_OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends State<_OfferSheet> {
  bool _working = false;
  String? _error;

  String _name(String id) => widget.provinceNames[id] ?? id;

  Future<void> _destroy(String id, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ConqueraColors.surface,
        title: Text('Destroy $label?', style: ConqueraText.name),
        content: Text(
          'The $label in ${_name(id)} is destroyed for good. There is no '
          'refund and you cannot build for a while afterwards. After that '
          'this territory can be traded.',
          style: ConqueraText.value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Destroy',
                style: TextStyle(color: ConqueraColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.onDestroy(id);
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _title(IconData icon, Color color, String text) => Row(
        children: [
          _Badge(icon, color),
          const SizedBox(width: 10),
          Text(text, style: ConqueraText.name.copyWith(fontSize: 17)),
        ],
      );

  Widget _terr(
    String id, {
    ProvinceState? building,
    bool canDestroy = false,
  }) {
    final has = building != null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(Icons.flag_outlined, size: 18, color: ConqueraColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_name(id), style: ConqueraText.value),
                if (has)
                  Text(
                    'Has a ${building!.buildingLabel}. Must be destroyed first.',
                    style: ConqueraText.label
                        .copyWith(color: ConqueraColors.brass),
                  ),
              ],
            ),
          ),
          if (has && canDestroy)
            OutlinedButton(
              onPressed: _working
                  ? null
                  : () => _destroy(id, building!.buildingLabel),
              style: OutlinedButton.styleFrom(
                foregroundColor: ConqueraColors.danger,
                side: BorderSide(color: ConqueraColors.danger),
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Destroy'),
            ),
        ],
      ),
    );
  }

  Widget _gold(int gold) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: GoldAmount(gold,
            style: ConqueraText.figure.copyWith(fontSize: 17), iconSize: 16),
      );

  Widget _nothing() => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('Nothing', style: ConqueraText.label),
      );

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final uid = widget.uid;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.players, widget.provinces]),
      builder: (context, _) {
        final provs = widget.provinces.value;
        final mine = offer.fromId == uid;
        final now = ServerClock.now();
        final problem =
            TradeService.problem(offer, provs, widget.players.value, now);
        final giveIds = mine ? offer.giveProvinces : offer.takeProvinces;
        final giveGold = mine ? offer.giveGold : offer.takeGold;
        final getIds = mine ? offer.takeProvinces : offer.giveProvinces;
        final getGold = mine ? offer.takeGold : offer.giveGold;
        final other = mine ? offer.toName : offer.fromName;
        final myGold = widget.players.value[uid]?.goldAt(now) ?? 0;
        final short = !mine && myGold < offer.takeGold;

        // Receiver only: own territories in this trade that have a building.
        final toClear = mine
            ? const <String>[]
            : TradeService.buildingsToClear(offer, provs);
        final canDestroy = !mine && problem == null && !short;

        final String note;
        switch (problem) {
          case TradeProblem.expired:
            note = 'This offer expired.';
          case TradeProblem.ownerChanged:
            note = 'A territory in this trade changed owner.';
          case TradeProblem.buildingAppeared:
            note = mine
                ? 'A territory you give got a building.'
                : 'This offer is no longer available.';
          case TradeProblem.giverShort:
            note = mine
                ? 'You have less gold than you offered.'
                : '$other has less gold than offered.';
          case null:
            if (short) {
              note = 'You need ${_n(offer.takeGold)} gold to accept.';
            } else if (toClear.isNotEmpty) {
              note = toClear.length == 1
                  ? 'Destroy the building below to accept this trade.'
                  : 'Destroy the buildings below to accept this trade.';
            } else {
              note = _left(offer.timeLeft(now));
            }
        }
        final bad = problem != null || short;
        final warn = !bad && toClear.isNotEmpty;

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                  ConqueraSpace.md, 10, ConqueraSpace.md, ConqueraSpace.md),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: ConqueraColors.divider,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(mine ? 'Offer to' : 'Offer from',
                          style: ConqueraText.label),
                      const SizedBox(width: ConqueraSpace.sm),
                      Flexible(
                        child: PlayerTag(
                          name: other,
                          color: _hex(mine ? offer.toColor : offer.fromColor),
                          style: ConqueraText.name,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _title(Icons.north_east, ConqueraColors.danger,
                            'You give'),
                        for (final id in giveIds)
                          _terr(
                            id,
                            building: toClear.contains(id) ? provs[id] : null,
                            canDestroy: canDestroy,
                          ),
                        if (giveGold > 0) _gold(giveGold),
                        if (giveIds.isEmpty && giveGold <= 0) _nothing(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _title(Icons.south_west, ConqueraColors.success,
                            'You get'),
                        for (final id in getIds) _terr(id),
                        if (getGold > 0) _gold(getGold),
                        if (getIds.isEmpty && getGold <= 0) _nothing(),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _error ?? note,
                    style: ConqueraText.label.copyWith(
                      color: _error != null || bad
                          ? ConqueraColors.danger
                          : warn
                              ? ConqueraColors.brass
                              : ConqueraColors.muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _working ? null : widget.onRemove,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 50),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(mine
                              ? (problem == null ? 'Cancel offer' : 'Remove')
                              : (problem == null ? 'Decline' : 'Remove')),
                        ),
                      ),
                      if (!mine) ...[
                        const SizedBox(width: ConqueraSpace.sm),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: (bad || warn || _working)
                                ? null
                                : widget.onAccept,
                            style: ElevatedButton.styleFrom(
                              elevation: 0,
                              minimumSize: const Size(0, 50),
                              backgroundColor: ConqueraColors.success,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor:
                                  ConqueraColors.muted.withOpacity(0.25),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: const Text('Accept'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── builder sheet ─────────────────────────

class _Opt {
  final String id;
  final String name;

  /// Greyed out and not selectable (your own territory with a building).
  final bool locked;
  const _Opt(this.id, this.name, {this.locked = false});
}

/// The whole "new trade" flow in one sheet: who, what you give, what you
/// get, send.
class _BuilderSheet extends StatefulWidget {
  final String gameId;
  final String myUid;
  final TradeService service;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;

  const _BuilderSheet({
    required this.gameId,
    required this.myUid,
    required this.service,
    required this.players,
    required this.provinces,
    required this.provinceNames,
  });

  @override
  State<_BuilderSheet> createState() => _BuilderSheetState();
}

class _BuilderSheetState extends State<_BuilderSheet> {
  final TextEditingController _giveGold = TextEditingController();
  final TextEditingController _getGold = TextEditingController();
  final Set<String> _give = {};
  final Set<String> _get = {};
  String? _partnerId;
  String _playerQuery = '';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _giveGold.dispose();
    _getGold.dispose();
    super.dispose();
  }

  String _name(String id) => widget.provinceNames[id] ?? id;
  int _amount(TextEditingController c) => int.tryParse(c.text) ?? 0;

  PlayerState? get _partner {
    final id = _partnerId;
    return id == null ? null : widget.players.value[id];
  }

  int _owned(String uid) =>
      widget.provinces.value.values.where((p) => p.ownerId == uid).length;

  /// Your own territories. Ones with a building are locked.
  List<_Opt> _myOptions() => [
        for (final p in widget.provinces.value.values)
          if (p.ownerId == widget.myUid)
            _Opt(p.id, _name(p.id), locked: p.hasBuilding),
      ]..sort((a, b) => a.name.compareTo(b.name));

  /// EVERY territory of the other player, with no hint of buildings: the
  /// receiver has to destroy a building before accepting.
  List<_Opt> _theirOptions(String owner) => [
        for (final p in widget.provinces.value.values)
          if (p.ownerId == owner) _Opt(p.id, _name(p.id)),
      ]..sort((a, b) => a.name.compareTo(b.name));

  void _pickPartner(PlayerState p) {
    setState(() {
      if (_partnerId != p.uid) _get.clear();
      _partnerId = p.uid;
      _error = null;
    });
  }

  /// Why the offer can't be sent yet (null = ready).
  String? get _problem {
    final partner = _partner;
    if (partner == null) return 'Choose who to trade with.';
    final give = _amount(_giveGold);
    final take = _amount(_getGold);
    if (_give.isEmpty && _get.isEmpty && give == 0 && take == 0) {
      return 'Add something to the trade.';
    }
    if (give > TradeService.maxGold || take > TradeService.maxGold) {
      return 'Gold is limited to ${_n(TradeService.maxGold)}.';
    }
    final mine =
        widget.players.value[widget.myUid]?.goldAt(ServerClock.now()) ?? 0;
    if (give > mine) return 'You only have ${_n(mine.floor())} gold.';
    if (_owned(widget.myUid) - _give.length + _get.length < 1) {
      return 'Keep at least one territory.';
    }
    if (_owned(partner.uid) - _get.length + _give.length < 1) {
      return '${partner.displayName} must keep at least one territory.';
    }
    return null;
  }

  Future<void> _send() async {
    final partner = _partner;
    if (_busy || partner == null || _problem != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.createOffer(
        gameId: widget.gameId,
        uid: widget.myUid,
        toId: partner.uid,
        giveProvinces: _give.toList(),
        giveGold: _amount(_giveGold),
        takeProvinces: _get.toList(),
        takeGold: _amount(_getGold),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _touched =>
      _give.isNotEmpty ||
      _get.isNotEmpty ||
      _giveGold.text.isNotEmpty ||
      _getGold.text.isNotEmpty;

  Widget _playerPicker() {
    final counts = <String, int>{};
    for (final p in widget.provinces.value.values) {
      final o = p.ownerId;
      if (o != null) counts[o] = (counts[o] ?? 0) + 1;
    }
    final all = [
      for (final p in widget.players.value.values)
        if (p.uid != widget.myUid && (counts[p.uid] ?? 0) > 0) p,
    ]..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final shown = [
      for (final p in all)
        if (p.displayName.toLowerCase().contains(_playerQuery.toLowerCase()) ||
            p.uid == _partnerId)
          p,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Trade with', style: ConqueraText.label),
        const SizedBox(height: 8),
        if (all.length > 6) ...[
          TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search players',
              prefixIcon: const Icon(Icons.search, size: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (v) => setState(() => _playerQuery = v),
          ),
          const SizedBox(height: 8),
        ],
        if (all.isEmpty)
          Text('No other players yet.', style: ConqueraText.label)
        else
          SizedBox(
            height: 46,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: shown.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final p = shown[i];
                final on = p.uid == _partnerId;
                return GestureDetector(
                  onTap: () => _pickPartner(p),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: on
                          ? ConqueraColors.ink.withOpacity(0.10)
                          : _cardColor,
                      borderRadius: BorderRadius.circular(23),
                      border: Border.all(
                        color: on ? ConqueraColors.ink : _lineColor,
                        width: on ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        PlayerTag(name: p.displayName, color: p.color),
                        const SizedBox(width: 8),
                        Text('${counts[p.uid] ?? 0}',
                            style: ConqueraText.label),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.players, widget.provinces]),
      builder: (context, _) {
        final partner = _partner;
        final problem = _problem;
        final myGold =
            widget.players.value[widget.myUid]?.goldAt(ServerClock.now()) ?? 0;
        final shownError =
            _error ?? ((problem != null && _touched) ? problem : null);

        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.94,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: ConqueraColors.divider,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      ConqueraSpace.md, 10, 6, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('New trade',
                            style: ConqueraText.title.copyWith(fontSize: 24)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                        ConqueraSpace.md, 8, ConqueraSpace.md, 16),
                    children: [
                      _playerPicker(),
                      const SizedBox(height: 16),
                      if (partner == null)
                        _Panel(
                          child: Row(
                            children: [
                              Icon(Icons.touch_app_outlined,
                                  color: ConqueraColors.muted),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Pick a player above to build your offer.',
                                  style: ConqueraText.label,
                                ),
                              ),
                            ],
                          ),
                        )
                      else ...[
                        _SidePanel(
                          key: const ValueKey('give'),
                          title: 'You give',
                          icon: Icons.north_east,
                          tint: ConqueraColors.danger,
                          options: _myOptions(),
                          selected: _give,
                          names: _name,
                          goldController: _giveGold,
                          goldHint: 'You have ${_n(myGold.floor())}',
                          onMax: () => setState(() {
                            final v = myGold.floor();
                            _giveGold.text = (v > TradeService.maxGold
                                    ? TradeService.maxGold
                                    : v)
                                .toString();
                            _error = null;
                          }),
                          onChanged: () => setState(() => _error = null),
                        ),
                        const SizedBox(height: 12),
                        _SidePanel(
                          key: ValueKey('get-${partner.uid}'),
                          title: 'You get',
                          icon: Icons.south_west,
                          tint: ConqueraColors.success,
                          options: _theirOptions(partner.uid),
                          selected: _get,
                          names: _name,
                          goldController: _getGold,
                          goldHint: 'From ${partner.displayName}',
                          onChanged: () => setState(() => _error = null),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Only you and ${partner.displayName} can see this '
                          'offer. It stays open for 12 hours. A territory '
                          'with a building cannot change hands, and the '
                          'offer switches off if a territory changes owner '
                          'or you hold less gold than you offered. Troops '
                          'stay with the territory.',
                          style: ConqueraText.label,
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(
                      ConqueraSpace.md, 12, ConqueraSpace.md, 12),
                  decoration: BoxDecoration(
                    color: ConqueraColors.surface,
                    border: Border(top: BorderSide(color: _lineColor)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (shownError != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              shownError,
                              style: ConqueraText.label
                                  .copyWith(color: ConqueraColors.danger),
                            ),
                          )
                        else if (partner != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              'Give ${_summary(_give.toList(), _amount(_giveGold), _name)}'
                              '   ·   '
                              'Get ${_summary(_get.toList(), _amount(_getGold), _name)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: ConqueraText.label,
                            ),
                          ),
                        ElevatedButton.icon(
                          onPressed: (_busy || problem != null) ? null : _send,
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: Text(_busy ? 'Sending...' : 'Send offer'),
                          style: ElevatedButton.styleFrom(
                            elevation: 0,
                            minimumSize: const Size.fromHeight(54),
                            backgroundColor: ConqueraColors.ink,
                            foregroundColor: ConqueraColors.onInk,
                            disabledBackgroundColor:
                                ConqueraColors.muted.withOpacity(0.25),
                            textStyle: ConqueraText.button.copyWith(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One side of the trade: territory chips, an inline picker that opens in
/// place, and a gold field.
class _SidePanel extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color tint;
  final List<_Opt> options;
  final Set<String> selected;
  final String Function(String) names;
  final TextEditingController goldController;
  final String goldHint;
  final VoidCallback? onMax;
  final VoidCallback onChanged;

  const _SidePanel({
    super.key,
    required this.title,
    required this.icon,
    required this.tint,
    required this.options,
    required this.selected,
    required this.names,
    required this.goldController,
    required this.goldHint,
    required this.onChanged,
    this.onMax,
  });

  @override
  State<_SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<_SidePanel> {
  bool _open = false;
  String _query = '';

  void _toggle(_Opt o) {
    if (o.locked) return;
    final s = widget.selected;
    setState(() {
      if (s.contains(o.id)) {
        s.remove(o.id);
      } else if (s.length < TradeService.maxProvincesPerSide) {
        s.add(o.id);
      }
    });
    widget.onChanged();
  }

  Widget _picker() {
    final shown = [
      for (final o in widget.options)
        if (o.name.toLowerCase().contains(_query.toLowerCase())) o,
    ];
    return Container(
      margin: const EdgeInsets.only(top: 10),
      height: 270,
      decoration: BoxDecoration(
        color: ConqueraColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _lineColor),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search territories',
                prefixIcon: const Icon(Icons.search, size: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Divider(height: 1, color: _lineColor),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text(
                      widget.options.isEmpty
                          ? 'No territories.'
                          : 'No match.',
                      style: ConqueraText.label,
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) {
                      final o = shown[i];
                      final on = widget.selected.contains(o.id);
                      return InkWell(
                        onTap: o.locked ? null : () => _toggle(o),
                        child: Opacity(
                          opacity: o.locked ? 0.45 : 1,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 11),
                            child: Row(
                              children: [
                                Icon(
                                  o.locked
                                      ? Icons.lock_outline
                                      : on
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                  size: 20,
                                  color: on
                                      ? widget.tint
                                      : ConqueraColors.muted,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child:
                                      Text(o.name, style: ConqueraText.value),
                                ),
                                if (o.locked)
                                  Text('Has a building',
                                      style: ConqueraText.label),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.selected;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge(widget.icon, widget.tint),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.title,
                    style: ConqueraText.name.copyWith(fontSize: 17)),
              ),
              Text(
                '${s.length} / ${TradeService.maxProvincesPerSide}',
                style: ConqueraText.label,
              ),
            ],
          ),
          if (s.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final id in s)
                  InputChip(
                    label: Text(widget.names(id),
                        style: ConqueraText.value.copyWith(fontSize: 13.5)),
                    backgroundColor: ConqueraColors.surface,
                    side: BorderSide(color: _lineColor),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    deleteIconColor: ConqueraColors.muted,
                    onDeleted: () {
                      setState(() => s.remove(id));
                      widget.onChanged();
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _open = !_open),
              icon: Icon(_open ? Icons.expand_less : Icons.add, size: 18),
              label: Text(_open
                  ? 'Done'
                  : s.isEmpty
                      ? 'Add territories'
                      : 'Add more'),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _open ? _picker() : const SizedBox(width: double.infinity),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: _lineColor),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.goldController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(8),
                  ],
                  style: ConqueraText.figure.copyWith(fontSize: 17),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '0 gold',
                    helperText: widget.goldHint,
                    prefixIcon: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 10),
                      child: GoldIcon(size: 18),
                    ),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 0, minHeight: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onChanged: (_) => widget.onChanged(),
                ),
              ),
              if (widget.onMax != null) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: OutlinedButton(
                    onPressed: widget.onMax,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Max'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}