import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';
import '../models/trade_offer.dart';
import '../services/firestore_service.dart' show GameActionException;
import '../services/server_clock.dart';
import '../services/trade_service.dart';
import '../theme/conquera_theme.dart';
import '../widgets/gold_amount.dart';
import '../widgets/player_tag.dart';

Color _hex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x457B9D;
  return Color(0xFF000000 | v);
}

String _left(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m left' : '${m < 1 ? 1 : m}m left';
}

/// Private trades with other players. "Received" are offers sent to you,
/// "Sent" are yours. The + button starts a new one: pick a player, fill in
/// the give / get table, send.
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

  Future<void> _newTrade(String uid) async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _PickPlayerScreen(
          gameId: widget.gameId,
          myUid: uid,
          service: _service,
          players: widget.players,
          provinces: widget.provinces,
          provinceNames: widget.provinceNames,
        ),
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
      backgroundColor: ConqueraColors.surface,
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
        actions: [
          if (uid != null)
            IconButton(
              tooltip: 'New trade',
              icon: const Icon(Icons.add),
              onPressed: _busy ? null : () => _newTrade(uid),
            ),
          const SizedBox(width: 4),
        ],
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
        _Balance(players: widget.players, uid: uid),
        Row(
          children: [
            const SizedBox(width: ConqueraSpace.md),
            _Tab(
              label: 'Received',
              count: live(received),
              on: !_sent,
              onTap: () => setState(() => _sent = false),
            ),
            const SizedBox(width: ConqueraSpace.md),
            _Tab(
              label: 'Sent',
              count: live(sent),
              on: _sent,
              onTap: () => setState(() => _sent = true),
            ),
          ],
        ),
        Divider(height: 1, color: ConqueraColors.divider),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(ConqueraSpace.lg),
                    child: Text(
                      _sent
                          ? 'You have not sent any trades.\nTap + to start one.'
                          : 'No trades for you right now.',
                      textAlign: TextAlign.center,
                      style: ConqueraText.label,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: ConqueraColors.divider),
                  itemBuilder: (_, i) => _row(rows[i], uid, provs, players, now),
                ),
        ),
      ],
    );
  }

  String _summary(List<String> ids, int gold) {
    final parts = <String>[
      if (ids.length == 1) _name(ids.first),
      if (ids.length > 1) '${ids.length} territories',
      if (gold > 0) '$gold gold',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(' + ');
  }

  Widget _row(
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

    final status = problem == null
        ? _left(o.timeLeft(now))
        : problem == TradeProblem.expired
            ? 'Expired'
            : 'Unavailable';

    return InkWell(
      onTap: () => _open(o, uid),
      child: Opacity(
        opacity: problem == null ? 1 : 0.5,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: ConqueraSpace.md,
            vertical: 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlayerTag(
                      name: mine ? o.toName : o.fromName,
                      color: _hex(mine ? o.toColor : o.fromColor),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'You give ${_summary(giveIds, giveGold)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConqueraText.label,
                    ),
                    Text(
                      'You get ${_summary(getIds, getGold)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConqueraText.label,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: ConqueraSpace.sm),
              Text(
                status,
                style: ConqueraText.label.copyWith(
                  color: problem == null
                      ? ConqueraColors.muted
                      : ConqueraColors.danger,
                ),
              ),
              Icon(Icons.chevron_right, color: ConqueraColors.muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: on ? ConqueraColors.ink : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          count > 0 ? '$label · $count' : label,
          style: ConqueraText.value.copyWith(
            color: on ? ConqueraColors.ink : ConqueraColors.muted,
          ),
        ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ConqueraSpace.md,
        ConqueraSpace.sm,
        ConqueraSpace.md,
        ConqueraSpace.md,
      ),
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

/// The give / get table. Left column is what YOU give, right is what you
/// get. Read-only here; the builder uses its own editable columns.
class _TradeTable extends StatelessWidget {
  final Widget give;
  final Widget take;

  const _TradeTable({required this.give, required this.take});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: ConqueraColors.divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: give),
            VerticalDivider(width: 1, color: ConqueraColors.divider),
            Expanded(child: take),
          ],
        ),
      ),
    );
  }
}

class _Column extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Column({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Text(title, style: ConqueraText.label),
        ),
        Divider(height: 1, color: ConqueraColors.divider),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

/// Read-only content of one side: territories, then gold.
List<Widget> _items(
  List<String> ids,
  int gold,
  String Function(String) name,
) {
  final out = <Widget>[
    for (final id in ids)
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(name(id), style: ConqueraText.value),
      ),
  ];
  if (gold > 0) {
    out.add(GoldAmount(gold, style: ConqueraText.figure.copyWith(fontSize: 16)));
  }
  if (out.isEmpty) out.add(Text('Nothing', style: ConqueraText.label));
  return out;
}

/// An offer in detail, with accept / decline / cancel.
class _OfferSheet extends StatelessWidget {
  final TradeOffer offer;
  final String uid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;
  final VoidCallback onAccept;
  final VoidCallback onRemove;

  const _OfferSheet({
    required this.offer,
    required this.uid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.onAccept,
    required this.onRemove,
  });

  String _name(String id) => provinceNames[id] ?? id;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([players, provinces]),
      builder: (context, _) {
        final mine = offer.fromId == uid;
        final now = ServerClock.now();
        final problem =
            TradeService.problem(offer, provinces.value, players.value, now);
        final giveIds = mine ? offer.giveProvinces : offer.takeProvinces;
        final giveGold = mine ? offer.giveGold : offer.takeGold;
        final getIds = mine ? offer.takeProvinces : offer.giveProvinces;
        final getGold = mine ? offer.takeGold : offer.giveGold;
        final other = mine ? offer.toName : offer.fromName;
        final myGold = players.value[uid]?.goldAt(now) ?? 0;
        final short = !mine && myGold < offer.takeGold;

        final String note;
        switch (problem) {
          case TradeProblem.expired:
            note = 'This offer expired.';
          case TradeProblem.ownerChanged:
            note = 'A territory in this trade changed owner.';
          case TradeProblem.buildingAppeared:
            note = 'A territory in this trade got a building.';
          case TradeProblem.giverShort:
            note = mine
                ? 'You have less gold than you offered.'
                : '$other has less gold than offered.';
          case null:
            note = short
                ? 'You need ${offer.takeGold} gold to accept.'
                : _left(offer.timeLeft(now));
        }
        final bad = problem != null || short;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(ConqueraSpace.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(mine ? 'To' : 'From', style: ConqueraText.label),
                    const SizedBox(width: ConqueraSpace.sm),
                    Flexible(
                      child: PlayerTag(
                        name: other,
                        color: _hex(mine ? offer.toColor : offer.fromColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: ConqueraSpace.md),
                _TradeTable(
                  give: _Column(
                    title: 'You give',
                    children: _items(giveIds, giveGold, _name),
                  ),
                  take: _Column(
                    title: 'You get',
                    children: _items(getIds, getGold, _name),
                  ),
                ),
                const SizedBox(height: ConqueraSpace.sm),
                Text(
                  note,
                  style: ConqueraText.label.copyWith(
                    color: bad ? ConqueraColors.danger : ConqueraColors.muted,
                  ),
                ),
                const SizedBox(height: ConqueraSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: onRemove,
                        child: Text(mine
                            ? (problem == null ? 'Cancel offer' : 'Remove')
                            : (problem == null ? 'Decline' : 'Remove')),
                      ),
                    ),
                    if (!mine) ...[
                      const SizedBox(width: ConqueraSpace.sm),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: bad ? null : onAccept,
                          child: const Text('Accept'),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Opt {
  final String id;
  final String name;
  const _Opt(this.id, this.name);
}

/// Step 1: choose who to trade with.
class _PickPlayerScreen extends StatefulWidget {
  final String gameId;
  final String myUid;
  final TradeService service;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;

  const _PickPlayerScreen({
    required this.gameId,
    required this.myUid,
    required this.service,
    required this.players,
    required this.provinces,
    required this.provinceNames,
  });

  @override
  State<_PickPlayerScreen> createState() => _PickPlayerScreenState();
}

class _PickPlayerScreenState extends State<_PickPlayerScreen> {
  Future<void> _pick(PlayerState p) async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => _BuilderScreen(
          gameId: widget.gameId,
          myUid: widget.myUid,
          partner: p,
          service: widget.service,
          players: widget.players,
          provinces: widget.provinces,
          provinceNames: widget.provinceNames,
        ),
      ),
    );
    if (sent == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ConqueraColors.surface,
      appBar: AppBar(
        backgroundColor: ConqueraColors.surface,
        foregroundColor: ConqueraColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('New trade', style: ConqueraText.title.copyWith(fontSize: 22)),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([widget.provinces, widget.players]),
        builder: (context, _) {
          final counts = <String, int>{};
          for (final p in widget.provinces.value.values) {
            final o = p.ownerId;
            if (o != null) counts[o] = (counts[o] ?? 0) + 1;
          }
          final list = [
            for (final p in widget.players.value.values)
              if (p.uid != widget.myUid && (counts[p.uid] ?? 0) > 0) p,
          ]..sort((a, b) => a.displayName
              .toLowerCase()
              .compareTo(b.displayName.toLowerCase()));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ConqueraSpace.md,
                  ConqueraSpace.sm,
                  ConqueraSpace.md,
                  ConqueraSpace.md,
                ),
                child: Text('Who do you want to trade with?',
                    style: ConqueraText.label),
              ),
              Divider(height: 1, color: ConqueraColors.divider),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Text('No other players yet.',
                            style: ConqueraText.label),
                      )
                    : ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: ConqueraColors.divider),
                        itemBuilder: (_, i) {
                          final p = list[i];
                          final n = counts[p.uid] ?? 0;
                          return InkWell(
                            onTap: () => _pick(p),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ConqueraSpace.md,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: PlayerTag(
                                      name: p.displayName,
                                      color: p.color,
                                    ),
                                  ),
                                  Text(
                                    n == 1 ? '1 territory' : '$n territories',
                                    style: ConqueraText.label,
                                  ),
                                  Icon(Icons.chevron_right,
                                      color: ConqueraColors.muted, size: 20),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Step 2: fill in the table and send it.
class _BuilderScreen extends StatefulWidget {
  final String gameId;
  final String myUid;
  final PlayerState partner;
  final TradeService service;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;

  const _BuilderScreen({
    required this.gameId,
    required this.myUid,
    required this.partner,
    required this.service,
    required this.players,
    required this.provinces,
    required this.provinceNames,
  });

  @override
  State<_BuilderScreen> createState() => _BuilderScreenState();
}

class _BuilderScreenState extends State<_BuilderScreen> {
  final TextEditingController _giveGold = TextEditingController();
  final TextEditingController _getGold = TextEditingController();
  final Set<String> _give = {};
  final Set<String> _get = {};
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

  List<_Opt> _options(String owner) {
    final list = [
      for (final p in widget.provinces.value.values)
        if (p.ownerId == owner && !p.hasBuilding) _Opt(p.id, _name(p.id)),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  int _owned(String uid) =>
      widget.provinces.value.values.where((p) => p.ownerId == uid).length;

  Future<void> _choose(bool give) async {
    final picked = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: ConqueraColors.surface,
      builder: (_) => _TerritorySheet(
        title: give ? 'Territories you give' : 'Territories you get',
        options: _options(give ? widget.myUid : widget.partner.uid),
        initial: give ? _give : _get,
      ),
    );
    if (picked == null) return;
    setState(() {
      final target = give ? _give : _get;
      target
        ..clear()
        ..addAll(picked);
      _error = null;
    });
  }

  /// Why the offer can't be sent yet (null = ready).
  String? get _problem {
    final give = _amount(_giveGold);
    final take = _amount(_getGold);
    if (_give.isEmpty && _get.isEmpty && give == 0 && take == 0) {
      return 'Add something to the trade.';
    }
    if (give > TradeService.maxGold || take > TradeService.maxGold) {
      return 'Gold is limited to 10,000,000.';
    }
    final mine =
        widget.players.value[widget.myUid]?.goldAt(ServerClock.now()) ?? 0;
    if (give > mine) return 'You only have ${mine.floor()} gold.';
    if (_owned(widget.myUid) - _give.length + _get.length < 1) {
      return 'Keep at least one territory.';
    }
    if (_owned(widget.partner.uid) - _get.length + _give.length < 1) {
      return '${widget.partner.displayName} must keep at least one territory.';
    }
    return null;
  }

  Future<void> _send() async {
    if (_busy || _problem != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.createOffer(
        gameId: widget.gameId,
        uid: widget.myUid,
        toId: widget.partner.uid,
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

  Widget _goldField(TextEditingController c) {
    return TextField(
      controller: c,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      style: ConqueraText.figure.copyWith(fontSize: 16),
      decoration: InputDecoration(
        isDense: true,
        hintText: '0',
        prefixIcon: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: GoldIcon(size: 16),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() => _error = null),
    );
  }

  Widget _side(String title, Set<String> ids, TextEditingController gold,
      bool give) {
    return _Column(
      title: title,
      children: [
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(child: Text(_name(id), style: ConqueraText.value)),
                InkWell(
                  onTap: () => setState(() => ids.remove(id)),
                  child: Icon(Icons.close, size: 16, color: ConqueraColors.muted),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : () => _choose(give),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(ids.isEmpty ? '+ Territory' : '+ More'),
          ),
        ),
        const SizedBox(height: ConqueraSpace.sm),
        _goldField(gold),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final problem = _problem;
    return Scaffold(
      backgroundColor: ConqueraColors.surface,
      appBar: AppBar(
        backgroundColor: ConqueraColors.surface,
        foregroundColor: ConqueraColors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('New trade', style: ConqueraText.title.copyWith(fontSize: 22)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          children: [
            Row(
              children: [
                Text('With', style: ConqueraText.label),
                const SizedBox(width: ConqueraSpace.sm),
                Flexible(
                  child: PlayerTag(
                    name: widget.partner.displayName,
                    color: widget.partner.color,
                  ),
                ),
              ],
            ),
            const SizedBox(height: ConqueraSpace.md),
            _TradeTable(
              give: _side('You give', _give, _giveGold, true),
              take: _side('You get', _get, _getGold, false),
            ),
            const SizedBox(height: ConqueraSpace.md),
            Text(
              'Only you and ${widget.partner.displayName} can see this offer. '
              'It stays open for 12 hours and switches off if a territory '
              'changes owner or gets a building, or if you hold less gold '
              'than you offered. Troops stay with the territory.',
              style: ConqueraText.label,
            ),
            const SizedBox(height: ConqueraSpace.md),
            if (_error != null || (problem != null && _touched))
              Padding(
                padding: const EdgeInsets.only(bottom: ConqueraSpace.sm),
                child: Text(
                  _error ?? problem!,
                  style: ConqueraText.label.copyWith(color: ConqueraColors.danger),
                ),
              ),
            OutlinedButton(
              onPressed: _busy || problem != null ? null : _send,
              child: Text(_busy ? 'Sending...' : 'Send offer'),
            ),
          ],
        ),
      ),
    );
  }

  bool get _touched =>
      _give.isNotEmpty ||
      _get.isNotEmpty ||
      _giveGold.text.isNotEmpty ||
      _getGold.text.isNotEmpty;
}

/// Multi-select list of territories with a search box.
class _TerritorySheet extends StatefulWidget {
  final String title;
  final List<_Opt> options;
  final Set<String> initial;

  const _TerritorySheet({
    required this.title,
    required this.options,
    required this.initial,
  });

  @override
  State<_TerritorySheet> createState() => _TerritorySheetState();
}

class _TerritorySheetState extends State<_TerritorySheet> {
  late final Set<String> _picked = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final o in widget.options)
        if (o.name.toLowerCase().contains(_query.toLowerCase())) o,
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ConqueraSpace.md,
                  ConqueraSpace.md,
                  ConqueraSpace.md,
                  ConqueraSpace.sm,
                ),
                child: Text(widget.title, style: ConqueraText.name),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: ConqueraSpace.md),
                child: TextField(
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'Search',
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              const SizedBox(height: ConqueraSpace.sm),
              Divider(height: 1, color: ConqueraColors.divider),
              Expanded(
                child: shown.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(ConqueraSpace.lg),
                          child: Text(
                            widget.options.isEmpty
                                ? 'No territories without a building.'
                                : 'No match.',
                            style: ConqueraText.label,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final o = shown[i];
                          final on = _picked.contains(o.id);
                          return InkWell(
                            onTap: () => setState(() {
                              on ? _picked.remove(o.id) : _picked.add(o.id);
                            }),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: ConqueraSpace.md,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                      child: Text(o.name,
                                          style: ConqueraText.value)),
                                  if (on)
                                    Icon(Icons.check,
                                        size: 18, color: ConqueraColors.ink),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              Divider(height: 1, color: ConqueraColors.divider),
              Padding(
                padding: const EdgeInsets.all(ConqueraSpace.md),
                child: OutlinedButton(
                  onPressed: _picked.length > TradeService.maxProvincesPerSide
                      ? null
                      : () => Navigator.of(context).pop(_picked),
                  child: Text(_picked.length > TradeService.maxProvincesPerSide
                      ? 'Max ${TradeService.maxProvincesPerSide} territories'
                      : 'Done (${_picked.length})'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}