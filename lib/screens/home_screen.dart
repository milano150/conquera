import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/dev_session.dart';
import '../services/firestore_service.dart';
import '../theme/conquera_theme.dart';
import '../widgets/blur_route.dart';
import '../widgets/conquera_text_field.dart';
import 'join_screen.dart';
import 'map_screen.dart';

/// The first screen: the title and a box for the id of a world. Worlds are
/// created by hand in the database, so a world that doesn't exist is just
/// an error here.
///
/// A returning player (they already picked a name and color in that world)
/// goes straight to the map; a new one goes to [JoinScreen].
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _worldId = TextEditingController();
  final FirestoreService _service = FirestoreService();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _worldId.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    final worldId = _worldId.text.trim();
    if (worldId.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      // Entering from here always uses this device's own account; the beta
      // "log in as" on the join screen sets an override again if needed.
      DevSession.reset();
      final uid = DevSession.uid;

      if (!await _service.worldExists(worldId)) {
        if (mounted) setState(() => _error = 'No world with that id.');
        return;
      }

      final joined = await _service.playerExists(gameId: worldId, uid: uid);
      if (joined) {
        try {
          await _service.reconcileIncome(gameId: worldId, uid: uid);
        } catch (e) {
          debugPrint('Income reconcile failed: $e');
        }
      }
      if (!mounted) return;

      await Navigator.of(context).push(
        BlurRoute<void>(
          builder: (_) => joined
              ? MapScreen(gameId: worldId)
              : JoinScreen(gameId: worldId),
        ),
      );
    } catch (e) {
      debugPrint('Entering world failed: $e');
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ConqueraSpace.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'conquera.beta',
                    textAlign: TextAlign.center,
                    style: ConqueraText.title.copyWith(
                      fontSize: 28,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.xl),
                  ConqueraTextField(
                    controller: _worldId,
                    hint: 'enter world_id',
                    enabled: !_busy,
                    autofocus: true,
                    textInputAction: TextInputAction.go,
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    onSubmitted: (_) => _enter(),
                  ),
                  const SizedBox(height: ConqueraSpace.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _enter,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Join world'),
                    ),
                  ),
                  const SizedBox(height: ConqueraSpace.sm),
                  SizedBox(
                    height: 18,
                    child: _error == null
                        ? null
                        : Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: ConqueraText.label.copyWith(
                              color: ConqueraColors.danger,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}