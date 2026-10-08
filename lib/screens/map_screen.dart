import 'dart:async';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/player_state.dart';
import '../models/province_state.dart';
import '../painters/map_painter.dart';
import '../services/firestore_service.dart';
import '../state/map_controller.dart';
import '../theme/conquera_theme.dart';
import '../widgets/country_info_panel.dart';
import '../widgets/player_top_bar.dart';

/// Pannable, zoomable world map. Tap a country to outline it and open its
/// info panel; tap the ocean (or the close button) to clear.
///
/// Same approach as Urbanize: [InteractiveViewer] gives smooth pan/zoom,
/// and a [Listener] (not a GestureDetector) does tap detection, because a
/// nested tap recognizer loses the gesture arena to InteractiveViewer's
/// scale recognizer. [PointerEvent.localPosition] arrives already in map
/// coordinates, so no matrix math is needed for hit-testing.
///
/// The map is two layers: a static base (all countries) and a small
/// selection overlay that redraws as the zoom changes, so the outline
/// keeps a constant on-screen thickness.
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

  // Same zoom lock as Urbanize.
  static const double _minScale = 0.5;
  static const double _maxScale = 16;
  static const double _boundaryMargin = 400;

  Size? _fittedFor; // viewport size the initial fit was computed for

  // Live game data.
  final FirestoreService _firestore = FirestoreService();
  late final String _uid = FirebaseAuth.instance.currentUser!.uid;
  StreamSubscription<Map<String, ProvinceState>>? _provincesSub;
  StreamSubscription<Map<String, PlayerState>>? _playersSub;
  Map<String, ProvinceState> _provinceStates = const {};
  Map<String, PlayerState> _players = const {};

  /// How opaque an owner's color is over the land fill (0-255).
  static const int _ownerFillAlpha = 170;

  @override
  void initState() {
    super.initState();
    _controller.loadMap(widget.assetPath);

    _provincesSub = _firestore
        .watchProvinces(gameId: FirestoreService.defaultGameId)
        .listen(
      (states) {
        if (mounted) setState(() => _provinceStates = states);
      },
      onError: (Object e) => debugPrint('Provinces stream error: $e'),
    );
    _playersSub = _firestore
        .watchPlayers(gameId: FirestoreService.defaultGameId)
        .listen(
      (players) {
        if (mounted) setState(() => _players = players);
      },
      onError: (Object e) => debugPrint('Players stream error: $e'),
    );
  }

  @override
  void dispose() {
    _provincesSub?.cancel();
    _playersSub?.cancel();
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

  /// Fits the whole map to the viewport and centers it. Runs on first
  /// layout (and again if the window size changes).
  void _fitToViewport(Size viewport) {
    final map = _controller.mapSize;
    if (map.isEmpty || viewport.isEmpty) return;

    final scale = _fitScaleFor(viewport);
    final dx = (viewport.width - map.width * scale) / 2;
    final dy = (viewport.height - map.height * scale) / 2;

    _transform.value = Matrix4.identity()
      ..translate(dx, dy)
      ..scale(scale);
    _fittedFor = viewport;
  }

  /// provinceId -> owner's color, for the map's owner fills.
  Map<String, Color> _ownerFillColors() {
    final colors = <String, Color>{};
    _provinceStates.forEach((id, state) {
      final owner = _players[state.ownerId];
      if (owner != null) colors[id] = owner.color.withAlpha(_ownerFillAlpha);
    });
    return colors;
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
        listenable: _controller,
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
              selected == null ? null : _provinceStates[selected.id];
          final selectedOwner = _players[selectedState?.ownerId];

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

                    // Urbanize's 0.5 floor, but never higher than the
                    // fit-to-screen scale (so the initial view is valid).
                    final minScale = min(_minScale, _fitScaleFor(viewport));

                    return InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      minScale: minScale,
                      maxScale: _maxScale,
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