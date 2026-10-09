import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/game_rules.dart';
import '../models/player_state.dart';
import '../models/province.dart';
import '../models/province_state.dart';
import '../painters/map_painter.dart';
import '../services/firestore_service.dart';
import '../state/map_controller.dart';
import '../theme/conquera_theme.dart';
import '../widgets/attack_dialog.dart';
import '../widgets/country_info_panel.dart';
import '../widgets/player_top_bar.dart';
import '../widgets/province_detail_dialog.dart';

/// Pannable, zoomable world map. Tap a country to outline it and open its
/// info panel; tap the ocean (or the close button) to clear. The panel's
/// "Manage" button opens the province window (build / reinforce).
///
/// Same approach as Urbanize: [InteractiveViewer] gives smooth pan/zoom,
/// and a [Listener] (not a GestureDetector) does tap detection, because a
/// nested tap recognizer loses the gesture arena to InteractiveViewer's
/// scale recognizer. [PointerEvent.localPosition] arrives already in map
/// coordinates, so no matrix math is needed for hit-testing.
///
/// The map is three layers: a static base (all countries), a badge layer
/// (building icons and power numbers) and a small selection overlay. Icons
/// and numbers have a fixed size on the map (they grow and shrink with it);
/// the selection outline keeps a constant on-screen thickness.
class MapScreen extends StatefulWidget {
  final String assetPath;

  const MapScreen({super.key, this.assetPath = 'assets/maps/world.svg'});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _controller = MapController();
  final TransformationController _transform = TransformationController();

  Offset? _pointerDown;
  static const double _tapSlop = 12.0; // screen pixels

  // Zoom limits. The most zoomed-out view is "Africa fills the screen", so
  // the player can never see the whole planet at once.
  static const double _maxScale = 16;
  static const double _boundaryMargin = 400;

  /// Extra room around Africa's bounding box at the zoomed-out limit.
  static const double _africaPadding = 0.04;

  /// Power numbers appear once the map is zoomed in to this many times the
  /// most zoomed-out view. Higher = you have to zoom in further.
  static const double _powerZoomFactor = 1.5;

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
  late final String _uid = FirebaseAuth.instance.currentUser!.uid;
  StreamSubscription<Map<String, ProvinceState>>? _provincesSub;
  StreamSubscription<Map<String, PlayerState>>? _playersSub;
  final ValueNotifier<Map<String, ProvinceState>> _provinceStates =
      ValueNotifier(const {});
  final ValueNotifier<Map<String, PlayerState>> _players =
      ValueNotifier(const {});

  /// How opaque an owner's color is over the land fill (0-255).
  static const int _ownerFillAlpha = 170;

  @override
  void initState() {
    super.initState();
    _controller.loadMap(widget.assetPath);

    _provincesSub = _firestore
        .watchProvinces(gameId: FirestoreService.defaultGameId)
        .listen(
      (states) => _provinceStates.value = states,
      onError: (Object e) => debugPrint('Provinces stream error: $e'),
    );
    _playersSub = _firestore
        .watchPlayers(gameId: FirestoreService.defaultGameId)
        .listen(
      (players) => _players.value = players,
      onError: (Object e) => debugPrint('Players stream error: $e'),
    );
  }

  @override
  void dispose() {
    _provincesSub?.cancel();
    _playersSub?.cancel();
    _provinceStates.dispose();
    _players.dispose();
    _controller.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Scale at which the whole map fits the viewport.
  double _fitScaleFor(Size viewport) {
    final map = _controller.mapSize;
    if (map.isEmpty || viewport.isEmpty) return 1.0;
    return min(viewport.width / map.width, viewport.height / map.height);
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

  /// The most zoomed-out scale allowed: Africa fills the viewport. Never
  /// lower than the whole-map fit.
  double _minScaleFor(Size viewport) {
    final whole = _fitScaleFor(viewport);
    final africa = _africaRect();
    if (africa == null || viewport.isEmpty) return whole;
    final africaFit = min(
      viewport.width / africa.width,
      viewport.height / africa.height,
    );
    return max(whole, africaFit);
  }

  /// Starts at the zoomed-out limit, centered on Africa. Runs on first
  /// layout (and again if the window size changes).
  void _fitToViewport(Size viewport) {
    final map = _controller.mapSize;
    if (map.isEmpty || viewport.isEmpty) return;

    final scale = _minScaleFor(viewport);
    final focus = _africaRect()?.center ?? map.center(Offset.zero);
    final dx = viewport.width / 2 - focus.dx * scale;
    final dy = viewport.height / 2 - focus.dy * scale;

    _transform.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
    _fittedFor = viewport;
  }

  /// provinceId -> owner's color, for the map's owner fills.
  Map<String, Color> _ownerFillColors() {
    final players = _players.value;
    final colors = <String, Color>{};
    _provinceStates.value.forEach((id, state) {
      final owner = players[state.ownerId];
      if (owner != null) colors[id] = owner.color.withAlpha(_ownerFillAlpha);
    });
    return colors;
  }

  /// What to draw on top of each province: its building's icon and its
  /// power. Provinces with neither get no badge.
  List<MapBadge> _badges() {
    final badges = <MapBadge>[];
    _provinceStates.value.forEach((id, state) {
      final province = _controller.provinceById(id);
      if (province == null) return;

      final icon = state.hasBuilding
          ? GameRules.buildingById(state.buildingType)?.icon
          : null;
      final power = state.troops.floor();
      if (icon == null && power <= 0) return;

      badges.add(MapBadge(anchor: province.anchor, icon: icon, power: power));
    });
    return badges;
  }

  /// Ids of the provinces the local player owns that border [target].
  Set<String> _myBorderingIds(Province target) {
    final states = _provinceStates.value;
    return {
      for (final id in _controller.neighborsOf(target.id))
        if (states[id]?.ownerId == _uid) id,
    };
  }

  /// Opens the battle window against [target].
  void _openAttack(Province target) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AttackDialog(
        gameId: FirestoreService.defaultGameId,
        uid: _uid,
        targetId: target.id,
        targetName: target.name,
        neighborIds: _controller.neighborsOf(target.id),
        provinceNames: {
          for (final p in _controller.provinces) p.id: p.name,
        },
        provinceStates: _provinceStates,
        players: _players,
        firestore: _firestore,
      ),
    );
  }

  /// Opens the build / reinforce window for [province].
  void _openDetails(Province province) {
    showDialog<void>(
      context: context,
      builder: (_) => ProvinceDetailDialog(
        gameId: FirestoreService.defaultGameId,
        uid: _uid,
        provinceId: province.id,
        provinceName: province.name,
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
          gameId: FirestoreService.defaultGameId,
          provinceId: provinceId,
          uid: _uid,
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
      _controller.selectAt(e.localPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        appBar: PlayerTopBar(
          gameId: FirestoreService.defaultGameId,
          uid: FirebaseAuth.instance.currentUser!.uid,
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
            final canAttack =
                selected != null && isEnemy && _myBorderingIds(selected).isNotEmpty;
            final attackReadyAt = _players.value[_uid]?.attackReadyAt;

            return Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final viewport = constraints.biggest;
                      if (_fittedFor != viewport) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _fitToViewport(viewport);
                        });
                      }

                      // Can't zoom out past "Africa fills the screen".
                      final minScale = _minScaleFor(viewport);
                      final maxScale = max(_maxScale, minScale * 14);
                      final powerMinScale = minScale * _powerZoomFactor;

                      return InteractiveViewer(
                        transformationController: _transform,
                        constrained: false,
                        minScale: minScale,
                        maxScale: maxScale,
                        boundaryMargin: const EdgeInsets.all(_boundaryMargin),
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _onPointerDown,
                          onPointerUp: _onPointerUp,
                          child: SizedBox(
                            width: _controller.mapSize.width,
                            height: _controller.mapSize.height,
                            child: Stack(
                              children: [
                                RepaintBoundary(
                                  child: CustomPaint(
                                    size: _controller.mapSize,
                                    painter: MapPainter(
                                      provinces: _controller.provinces,
                                      ownerFillColors: _ownerFillColors(),
                                    ),
                                  ),
                                ),
                                IgnorePointer(
                                  child: RepaintBoundary(
                                    child: CustomPaint(
                                      size: _controller.mapSize,
                                      painter: BadgePainter(
                                        badges: _badges(),
                                        transform: _transform,
                                        powerMinScale: powerMinScale,
                                        iconSize: _iconPxAtMinZoom / minScale,
                                        powerSize:
                                            _powerPxAtPowerZoom / powerMinScale,
                                      ),
                                    ),
                                  ),
                                ),
                                IgnorePointer(
                                  child: RepaintBoundary(
                                    child: AnimatedBuilder(
                                      animation: _transform,
                                      builder: (context, _) => CustomPaint(
                                        size: _controller.mapSize,
                                        painter: SelectionPainter(
                                          path: selected?.path,
                                          scale: _transform.value
                                              .getMaxScaleOnAxis(),
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
                            power: '${(selectedState?.troops ?? 0).floor()}',
                            building: selectedState?.buildingLabel ?? 'None',
                            onClose: _controller.clearSelection,
                            onOpenDetails: () => _openDetails(selected),
                            isEnemy: isEnemy,
                            canAttack: canAttack,
                            attackReadyAt: attackReadyAt,
                            onAttack: () => _openAttack(selected),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}