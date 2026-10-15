import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/dev_session.dart';
import '../config/game_rules.dart';
import '../models/attack_result.dart';
import '../models/battle_event.dart';
import '../models/player_state.dart';
import '../models/province.dart';
import '../models/province_state.dart';
import '../painters/map_painter.dart';
import '../screens/updates_screen.dart';
import '../services/firestore_service.dart';
import '../state/map_controller.dart';
import '../theme/conquera_theme.dart';
import '../widgets/attack_dialog.dart';
import '../widgets/country_info_panel.dart';
import '../widgets/gold_amount.dart';
import '../widgets/map_viewport.dart';
import '../widgets/player_top_bar.dart';
import '../widgets/province_detail_dialog.dart';
import '../widgets/world_sidebar.dart';

/// Pannable, zoomable world map. Tap a country to outline it and open its
/// info panel; tap the ocean (or the close button) to clear. The panel's
/// "Manage" button opens the province window (build / reinforce).
///
/// [MapViewport] gives smooth pan/zoom (with a gliding fling), wraps the
/// world sideways and stops at the vertical limits. A [Listener] (not a
/// GestureDetector) does tap detection, because a nested tap recognizer
/// loses the gesture arena to the viewport's scale recognizer. The scene
/// holds two copies of the world, so [PointerEvent.localPosition] is folded
/// back onto the first copy before hit-testing.
///
/// The map is three layers: a static base (all countries), a badge layer
/// (building icons and power numbers) and a small selection overlay. Icons
/// and numbers have a fixed size on the map (they grow and shrink with it);
/// the selection outline keeps a constant on-screen thickness.
class MapScreen extends StatefulWidget {
  static const String defaultAssetPath = 'assets/maps/world.svg';

  /// The world (games/{gameId}) being played.
  final String gameId;

  /// A country to center the camera on at the start (the one the player just
  /// spawned in). Without it the camera centers on one of the player's own
  /// countries, or on Africa.
  final String? focusProvinceId;

  final String assetPath;

  const MapScreen({
    super.key,
    required this.gameId,
    this.focusProvinceId,
    this.assetPath = defaultAssetPath,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin {
  final MapController _controller = MapController();
  final MapCameraController _transform = MapCameraController();

  Offset? _pointerDown;
  static const double _tapSlop = 12.0; // screen pixels

  // Zoom limits. The most zoomed-out view is "Africa fills the screen", so
  // the player can never see the whole planet at once.
  static const double _maxScale = 16;

  /// How far past Greenland's northern tip / South America's southern tip
  /// the view may go, as a share of the map height. The map wraps sideways
  /// (the earth is round) but not up and down.
  static const double _topMarginFrac = 0.01;
  static const double _bottomMarginFrac = 0.03;

  /// Extra room around Africa's bounding box at the zoomed-out limit.
  static const double _africaPadding = 0.04;

  /// Power numbers appear once the map is zoomed in to this many times the
  /// most zoomed-out view. Higher = you have to zoom in further.
  static const double _powerZoomFactor = 1.3;

  /// Building icons and power numbers have a fixed size in MAP units (they
  /// scale with the map like the countries do). These are how big they look
  /// on screen at the zoom where they are first visible.
  static const double _iconPxAtMinZoom = 20;
  static const double _powerPxAtPowerZoom = 18;

  /// Mainland Africa (ISO alpha-2). Far-off island nations (Cape Verde,
  /// Mauritius, Seychelles, Comoros, Sao Tome) are left out so they don't
  /// stretch the zoom-out limit.
  static const Set<String> _africaIds = {
    'DZ', 'AO', 'BJ', 'BW', 'BF', 'BI', 'CM', 'CF', 'TD', 'CG', 'CD', 'CI',
    'DJ', 'EG', 'GQ', 'ER', 'SZ', 'ET', 'GA', 'GM', 'GH', 'GN', 'GW', 'KE',
    'LS', 'LR', 'LY', 'MG', 'MW', 'ML', 'MR', 'MA', 'MZ', 'NA', 'NE', 'NG',
    'RW', 'SN', 'SL', 'SO', 'ZA', 'SS', 'SD', 'TZ', 'TG', 'TN', 'UG', 'EH',
    'ZM', 'ZW',
  };

  Rect? _africaRectCache;

  Size? _fittedFor; // viewport size the initial fit was computed for

  // Live game data. Notifiers (instead of plain fields) so the province
  // window can listen to the same data without opening its own streams.
  final FirestoreService _firestore = FirestoreService();
  late final String _uid = DevSession.uid;
  StreamSubscription<Map<String, ProvinceState>>? _provincesSub;
  StreamSubscription<Map<String, PlayerState>>? _playersSub;
  StreamSubscription<BattleEvent>? _eventsSub;

  /// Attacks by other players waiting to be played on this map.
  final List<BattleEvent> _eventQueue = [];
  final Set<String> _seenEventIds = {};
  bool _drainingEvents = false;

  /// If true, the camera flies to other players' battles so nobody misses
  /// the invasion and the "annexed" pop-up.
  static const bool _cameraFollowsBattles = true;
  final ValueNotifier<Map<String, ProvinceState>> _provinceStates =
      ValueNotifier(const {});
  final ValueNotifier<Map<String, PlayerState>> _players =
      ValueNotifier(const {});

  /// How opaque an owner's color is over the land fill (0-255).
  static const int _ownerFillAlpha = 170;

  // --- Battle on the map -------------------------------------------------
  // After "Confirm attack" the dialog closes and the fight plays out here:
  // involved borders are outlined, then a sweep (win) or shake (loss) plays
  // and a pop-up names the territory.

  /// The battle being shown; null when none.
  BattleView? _battle;

  /// Colors forced on provinces while a battle plays, so the base layer
  /// doesn't flip to the new owner before the sweep reaches it.
  Map<String, Color> _colorOverrides = const {};

  /// Provinces the base layer skips (the battle layer draws them).
  Set<String> _hiddenIds = const {};

  /// Troop counts shown on the map while a battle or claim plays, so the
  /// new numbers (the split) only appear once the sweep has finished.
  /// Empty = show the live numbers. A province missing from a non-empty map
  /// shows 0 (e.g. the territory being claimed).
  Map<String, double> _frozenTroops = const {};

  /// Enemy power shown for a moment after a failed attack (province id ->
  /// troops left), then hidden again.
  Map<String, int> _revealedPower = const {};

  /// Drives how long the revealed power stays up and when it fades:
  /// [_revealHold] fully visible, then [_revealFade] fading out.
  static const Duration _revealHold = Duration(milliseconds: 2500);
  static const Duration _revealFade = Duration(milliseconds: 1000);
  late final AnimationController _revealCtl = AnimationController(
    vsync: this,
    duration: _revealHold + _revealFade,
  )..addListener(() {
      if (mounted && _revealedPower.isNotEmpty) setState(() {});
    });

  double get _revealOpacity {
    final holdShare =
        _revealHold.inMilliseconds / (_revealHold + _revealFade).inMilliseconds;
    final t = _revealCtl.value;
    if (t <= holdShare) return 1;
    return (1 - (t - holdShare) / (1 - holdShare)).clamp(0.0, 1.0);
  }

  Map<String, double> _snapshotTroops() => {
        for (final e in _provinceStates.value.entries) e.key: e.value.troops,
      };

  /// Pulse of the outlines (repeats while the battle is shown).
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  /// The sweep (win) or shake (loss), 0..1.
  late final AnimationController _fx = AnimationController(vsync: this);

  /// The pop-up text, 0..1.
  late final AnimationController _popupAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  _Popup? _popup;

  bool get _battleRunning => _battle != null;

  // --- Camera pan toward the war zone -----------------------------------
  /// Last viewport size, remembered so the camera can be moved from code.
  Size _viewport = Size.zero;
  late final AnimationController _cam = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..addListener(_applyCameraFrame);
  Offset _camFromFocus = Offset.zero;
  Offset _camToFocus = Offset.zero;
  double _camFromScale = 1;
  double _camToScale = 1;

  /// A target smaller than this on screen (longest side, px) makes the
  /// camera zoom in a little so the animation can actually be seen.
  static const double _minTargetPx = 70;

  @override
  void initState() {
    super.initState();
    _controller.loadMap(widget.assetPath);

    _provincesSub = _firestore
        .watchProvinces(gameId: widget.gameId)
        .listen(
      (states) => _provinceStates.value = states,
      onError: (Object e) => debugPrint('Provinces stream error: $e'),
    );
    _playersSub = _firestore
        .watchPlayers(gameId: widget.gameId)
        .listen(
      (players) => _players.value = players,
      onError: (Object e) => debugPrint('Players stream error: $e'),
    );
    _eventsSub = _firestore.watchBattleEvents(gameId: widget.gameId).listen(
      _onBattleEvent,
      onError: (Object e) => debugPrint('Battle events stream error: $e'),
    );
  }

  @override
  void dispose() {
    _provincesSub?.cancel();
    _playersSub?.cancel();
    _eventsSub?.cancel();
    _provinceStates.dispose();
    _players.dispose();
    _controller.dispose();
    _transform.dispose();
    _pulse.dispose();
    _fx.dispose();
    _popupAnim.dispose();
    _cam.dispose();
    _revealCtl.dispose();
    super.dispose();
  }

  /// Bounding box of Africa (padded), or null if its countries aren't found.
  Rect? _africaRect() {
    final cached = _africaRectCache;
    if (cached != null) return cached;

    Rect? union;
    for (final province in _controller.provinces) {
      if (!_africaIds.contains(province.id)) continue;
      union = union == null
          ? province.bounds
          : union.expandToInclude(province.bounds);
    }
    if (union == null) return null;

    final pad = max(union.width, union.height) * _africaPadding;
    return _africaRectCache = union.inflate(pad);
  }

  /// Highest and lowest map y the camera may show: the northern tip of
  /// Greenland, and a little past the southern tip of South America.
  (double, double) _verticalLimits() {
    final map = _controller.mapSize;
    final top =
        (_controller.provinceById('GL')?.bounds.top ?? 0) -
            map.height * _topMarginFrac;

    double? south;
    for (final id in const ['AR', 'CL']) {
      final bottom = _controller.provinceById(id)?.bounds.bottom;
      if (bottom != null && (south == null || bottom > south)) south = bottom;
    }
    final bottom = (south ?? map.height) + map.height * _bottomMarginFrac;
    return (top, bottom);
  }

  /// Gives the camera its rules for this viewport: wrap sideways, stay
  /// between the vertical limits.
  void _configureCamera(Size viewport) {
    final limits = _verticalLimits();
    _transform
      ..wrapWidth = _controller.mapSize.width
      ..topLimit = limits.$1
      ..bottomLimit = limits.$2
      ..viewportHeight = viewport.height;
  }

  /// The most zoomed-out scale allowed: Africa fills the viewport, but
  /// never so far out that the view shows more than one world across or
  /// more than the allowed height.
  double _minScaleFor(Size viewport) {
    final map = _controller.mapSize;
    if (map.isEmpty || viewport.isEmpty) return 1.0;

    final limits = _verticalLimits();
    var scale = max(
      viewport.width / map.width,
      viewport.height / (limits.$2 - limits.$1),
    );
    final africa = _africaRect();
    if (africa != null) {
      scale = max(
        scale,
        min(viewport.width / africa.width, viewport.height / africa.height),
      );
    }
    return scale;
  }

  /// Starts at the zoomed-out limit, centered on Africa. Runs on first
  /// layout (and again if the window size changes).
  void _fitToViewport(Size viewport) {
    final map = _controller.mapSize;
    if (map.isEmpty || viewport.isEmpty) return;

    final scale = _minScaleFor(viewport);

    // Start on the player's own land if we know where it is, otherwise on
    // Africa. A player who just spawned starts zoomed out on Africa and
    // then flies in slowly to their country (see _spawnFlight).
    final justSpawned = widget.focusProvinceId != null && !_spawnFlightDone;
    final focus = (justSpawned ? null : _homePoint()) ??
        _africaRect()?.center ??
        map.center(Offset.zero);

    final dx = viewport.width / 2 - focus.dx * scale;
    final dy = viewport.height / 2 - focus.dy * scale;

    _transform.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
    _fittedFor = viewport;
    if (justSpawned) _spawnFlight();
  }

  bool _spawnFlightDone = false;

  /// After spawning: a slow pan and zoom from the world view to the
  /// player's starting country.
  Future<void> _spawnFlight() async {
    _spawnFlightDone = true;
    final id = widget.focusProvinceId;
    final target = id == null ? null : _controller.provinceById(id);
    if (target == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    final side = max(target.bounds.longestSide, 1.0);
    final shortSide = min(_viewport.width, _viewport.height);
    // Zoom until the country fills roughly 40% of the screen.
    final wanted = (shortSide * 0.4) / side;

    final normal = _cam.duration;
    _cam.duration = const Duration(milliseconds: 3500);
    try {
      await _panTo(target.anchor, minScale: wanted);
    } finally {
      _cam.duration = normal;
    }
  }

  /// Where the player's land is: the country they just spawned in, or else
  /// any country they own. Null if neither is known yet.
  Offset? _homePoint() {
    var id = widget.focusProvinceId;
    if (id == null) {
      for (final entry in _provinceStates.value.entries) {
        if (entry.value.ownerId == _uid) {
          id = entry.key;
          break;
        }
      }
    }
    return id == null ? null : _controller.provinceById(id)?.anchor;
  }

  /// provinceId -> owner's color, for the map's owner fills.
  Map<String, Color> _ownerFillColors() {
    final players = _players.value;
    final colors = <String, Color>{};
    _provinceStates.value.forEach((id, state) {
      final owner = players[state.ownerId];
      if (owner != null) colors[id] = owner.color.withAlpha(_ownerFillAlpha);
    });
    colors.addAll(_colorOverrides);
    return colors;
  }

  /// Fog of war: you see your own provinces, plus every province that
  /// borders one of your radars.
  bool _canSee(String id) {
    final states = _provinceStates.value;
    final s = states[id];
    if (s == null) return false;
    if (s.ownerId == _uid) return true;
    for (final n in _controller.neighborsOf(id)) {
      final ns = states[n];
      if (ns != null &&
          ns.ownerId == _uid &&
          GameRules.revealsNeighbors(ns.buildingType)) {
        return true;
      }
    }
    return false;
  }

  /// What to draw on top of each province: its building's icon and its
  /// power. Provinces with neither get no badge.
  List<MapBadge> _badges() {
    final badges = <MapBadge>[];
    _provinceStates.value.forEach((id, state) {
      final province = _controller.provinceById(id);
      if (province == null) return;

      // Briefly show what is left of a province you just failed to take.
      final revealed = _revealedPower[id];
      if (revealed != null && state.ownerId != _uid) {
        badges.add(
          MapBadge(
            anchor: province.anchor,
            power: revealed,
            extent: sqrt(province.bounds.width * province.bounds.height),
            color: _players.value[state.ownerId]?.color,
            opacity: _revealOpacity,
          ),
        );
        return;
      }

      // Fog of war: only provinces you own or see with a radar show a
      // building and power.
      if (!_canSee(id)) return;
      final icon = state.hasBuilding
          ? GameRules.buildingById(state.buildingType)?.icon
          : null;
      final power = (_frozenTroops.isEmpty
              ? state.troops
              : (_frozenTroops[id] ?? 0))
          .floor();
      if (icon == null && power <= 0) return;

      badges.add(
        MapBadge(
          anchor: province.anchor,
          icon: icon,
          power: power,
          extent: sqrt(province.bounds.width * province.bounds.height),
          color: _players.value[state.ownerId]?.color,
        ),
      );
    });
    return badges;
  }

  /// False when none of the player's provinces that would take part holds
  /// more than 1 power: a province with only 1 power can't attack or claim.
  /// A claim uses the bordering provinces (a barracks can pay for it); an
  /// attack also counts the barracks that join it.
  bool _canSplitPower(Province target, {required bool claim}) {
    final states = _provinceStates.value;
    final ids = {
      ..._myBorderingIds(target),
      if (!claim) ..._supportLinks(target).keys,
    };
    return ids.any((id) {
      final s = states[id];
      return s != null && GameRules.canFight(s.troops, s.buildingType);
    });
  }

  /// Ids of the provinces the local player owns that border [target].
  Set<String> _myBorderingIds(Province target) {
    final states = _provinceStates.value;
    return {
      for (final id in _controller.neighborsOf(target.id))
        if (states[id]?.ownerId == _uid) id,
    };
  }

  /// Buys the unclaimed [target] (it must border one of the player's
  /// provinces). Asks first, then plays the annexation on the map.
  Future<void> _claim(Province target) async {
    if (_battleRunning) return;
    final cost = GameRules.claimCost;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: ConqueraColors.divider),
        ),
        title: Text('Claim ${target.name}?', style: ConqueraText.name),
        content: Text.rich(
          TextSpan(
            style: ConqueraText.value,
            children: [
              const TextSpan(text: 'It costs '),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: GoldAmount(cost, style: ConqueraText.value),
              ),
              const TextSpan(text: ' and starts your attack cooldown.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Claim for '),
                GoldAmount(cost),
              ],
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _runClaim(target);
  }

  /// Buys [target] and plays the same camera flight and sweep as a won
  /// attack, without the war borders, then the "annexed" pop-up.
  Future<void> _runClaim(Province target) async {
    if (_battleRunning) return;
    final me = _players.value[_uid];
    final attackerColor = me?.color ?? ConqueraColors.accent;
    final messenger = ScaffoldMessenger.of(context);
    final fighters = _myBorderingIds(target);

    _controller.clearSelection();
    _popupAnim.stop();
    _popupAnim.value = 0;
    _popup = null;
    _fx.value = 0;
    setState(() {
      // Keep the land looking unclaimed until the sweep reaches it.
      _colorOverrides = {target.id: Colors.transparent};
      _frozenTroops = _snapshotTroops();
      _hiddenIds = const {};
      _battle = _battleView(
        target: target,
        fighterIds: fighters,
        defenderSupportIds: const [],
        attackerColor: attackerColor,
        defenderColor: ConqueraColors.muted,
        outcome: BattleOutcome.pending,
        showOutlines: false,
      );
    });

    // Fly to the territory while the claim goes to the server.
    final pan = _panToTarget(target);

    String? error;
    try {
      await _firestore.claimUnclaimedProvince(
        gameId: widget.gameId,
        uid: _uid,
        provinceId: target.id,
        neighborIds: _controller.neighborsOf(target.id),
      );
    } on GameActionException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('Claim failed: $e');
      error = 'Something went wrong. Try again.';
    }
    await pan;
    if (!mounted) return;

    if (error != null) {
      _endBattle();
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }

    setState(() {
      _battle = _battleView(
        target: target,
        fighterIds: fighters,
        defenderSupportIds: const [],
        attackerColor: attackerColor,
        defenderColor: ConqueraColors.muted,
        outcome: BattleOutcome.won,
        showOutlines: false,
      );
    });
    _fx.duration = const Duration(milliseconds: 1100);
    await _fx.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _colorOverrides = {target.id: attackerColor.withAlpha(_ownerFillAlpha)};
      _frozenTroops = const {}; // the troops split now
    });
    _showPopup(
      target,
      'annexed ',
      attackerColor,
      subject: _players.value[_uid]?.displayName,
    );

    await _popupAnim.forward(from: 0);
    if (!mounted) return;
    _endBattle();
  }

  /// Barracks the player owns that could join an attack on [target]:
  /// candidate province id -> the player's bordering provinces it touches.
  /// (The battle re-checks this on the server side of the transaction.)
  Map<String, Set<String>> _supportLinks(Province target) {
    final states = _provinceStates.value;
    final border = _controller.neighborsOf(target.id);
    final links = <String, Set<String>>{};
    for (final b in border) {
      if (states[b]?.ownerId != _uid) continue;
      for (final m in _controller.neighborsOf(b)) {
        if (m == target.id || border.contains(m)) continue;
        final state = states[m];
        if (state == null || state.ownerId != _uid) continue;
        if (!GameRules.supportsAttacks(state.buildingType)) continue;
        (links[m] ??= <String>{}).add(b);
      }
    }
    return links;
  }

  /// The map point at the middle of the screen right now.
  Offset _currentFocus() {
    final m = _transform.value;
    final scale = m.getMaxScaleOnAxis();
    return Offset(
      (_viewport.width / 2 - m.storage[12]) / scale,
      (_viewport.height / 2 - m.storage[13]) / scale,
    );
  }

  void _applyCameraFrame() {
    if (_viewport.isEmpty) return;
    final t = Curves.easeInOutCubic.transform(_cam.value);
    final scale = _camFromScale * pow(_camToScale / _camFromScale, t);
    final focus = Offset.lerp(_camFromFocus, _camToFocus, t)!;
    _transform.value = Matrix4.identity()
      ..translate(
        _viewport.width / 2 - focus.dx * scale,
        _viewport.height / 2 - focus.dy * scale,
      )
      ..scale(scale);
  }

  /// Smoothly moves the camera so [focus] (map coordinates) is centered,
  /// zooming in only if [minScale] asks for more than the current zoom.
  Future<void> _panTo(Offset focus, {double minScale = 0}) async {
    if (_viewport.isEmpty) return;
    final minZoom = _minScaleFor(_viewport);
    final maxZoom = max(_maxScale, minZoom * 14);
    final current = _transform.value.getMaxScaleOnAxis();
    final scale = max(current, minScale).clamp(minZoom, maxZoom).toDouble();

    // The world wraps: fly to whichever copy of the target is nearest, so
    // the camera takes the short way round. The camera controller keeps the
    // result inside the vertical limits.
    final map = _controller.mapSize;
    final from = _currentFocus();
    var targetX = focus.dx;
    if (map.width > 0) {
      targetX -= map.width * ((targetX - from.dx) / map.width).round();
    }
    final target = Offset(targetX, focus.dy);

    _camFromFocus = from;
    _camToFocus = target;
    _camFromScale = current;
    _camToScale = scale;
    await _cam.forward(from: 0);
  }

  /// Flies the camera to [target] (the country being invaded or claimed),
  /// zooming in a little if it is too small to see the animation.
  Future<void> _panToTarget(Province target) {
    final current = _transform.value.getMaxScaleOnAxis();
    final targetSide = max(target.bounds.longestSide, 1.0);
    final wanted = _minTargetPx / targetSide;
    return _panTo(target.anchor, minScale: wanted > current ? wanted : 0);
  }

  /// Opens the battle preview against [target]. Confirming closes it and
  /// hands back the ids of the fighting provinces; the fight itself then
  /// plays on the map.
  Future<void> _openAttack(Province target) async {
    if (_battleRunning) return;
    final fighters = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AttackDialog(
        uid: _uid,
        targetId: target.id,
        targetName: target.name,
        neighborIds: _controller.neighborsOf(target.id),
        supportLinks: _supportLinks(target),
        targetVisible: _canSee(target.id),
        provinceNames: {
          for (final p in _controller.provinces) p.id: p.name,
        },
        provinceStates: _provinceStates,
        players: _players,
      ),
    );
    if (fighters == null || !mounted) return;
    try {
      await _runBattle(target, fighters);
    } catch (e, st) {
      debugPrint('Battle animation failed: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) _endBattle();
    }
  }

  /// Direction the attack comes from: from the middle of the fighting
  /// provinces toward the target.
  Offset _attackDirection(Province target, Iterable<String> fighterIds) {
    final border = _controller.neighborsOf(target.id);
    var ids = [for (final id in fighterIds) if (border.contains(id)) id];
    if (ids.isEmpty) ids = fighterIds.toList();

    var sum = Offset.zero;
    var count = 0;
    for (final id in ids) {
      final p = _controller.provinceById(id);
      if (p == null) continue;
      sum += p.anchor;
      count++;
    }
    if (count == 0) return const Offset(1, 0);
    final from = sum / count.toDouble();
    final delta = target.anchor - from;
    return delta.distance < 0.001 ? const Offset(1, 0) : delta / delta.distance;
  }

  /// The defender's barracks that border [target] and so help defend it.
  Set<String> _defenderSupportIds(Province target) {
    final states = _provinceStates.value;
    final defenderId = states[target.id]?.ownerId;
    if (defenderId == null) return const {};
    return {
      for (final id in _controller.neighborsOf(target.id))
        if (id != target.id &&
            states[id]?.ownerId == defenderId &&
            GameRules.supportsAttacks(states[id]!.buildingType))
          id,
    };
  }

  BattleView _battleView({
    required Province target,
    required Iterable<String> fighterIds,
    required Iterable<String> defenderSupportIds,
    required Color attackerColor,
    required Color defenderColor,
    required BattleOutcome outcome,
    bool showOutlines = true,
  }) {
    return BattleView(
      attackerPaths: [
        for (final id in fighterIds)
          if (_controller.provinceById(id) != null)
            _controller.provinceById(id)!.path,
      ],
      attackerColor: attackerColor,
      targetPath: target.path,
      defenderSupportPaths: [
        for (final id in defenderSupportIds)
          if (_controller.provinceById(id) != null)
            _controller.provinceById(id)!.path,
      ],
      defenderColor: defenderColor,
      outcome: outcome,
      sweepDirection: _attackDirection(target, fighterIds),
      fillAlpha: _ownerFillAlpha,
      showOutlines: showOutlines,
    );
  }

  /// Runs the attack against the server and plays what happens on the map.
  Future<void> _runBattle(Province target, Set<String> previewFighters) async {
    final players = _players.value;
    final states = _provinceStates.value;
    final me = players[_uid];
    final defender = players[states[target.id]?.ownerId];
    final attackerColor = me?.color ?? ConqueraColors.accent;
    final defenderColor = defender?.color ?? ConqueraColors.muted;
    final messenger = ScaffoldMessenger.of(context);
    final previewDefenders = _defenderSupportIds(target);

    // Back to the map: outline everyone involved and freeze the target's
    // current color until the animation has played.
    _controller.clearSelection();
    _popupAnim.stop();
    _popupAnim.value = 0;
    _popup = null;
    _fx.value = 0;
    _pulse.repeat(reverse: true);
    setState(() {
      _colorOverrides = {target.id: defenderColor.withAlpha(_ownerFillAlpha)};
      _frozenTroops = _snapshotTroops();
      _hiddenIds = const {};
      _battle = _battleView(
        target: target,
        fighterIds: previewFighters,
        defenderSupportIds: previewDefenders,
        attackerColor: attackerColor,
        defenderColor: defenderColor,
        outcome: BattleOutcome.pending,
      );
    });

    // Fly to the invaded country while the attack goes to the server.
    final pan = _panToTarget(target);

    final started = DateTime.now();
    AttackResult? result;
    String? error;
    try {
      result = await _firestore.attackProvince(
        gameId: widget.gameId,
        uid: _uid,
        targetId: target.id,
        neighborIds: _controller.neighborsOf(target.id),
        supportLinks: _supportLinks(target),
      );
    } on GameActionException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('Attack failed: $e');
      error = 'Something went wrong. Try again.';
    }
    // The animation starts once the camera has arrived (and the outlines have
    // been on screen for a moment), even if the server was quick.
    final wait =
        const Duration(milliseconds: 900) - DateTime.now().difference(started);
    if (error == null && !wait.isNegative) await Future<void>.delayed(wait);
    await pan;
    if (!mounted) return;
    debugPrint('Battle result: won=${result?.won} error=$error');

    if (result == null) {
      _endBattle();
      messenger.showSnackBar(
        SnackBar(content: Text(error ?? 'Attack failed.')),
      );
      return;
    }

    final fighters = result.fighterIds.isEmpty
        ? previewFighters
        : result.fighterIds.toSet();

    final defenders = result.defenderSupportIds.toSet();

    if (result.won) {
      setState(() {
        _battle = _battleView(
          target: target,
          fighterIds: fighters,
          defenderSupportIds: defenders,
          attackerColor: attackerColor,
          defenderColor: defenderColor,
          outcome: BattleOutcome.won,
        );
      });
      _fx.duration = const Duration(milliseconds: 1100);
      await _fx.forward(from: 0);
      if (!mounted) return;
      // The target is ours now; keep it painted that way until the live data
      // has caught up. The troops split now that the sweep is done.
      setState(() {
        _colorOverrides = {target.id: attackerColor.withAlpha(_ownerFillAlpha)};
        _frozenTroops = const {};
      });
      _showPopup(target, 'annexed ', attackerColor, subject: me?.displayName);
    } else {
      setState(() {
        _hiddenIds = {target.id};
        _battle = _battleView(
          target: target,
          fighterIds: fighters,
          defenderSupportIds: defenders,
          attackerColor: attackerColor,
          defenderColor: defenderColor,
          outcome: BattleOutcome.lost,
        );
      });
      _fx.duration = const Duration(milliseconds: 825);
      await _fx.forward(from: 0);
      if (!mounted) return;
      setState(() {
        _hiddenIds = const {};
        _frozenTroops = const {};
      });
      _showPopup(target, 'Failed to annex ', attackerColor);
      _revealLeftover(target.id, result.defenderPowerLeft);
    }

    // Keep the outlines up while the pop-up is read, then clear everything.
    await _popupAnim.forward(from: 0);
    if (!mounted) return;
    _endBattle();
  }

  /// Shows the defender's remaining power on the map for a few seconds,
  /// then fades it away.
  Future<void> _revealLeftover(String id, double left) async {
    setState(() => _revealedPower = {id: left.floor()});
    await _revealCtl.forward(from: 0);
    if (!mounted) return;
    setState(() => _revealedPower = const {});
  }

  void _showPopup(
    Province target,
    String lead,
    Color nameColor, {
    String? subject,
  }) {
    setState(() {
      _popup = _Popup(
        anchor: target.anchor,
        subject: subject,
        lead: lead,
        name: target.name,
        nameColor: nameColor,
      );
    });
  }

  // --- Watching other players' battles -----------------------------------

  void _onBattleEvent(BattleEvent e) {
    if (!_seenEventIds.add(e.id)) return;
    if (e.attackerId == _uid) return; // the attacker plays their own fight
    final at = e.at;
    if (at != null && DateTime.now().difference(at).inSeconds > 20) return;
    _eventQueue.add(e);
    _drainEvents();
  }

  /// Plays queued battles one after another, waiting for this player's own
  /// battle (or the previous one) to finish first.
  Future<void> _drainEvents() async {
    if (_drainingEvents) return;
    _drainingEvents = true;
    try {
      while (mounted && _eventQueue.isNotEmpty) {
        if (_battleRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        final e = _eventQueue.removeAt(0);
        try {
          await _spectateBattle(e);
        } catch (err, st) {
          debugPrint('Spectating failed: $err');
          debugPrintStack(stackTrace: st);
          if (mounted) _endBattle();
        }
      }
    } finally {
      _drainingEvents = false;
    }
  }

  /// Replays [e] on this map: outlines, the sweep, and (for a conquest)
  /// the "player annexed country" pop-up.
  Future<void> _spectateBattle(BattleEvent e) async {
    final target = _controller.provinceById(e.targetId);
    if (target == null || !mounted) return;
    final players = _players.value;
    final attacker = players[e.attackerId];
    final defender = e.defenderId == null ? null : players[e.defenderId];
    final attackerColor = attacker?.color ?? ConqueraColors.accent;
    final defenderColor = defender?.color ?? ConqueraColors.muted;

    _popupAnim.stop();
    _popupAnim.value = 0;
    _popup = null;
    _fx.value = 0;
    _pulse.repeat(reverse: true);
    setState(() {
      // The live data already shows the result; keep the old owner's color
      // until the sweep has played.
      _colorOverrides = {target.id: defenderColor.withAlpha(_ownerFillAlpha)};
      _hiddenIds = const {};
      _battle = _battleView(
        target: target,
        fighterIds: e.fighterIds,
        defenderSupportIds: e.defenderSupportIds,
        attackerColor: attackerColor,
        defenderColor: defenderColor,
        outcome: BattleOutcome.pending,
      );
    });

    if (_cameraFollowsBattles) await _panToTarget(target);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    if (e.won) {
      setState(() {
        _battle = _battleView(
          target: target,
          fighterIds: e.fighterIds,
          defenderSupportIds: e.defenderSupportIds,
          attackerColor: attackerColor,
          defenderColor: defenderColor,
          outcome: BattleOutcome.won,
        );
      });
      _fx.duration = const Duration(milliseconds: 1100);
      await _fx.forward(from: 0);
      if (!mounted) return;
      setState(() {
        _colorOverrides = {target.id: attackerColor.withAlpha(_ownerFillAlpha)};
      });
      _showPopup(
        target,
        'annexed ',
        attackerColor,
        subject: attacker?.displayName ?? 'A player',
      );
    } else {
      setState(() {
        _hiddenIds = {target.id};
        _battle = _battleView(
          target: target,
          fighterIds: e.fighterIds,
          defenderSupportIds: e.defenderSupportIds,
          attackerColor: attackerColor,
          defenderColor: defenderColor,
          outcome: BattleOutcome.lost,
        );
      });
      _fx.duration = const Duration(milliseconds: 825);
      await _fx.forward(from: 0);
      if (!mounted) return;
      setState(() => _hiddenIds = const {});
      _showPopup(
        target,
        'failed to annex ',
        attackerColor,
        subject: attacker?.displayName ?? 'A player',
      );
    }

    await _popupAnim.forward(from: 0);
    if (!mounted) return;
    _endBattle();
  }

  void _endBattle() {
    _pulse.stop();
    _fx.value = 0;
    setState(() {
      _battle = null;
      _colorOverrides = const {};
      _frozenTroops = const {};
      _hiddenIds = const {};
      _popup = null;
    });
  }

  /// Opens the build / reinforce window for [province].
  void _openDetails(Province province) {
    showDialog<void>(
      context: context,
      builder: (_) => ProvinceDetailDialog(
        gameId: widget.gameId,
        uid: _uid,
        provinceId: province.id,
        provinceName: province.name,
        neighborIds: _controller.neighborsOf(province.id),
        canSee: _canSee(province.id),
        provinceStates: _provinceStates,
        players: _players,
        firestore: _firestore,
      ),
    );
  }

  /// DEBUG ONLY: Space claims the selected country for the local player.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!kDebugMode) return KeyEventResult.ignored;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }

    final provinceId = _controller.selectedProvinceId;
    if (provinceId == null) return KeyEventResult.ignored;

    _firestore
        .claimProvince(
          gameId: widget.gameId,
          provinceId: provinceId,
          uid: _uid,
          neighborIds: _controller.neighborsOf(provinceId),
        )
        .catchError((Object e) => debugPrint('Claim failed: $e'));
    return KeyEventResult.handled;
  }

  void _onPointerDown(PointerDownEvent e) => _pointerDown = e.position;

  void _onPointerUp(PointerUpEvent e) {
    final start = _pointerDown;
    _pointerDown = null;
    if (start == null) return;
    if ((e.position - start).distance <= _tapSlop) {
      // The scene holds two copies of the world: fold the tap back onto
      // the first one.
      final p = e.localPosition;
      final w = _controller.mapSize.width;
      _controller.selectAt(w > 0 ? Offset(p.dx % w, p.dy) : p);
    }
  }

  /// The floating text above the attacked territory: it rises a little, and
  /// fades in and out. Follows the territory as the map is panned/zoomed.
  Widget _popupWidget(_Popup popup) {
    final t = _popupAnim.value;
    // Draw it on the copy of the world that is closest to the camera.
    final mapWidth = _controller.mapSize.width;
    var anchorX = popup.anchor.dx;
    if (mapWidth > 0) {
      anchorX -= mapWidth * ((anchorX - _currentFocus().dx) / mapWidth).round();
    }
    final point = MatrixUtils.transformPoint(
      _transform.value,
      Offset(anchorX, popup.anchor.dy),
    );
    final rise = 10 + 26 * Curves.easeOut.transform(t.clamp(0.0, 1.0).toDouble());
    final opacity = t < 0.12
        ? t / 0.12
        : (t > 0.75 ? (1 - (t - 0.75) / 0.25) : 1.0);
    final scale = 0.85 + 0.15 * Curves.easeOutBack.transform(min(1.0, t / 0.15));

    return Stack(
      children: [
        Positioned(
          left: point.dx,
          top: point.dy - rise,
          child: FractionalTranslation(
            translation: const Offset(-0.5, -1),
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0).toDouble(),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ConqueraSpace.md,
                    vertical: ConqueraSpace.sm,
                  ),
                  decoration: BoxDecoration(
                    color: ConqueraColors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ConqueraColors.divider),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text.rich(
                    TextSpan(
                      style: ConqueraText.name,
                      children: [
                        if (popup.subject != null)
                          TextSpan(text: '${popup.subject} '),
                        TextSpan(text: popup.lead),
                        TextSpan(
                          text: popup.name,
                          style: TextStyle(color: popup.nameColor),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Opens the war log (attacks you did or faced, buildings built and
  /// destroyed).
  void _openUpdates() {
    setState(() => _sidebarOpen = false);
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        // Swipes in from the left edge, to the right, like the menu it
        // came from.
        transitionsBuilder: (context, animation, secondary, child) =>
            SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            ),
          ),
          child: child,
        ),
        pageBuilder: (_, __, ___) => UpdatesScreen(
          gameId: widget.gameId,
          uid: _uid,
          firestore: _firestore,
          provinceNames: {
            for (final p in _controller.provinces) p.id: p.name,
          },
          players: _players,
        ),
      ),
    );
  }

  /// Whether the left menu is open (the world blurs behind it).
  bool _sidebarOpen = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Scaffold(
            appBar: PlayerTopBar(
              gameId: widget.gameId,
              uid: _uid,
              onMenuPressed: () => setState(() => _sidebarOpen = true),
            ),
            body: ListenableBuilder(
              listenable: Listenable.merge([_controller, _provinceStates, _players]),
              builder: (context, _) {
                if (_controller.loadError != null) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(ConqueraSpace.lg),
                      child: Text(
                        'The map could not be loaded.\n${_controller.loadError}',
                        textAlign: TextAlign.center,
                        style: ConqueraText.value,
                      ),
                    ),
                  );
                }
                if (!_controller.isLoaded) {
                  return const Center(child: CircularProgressIndicator());
                }

                final selected = _controller.selectedProvince;
                final selectedState =
                    selected == null ? null : _provinceStates.value[selected.id];
                final selectedOwner = _players.value[selectedState?.ownerId];

                // Another player's province gets an Attack button; it only works
                // if one of the player's own provinces borders it.
                final selectedOwnerId = selectedState?.ownerId;
                final isEnemy = selected != null &&
                    selectedOwnerId != null &&
                    selectedOwnerId != _uid;
                final isUnclaimed = selected != null && selectedOwnerId == null;

                // Attacking and claiming both need a bordering province of ours.
                final canAttack = selected != null &&
                    (isEnemy || isUnclaimed) &&
                    _myBorderingIds(selected).isNotEmpty;
                final canSplit = selected == null ||
                    !canAttack ||
                    _canSplitPower(selected, claim: isUnclaimed);
                final attackReadyAt = _players.value[_uid]?.attackReadyAt;

                return Stack(
                  children: [
                    Positioned.fill(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final viewport = constraints.biggest;
                          _viewport = viewport;
                          _configureCamera(viewport);
                          if (_fittedFor != viewport) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _fitToViewport(viewport);
                            });
                          }

                          // Can't zoom out past "Africa fills the screen".
                          final minScale = _minScaleFor(viewport);
                          final maxScale = max(_maxScale, minScale * 14);
                          final powerMinScale = minScale * _powerZoomFactor;

                          // Two copies of the world side by side, so the
                          // view can scroll past the right edge onto the
                          // left edge of the map again.
                          final mapSize = _controller.mapSize;
                          final sceneSize =
                              Size(mapSize.width * 2, mapSize.height);

                          return MapViewport(
                            controller: _transform,
                            contentSize: sceneSize,
                            minScale: minScale,
                            maxScale: maxScale,
                            onInteractionStart: () => _cam.stop(canceled: false),
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: _onPointerDown,
                              onPointerUp: _onPointerUp,
                              child: SizedBox(
                                width: sceneSize.width,
                                height: sceneSize.height,
                                child: Stack(
                                  children: [
                                    RepaintBoundary(
                                      child: CustomPaint(
                                        size: sceneSize,
                                        painter: MapPainter(
                                          provinces: _controller.provinces,
                                          ownerFillColors: _ownerFillColors(),
                                          hiddenIds: _hiddenIds,
                                          wrapWidth: mapSize.width,
                                        ),
                                      ),
                                    ),
                                    if (_battle != null)
                                      IgnorePointer(
                                        child: RepaintBoundary(
                                          child: CustomPaint(
                                            size: sceneSize,
                                            painter: BattlePainter(
                                              view: _battle!,
                                              pulse: _pulse,
                                              fx: _fx,
                                              transform: _transform,
                                              wrapWidth: mapSize.width,
                                            ),
                                          ),
                                        ),
                                      ),
                                    IgnorePointer(
                                      child: RepaintBoundary(
                                        child: CustomPaint(
                                          size: sceneSize,
                                          painter: BadgePainter(
                                            badges: _badges(),
                                            transform: _transform,
                                            powerMinScale: powerMinScale,
                                            iconSize: _iconPxAtMinZoom / minScale,
                                            powerSize:
                                                _powerPxAtPowerZoom / powerMinScale,
                                            wrapWidth: mapSize.width,
                                          ),
                                        ),
                                      ),
                                    ),
                                    IgnorePointer(
                                      child: RepaintBoundary(
                                        child: AnimatedBuilder(
                                          animation: _transform,
                                          builder: (context, _) => CustomPaint(
                                            size: sceneSize,
                                            painter: SelectionPainter(
                                              path: selected?.path,
                                              scale: _transform.value
                                                  .getMaxScaleOnAxis(),
                                              wrapWidth: mapSize.width,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (_popup != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: Listenable.merge([_popupAnim, _transform]),
                            builder: (context, _) => _popupWidget(_popup!),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: AnimatedSize(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: selected == null
                            ? const SizedBox(width: double.infinity)
                            : CountryInfoPanel(
                                name: selected.name,
                                ownerName: selectedOwner?.displayName ??
                                    (selectedState?.ownerId != null
                                        ? 'Unknown player'
                                        : null),
                                ownerColor: selectedOwner?.color,
                                power: _canSee(selected.id)
                                    ? '${(selectedState?.troops ?? 0).floor()}'
                                    : '?',
                                building: _canSee(selected.id)
                                    ? (selectedState?.buildingLabel ?? 'None')
                                    : '?',
                                onClose: _controller.clearSelection,
                                onOpenDetails: () => _openDetails(selected),
                                isEnemy: isEnemy,
                                isUnclaimed: isUnclaimed,
                                canAttack: canAttack,
                                canSplit: canSplit,
                                attackReadyAt: attackReadyAt,
                                onAttack: () => _openAttack(selected),
                                onClaim: () => _claim(selected),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          WorldSidebar(
            open: _sidebarOpen,
            worldId: widget.gameId,
            onClose: () => setState(() => _sidebarOpen = false),
            players: _players,
            provinces: _provinceStates,
            myUid: _uid,
            onOpenUpdates: _openUpdates,
          ),
        ],
      ),
    );
  }
}

/// Text floating above an attacked territory: [lead] in ink, then the
/// territory [name] in the attacker's color.
class _Popup {
  final Offset anchor;

  /// The player named first ("Alex annexed Peru"). Null = no subject.
  final String? subject;
  final String lead;
  final String name;
  final Color nameColor;

  const _Popup({
    required this.anchor,
    this.subject,
    required this.lead,
    required this.name,
    required this.nameColor,
  });
}