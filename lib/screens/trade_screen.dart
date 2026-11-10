import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

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
import '../widgets/conquera_text_field.dart';
import '../widgets/gold_amount.dart';
import '../widgets/player_tag.dart';
import '../widgets/stat_block.dart';

// ───────────────────────── helpers ─────────────────────────

Color _hex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x457B9D;
  return Color(0xFF000000 | v);
}

String _span(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m' : '${m < 1 ? 1 : m}m';
}

String _left(Duration d) => '${_span(d)} left';

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

/// Same fill the build window uses for its fields and cards.
Color get _fieldFill => ConqueraColors.dark
    ? ConqueraColors.ink.withAlpha(18)
    : Colors.white.withAlpha(170);

Color get _faintLine => ConqueraColors.divider.withAlpha(90);

/// The shared hollow button with a different outline color (Destroy,
/// Accept...). Everything else comes from the app theme.
ButtonStyle _tinted(Color c, {double height = 36}) => ButtonStyle(
      minimumSize: MaterialStatePropertyAll(Size(0, height)),
      foregroundColor: MaterialStateProperty.resolveWith(
        (s) => s.contains(MaterialState.disabled)
            ? ConqueraColors.muted.withAlpha(150)
            : c,
      ),
      side: MaterialStateProperty.resolveWith(
        (s) => BorderSide(
          color: s.contains(MaterialState.disabled)
              ? ConqueraColors.divider
              : c,
        ),
      ),
    );

/// Most gold you can ask the other player for in one offer.
const int _getGoldCap = 10000;

/// Gold is typed and shown with thousands separators.
int _parseGold(String s) => int.tryParse(s.replaceAll(',', '')) ?? 0;

/// Step size that grows with the amount, so +/- stays useful from 5 gold to
/// 5 million.
int _tier(int v) => v < 100
    ? 1
    : v < 1000
        ? 10
        : v < 10000
            ? 100
            : v < 100000
                ? 1000
                : 10000;

int _snap(int v) {
  final t = _tier(v);
  return ((v + t ~/ 2) ~/ t) * t;
}

// ───────────────────────── small building blocks ─────────────────────────

/// The window itself: same shell as the build window.
class _Shell extends StatelessWidget {
  final Widget child;

  const _Shell({required this.child});

  @override
  Widget build(BuildContext context) {
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
        child: child,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final VoidCallback onClose;

  const _Header({required this.title, required this.onClose, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBack != null)
          IconButton(
            onPressed: onBack,
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back, size: 20),
            color: ConqueraColors.ink,
            visualDensity: VisualDensity.compact,
          ),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.title,
          ),
        ),
        IconButton(
          onPressed: onClose,
          tooltip: 'Close',
          icon: const Icon(Icons.close, size: 20),
          color: ConqueraColors.muted,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: ConqueraText.label.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
      ),
    );
  }
}

/// Divider with the build window's spacing around it.
List<Widget> _rule() => [
      const SizedBox(height: ConqueraSpace.lg),
      Divider(height: 1, color: ConqueraColors.divider),
      const SizedBox(height: ConqueraSpace.lg),
    ];

/// Info text on the left, action button(s) on the right.
class _ActionRow extends StatelessWidget {
  final String info;
  final Color? infoColor;
  final Widget button;

  const _ActionRow({required this.info, required this.button, this.infoColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            info,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.label.copyWith(
              color: infoColor ?? ConqueraColors.muted,
            ),
          ),
        ),
        const SizedBox(width: ConqueraSpace.sm),
        button,
      ],
    );
  }
}

/// Coin + amount with thousands separators.
class _Gold extends StatelessWidget {
  final int amount;
  final TextStyle? style;
  final double iconSize;

  const _Gold(this.amount, {this.style, this.iconSize = 15});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GoldIcon(size: iconSize),
        const SizedBox(width: 4),
        Text(_n(amount), style: style ?? ConqueraText.value),
      ],
    );
  }
}

/// Your gold, ticking live.
class _LiveGold extends StatefulWidget {
  final ValueListenable<Map<String, PlayerState>> players;
  final String uid;

  const _LiveGold({required this.players, required this.uid});

  @override
  State<_LiveGold> createState() => _LiveGoldState();
}

class _LiveGoldState extends State<_LiveGold> {
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
    return _Gold(
      gold.floor(),
      style: ConqueraText.value.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// Small squarish outlined (icon or label) button beside the slider.
class _StepButton extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;

  const _StepButton({this.icon, this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final c = on ? ConqueraColors.ink : ConqueraColors.muted.withAlpha(150);
    final border = on ? ConqueraColors.ink : ConqueraColors.divider;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 30,
        constraints: const BoxConstraints(minWidth: 30),
        padding: EdgeInsets.symmetric(horizontal: label != null ? 10 : 0),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
        ),
        child: icon != null
            ? Icon(icon, size: 16, color: c)
            : Text(
                label!,
                style: ConqueraText.label.copyWith(
                  color: c,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.8,
                ),
              ),
      ),
    );
  }
}

/// Round slider thumb, same as the reinforce slider.
class _GameThumb extends SliderComponentShape {
  final Color color;

  const _GameThumb({required this.color});

  static const double _r = 11;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(_r);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final grow = 1 + 0.12 * activationAnimation.value;
    final r = _r * grow;

    canvas.drawCircle(
      center.translate(0, 1.5),
      r,
      Paint()
        ..color = Colors.black.withAlpha(50)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, r, Paint()..color = Colors.white);
    canvas.drawCircle(
      center,
      r - 1.5,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(center, 3, Paint()..color = color);
  }
}

/// Keeps a gold field to digits (max 8) with thousands separators.
class _CommaFormatter extends TextInputFormatter {
  const _CommaFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > 8) digits = digits.substring(0, 8);
    digits = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final text = digits.isEmpty ? '' : _n(int.parse(digits));
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// The reinforce-style card for gold: a typed amount, a slider, - / + / MAX.
/// The slider is not linear (fine control for small sums, still reaches
/// millions); the field accepts an exact amount.
class _GoldSlider extends StatefulWidget {
  final int value;
  final int max;
  final String caption;
  final ValueChanged<int> onChanged;

  const _GoldSlider({
    required this.value,
    required this.max,
    required this.caption,
    required this.onChanged,
  });

  @override
  State<_GoldSlider> createState() => _GoldSliderState();
}

class _GoldSliderState extends State<_GoldSlider> {
  late final TextEditingController _c =
      TextEditingController(text: _fmt(widget.value));

  static String _fmt(int v) => v <= 0 ? '' : _n(v);

  @override
  void didUpdateWidget(covariant _GoldSlider old) {
    super.didUpdateWidget(old);
    // Slider / buttons moved the value: show it. Typing already matches, so
    // the cursor is left alone.
    if (_parseGold(_c.text) != widget.value) {
      final t = _fmt(widget.value);
      _c.value = TextEditingValue(
        text: t,
        selection: TextSelection.collapsed(offset: t.length),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  int get _max => widget.max;

  void _set(int v) => widget.onChanged(v.clamp(0, _max).toInt());

  double _toSlider(int v) {
    if (_max < 1) return 0;
    return math.pow((v / _max).clamp(0.0, 1.0), 1 / 3).toDouble();
  }

  int _fromSlider(double f) {
    if (f >= 0.995) return _max;
    final raw = (_max * f * f * f).round();
    return math.min(_snap(raw), _max);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _max >= 1;
    final accent = enabled ? ConqueraColors.ink : ConqueraColors.muted.withAlpha(120);
    final value = widget.value.clamp(0, math.max(_max, 0)).toInt();

    final readout = ConqueraText.figure.copyWith(fontSize: 26, color: accent);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      decoration: BoxDecoration(
        color: enabled ? _fieldFill : _fieldFill.withAlpha(60),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: enabled
              ? ConqueraColors.ink.withAlpha(150)
              : ConqueraColors.divider,
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              GoldIcon(size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _c,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: const [_CommaFormatter()],
                  cursorColor: ConqueraColors.ink,
                  style: readout,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '0',
                    hintStyle: readout.copyWith(
                      color: ConqueraColors.muted.withAlpha(120),
                    ),
                  ),
                  onChanged: (t) => _set(math.min(_parseGold(t), _max)),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConqueraText.label,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              _StepButton(
                icon: Icons.remove,
                onTap: enabled && value > 0
                    ? () => _set(value - _tier(math.max(value - 1, 1)))
                    : null,
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 8,
                    activeTrackColor: accent,
                    inactiveTrackColor: ConqueraColors.divider.withAlpha(110),
                    disabledActiveTrackColor: accent,
                    disabledInactiveTrackColor:
                        ConqueraColors.divider.withAlpha(70),
                    overlayColor: ConqueraColors.ink.withAlpha(36),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 20),
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                    thumbShape: _GameThumb(color: accent),
                    trackShape: const RoundedRectSliderTrackShape(),
                  ),
                  child: Slider(
                    value: _toSlider(value),
                    min: 0,
                    max: 1,
                    onChanged: enabled ? (f) => _set(_fromSlider(f)) : null,
                  ),
                ),
              ),
              _StepButton(
                icon: Icons.add,
                onTap: enabled && value < _max
                    ? () => _set(value + _tier(value))
                    : null,
              ),
              const SizedBox(width: 6),
              _StepButton(
                label: 'MAX',
                onTap: enabled && value < _max ? () => _set(_max) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same look as the build window's "Select building" field.
class _PickerField extends StatelessWidget {
  final String hint;
  final String? label;
  final VoidCallback? onTap;

  const _PickerField({
    required this.hint,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chosen = label != null;
    return Material(
      color: onTap == null ? _fieldFill.withAlpha(70) : _fieldFill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: ConqueraColors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  chosen ? label! : hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: chosen
                      ? ConqueraText.value
                      : ConqueraText.value.copyWith(
                          color: ConqueraColors.muted,
                        ),
                ),
              ),
              Icon(Icons.expand_more, color: ConqueraColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Square slot (like the building icon slot): direction arrow + how many
/// territories are in this side of the trade.
class _DirSlot extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int count;

  const _DirSlot({
    required this.icon,
    required this.color,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: _fieldFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(height: 2),
          Text(
            '$count',
            style: ConqueraText.label.copyWith(
              fontWeight: FontWeight.w600,
              color: ConqueraColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// A picked territory, with an x to remove it.
class _Chip extends StatelessWidget {
  final String text;
  final VoidCallback onRemove;

  const _Chip({required this.text, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        color: _fieldFill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ConqueraColors.divider),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ConqueraText.value.copyWith(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(Icons.close, size: 14, color: ConqueraColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Received | Sent switch, in the hollow-button look.
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? ConqueraColors.ink.withAlpha(14) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? ConqueraColors.ink : ConqueraColors.divider,
            ),
          ),
          child: Text(
            label,
            style: ConqueraText.value.copyWith(
              fontSize: 14,
              color: selected ? ConqueraColors.ink : ConqueraColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── window ─────────────────────────

enum _View { home, build, offer }

/// Private trades with other players, in one window that matches the build
/// window. Three views live inside it: the offer lists, the "new trade"
/// builder, and a single offer in detail.
///
/// Open it with [TradeScreen.show].
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

  static Future<void> show(
    BuildContext context, {
    required String gameId,
    required String? myUid,
    required ValueListenable<Map<String, PlayerState>> players,
    required ValueListenable<Map<String, ProvinceState>> provinces,
    required Map<String, String> provinceNames,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => TradeScreen(
        gameId: gameId,
        myUid: myUid,
        players: players,
        provinces: provinces,
        provinceNames: provinceNames,
      ),
    );
  }

  @override
  State<TradeScreen> createState() => _TradeScreenState();
}

class _TradeScreenState extends State<TradeScreen> {
  final TradeService _service = TradeService();
  final FirestoreService _game = FirestoreService();
  StreamSubscription<List<TradeOffer>>? _sub;
  Timer? _tick;
  List<TradeOffer> _offers = const [];

  _View _view = _View.home;
  String? _offerId;
  bool _sentTab = false;
  bool _busy = false;
  String? _message;
  bool _isError = false;

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

  void _go(_View v, {String? offerId}) {
    setState(() {
      _view = v;
      _offerId = offerId;
      _message = null;
    });
  }

  void _close() => Navigator.of(context).pop();

  Future<void> _run(Future<void> Function() job, String done) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await job();
      if (mounted) {
        setState(() {
          _message = done;
          _isError = false;
        });
      }
    } on GameActionException catch (e) {
      if (mounted) {
        setState(() {
          _message = e.message;
          _isError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'Something went wrong. Try again.';
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  TradeOffer? _find(String? id) {
    if (id == null) return null;
    for (final o in _offers) {
      if (o.id == id) return o;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final uid = widget.myUid;
    if (uid == null) {
      return _Shell(
        child: Padding(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(title: 'Trade', onClose: _close),
              const SizedBox(height: ConqueraSpace.sm),
              Text('Join the world to trade.', style: ConqueraText.label),
              const SizedBox(height: ConqueraSpace.sm),
            ],
          ),
        ),
      );
    }

    switch (_view) {
      case _View.build:
        return _Shell(
          child: _Builder(
            gameId: widget.gameId,
            myUid: uid,
            service: _service,
            players: widget.players,
            provinces: widget.provinces,
            provinceNames: widget.provinceNames,
            onBack: () => _go(_View.home),
            onClose: _close,
            onSent: () {
              setState(() {
                _view = _View.home;
                _sentTab = true;
                _message = 'Offer sent.';
                _isError = false;
              });
            },
          ),
        );
      case _View.offer:
        final offer = _find(_offerId);
        if (offer == null) {
          // Accepted, declined or removed meanwhile: back to the list.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _view == _View.offer && _find(_offerId) == null) {
              setState(() => _view = _View.home);
            }
          });
          return _Shell(child: _homeListener(uid));
        }
        return _Shell(
          child: _OfferView(
            offer: offer,
            uid: uid,
            players: widget.players,
            provinces: widget.provinces,
            provinceNames: widget.provinceNames,
            onBack: () => _go(_View.home),
            onClose: _close,
            onAccept: () {
              setState(() {
                _view = _View.home;
                _message = null;
              });
              _run(
                () => _service.acceptOffer(
                  gameId: widget.gameId,
                  uid: uid,
                  offerId: offer.id,
                ),
                'Trade completed.',
              );
            },
            onRemove: () {
              final mine = offer.fromId == uid;
              setState(() {
                _view = _View.home;
                _message = null;
              });
              _run(
                () => _service.removeOffer(
                  gameId: widget.gameId,
                  uid: uid,
                  offerId: offer.id,
                ),
                mine ? 'Offer cancelled.' : 'Offer declined.',
              );
            },
            onDestroy: (provinceId) => _game.destroyBuilding(
              gameId: widget.gameId,
              provinceId: provinceId,
              uid: uid,
            ),
          ),
        );
      case _View.home:
        return _Shell(child: _homeListener(uid));
    }
  }

  Widget _homeListener(String uid) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.provinces, widget.players]),
      builder: (context, _) => _home(uid),
    );
  }

  // ───────────── home: stats, offer lists, "New trade" ─────────────

  Widget _home(String uid) {
    final provs = widget.provinces.value;
    final players = widget.players.value;
    final now = ServerClock.now();
    final received = _offers.where((o) => o.toId == uid).toList();
    final sent = _offers.where((o) => o.fromId == uid).toList();
    int live(List<TradeOffer> l) => l
        .where((o) => TradeService.problem(o, provs, players, now) == null)
        .length;
    final rows = _sentTab ? sent : received;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(ConqueraSpace.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(title: 'Trade', onClose: _close),
          const SizedBox(height: ConqueraSpace.sm),
          Wrap(
            spacing: ConqueraSpace.xl,
            runSpacing: ConqueraSpace.md,
            children: [
              StatBlock(
                label: 'Your gold',
                child: _LiveGold(players: widget.players, uid: uid),
              ),
              StatBlock(
                label: 'Received',
                child: Text('${live(received)}', style: ConqueraText.value),
              ),
              StatBlock(
                label: 'Sent',
                child: Text('${live(sent)}', style: ConqueraText.value),
              ),
            ],
          ),
          ..._rule(),
          const _SectionTitle('Offers'),
          const SizedBox(height: ConqueraSpace.sm),
          Row(
            children: [
              _TabButton(
                label: 'Received',
                selected: !_sentTab,
                onTap: () => setState(() => _sentTab = false),
              ),
              const SizedBox(width: ConqueraSpace.sm),
              _TabButton(
                label: 'Sent',
                selected: _sentTab,
                onTap: () => setState(() => _sentTab = true),
              ),
            ],
          ),
          const SizedBox(height: ConqueraSpace.sm),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  _sentTab ? 'Nothing sent' : 'No offers',
                  textAlign: TextAlign.center,
                  style: ConqueraText.label,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 330),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: rows.length,
                separatorBuilder: (_, __) =>
                    Divider(height: 1, color: _faintLine),
                itemBuilder: (_, i) => _row(rows[i], uid, provs, players, now),
              ),
            ),
          ..._rule(),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : () => _go(_View.build),
              child: const Text('New trade'),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: ConqueraSpace.md),
              child: Text(
                _message!,
                style: ConqueraText.label.copyWith(
                  color: _isError ? ConqueraColors.danger : ConqueraColors.ink,
                ),
              ),
            ),
        ],
      ),
    );
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
      child: InkWell(
        onTap: () => _go(_View.offer, offerId: o.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
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
                        style: ConqueraText.value.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    status,
                    style: ConqueraText.label.copyWith(color: statusColor),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: ConqueraColors.muted,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Line(
                icon: Icons.north_east,
                color: ConqueraColors.danger,
                label: 'You give',
                text: _summary(giveIds, giveGold, _name),
              ),
              const SizedBox(height: 4),
              _Line(
                icon: Icons.south_west,
                color: ConqueraColors.success,
                label: 'You get',
                text: _summary(getIds, getGold, _name),
              ),
              if (toClear > 0) ...[
                const SizedBox(height: 6),
                Text(
                  toClear == 1
                      ? 'Destroy 1 building to accept'
                      : 'Destroy $toClear buildings to accept',
                  style: ConqueraText.label.copyWith(
                    color: ConqueraColors.brass,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
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
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        SizedBox(width: 56, child: Text(label, style: ConqueraText.label)),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ConqueraText.value.copyWith(fontSize: 14),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── offer in detail ─────────────────────────

/// An offer in detail, with accept / decline / cancel. The receiver also
/// sees which of THEIR territories have a building and can destroy it here.
class _OfferView extends StatefulWidget {
  final TradeOffer offer;
  final String uid;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback onAccept;
  final VoidCallback onRemove;
  final Future<void> Function(String provinceId) onDestroy;

  const _OfferView({
    required this.offer,
    required this.uid,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.onBack,
    required this.onClose,
    required this.onAccept,
    required this.onRemove,
    required this.onDestroy,
  });

  @override
  State<_OfferView> createState() => _OfferViewState();
}

class _OfferViewState extends State<_OfferView> {
  bool _working = false;
  String? _error;

  String _name(String id) => widget.provinceNames[id] ?? id;

  Future<void> _destroy(String id, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ConqueraColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: ConqueraColors.divider),
        ),
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
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: _tinted(ConqueraColors.danger),
            child: const Text('Destroy'),
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

  Widget _terr(
    String id, {
    ProvinceState? building,
    bool canDestroy = false,
  }) {
    final has = building != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Icons.flag_outlined, size: 16, color: ConqueraColors.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name(id),
                  style: ConqueraText.value.copyWith(fontSize: 16),
                ),
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
              onPressed:
                  _working ? null : () => _destroy(id, building!.buildingLabel),
              style: _tinted(ConqueraColors.danger, height: 30),
              child: const Text('Destroy'),
            ),
        ],
      ),
    );
  }

  Widget _side({
    required String title,
    required IconData icon,
    required Color tint,
    required List<String> ids,
    required int gold,
    required Widget Function(String id) terr,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: tint),
            const SizedBox(width: 6),
            _SectionTitle(title),
          ],
        ),
        const SizedBox(height: ConqueraSpace.sm),
        for (final id in ids) terr(id),
        if (gold > 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _Gold(gold, style: ConqueraText.figure, iconSize: 18),
          ),
        if (ids.isEmpty && gold <= 0)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('Nothing', style: ConqueraText.label),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final uid = widget.uid;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.players, widget.provinces]),
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
              note = '';
            }
        }
        final bad = problem != null || short;
        final warn = !bad && toClear.isNotEmpty;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(
                title: mine ? 'Your offer' : 'Offer',
                onBack: widget.onBack,
                onClose: widget.onClose,
              ),
              const SizedBox(height: ConqueraSpace.sm),
              Wrap(
                spacing: ConqueraSpace.xl,
                runSpacing: ConqueraSpace.md,
                children: [
                  StatBlock(
                    label: 'From',
                    child: PlayerTag(
                      name: offer.fromName,
                      color: _hex(offer.fromColor),
                      style: ConqueraText.value,
                    ),
                  ),
                  StatBlock(
                    label: 'To',
                    child: PlayerTag(
                      name: offer.toName,
                      color: _hex(offer.toColor),
                      style: ConqueraText.value,
                    ),
                  ),
                  StatBlock(
                    label: 'Expires in',
                    child: Text(
                      problem == TradeProblem.expired
                          ? 'Expired'
                          : _span(offer.timeLeft(now)),
                      style: ConqueraText.value.copyWith(
                        color: problem == TradeProblem.expired
                            ? ConqueraColors.danger
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
              ..._rule(),
              _side(
                title: 'You give',
                icon: Icons.north_east,
                tint: ConqueraColors.danger,
                ids: giveIds,
                gold: giveGold,
                terr: (id) => _terr(
                  id,
                  building: toClear.contains(id) ? provs[id] : null,
                  canDestroy: canDestroy,
                ),
              ),
              ..._rule(),
              _side(
                title: 'You get',
                icon: Icons.south_west,
                tint: ConqueraColors.success,
                ids: getIds,
                gold: getGold,
                terr: (id) => _terr(id),
              ),
              if ((_error ?? note).isNotEmpty) ...[
                const SizedBox(height: ConqueraSpace.md),
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
              ],
              const SizedBox(height: ConqueraSpace.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: _working ? null : widget.onRemove,
                    child: Text(
                      mine
                          ? (problem == null ? 'Cancel offer' : 'Remove')
                          : (problem == null ? 'Decline' : 'Remove'),
                    ),
                  ),
                  if (!mine) ...[
                    const SizedBox(width: ConqueraSpace.sm),
                    OutlinedButton(
                      onPressed:
                          (bad || warn || _working) ? null : widget.onAccept,
                      style: _tinted(ConqueraColors.success),
                      child: const Text('Accept'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── new trade ─────────────────────────

class _Opt {
  final String id;
  final String name;

  /// Greyed out and not selectable (your own territory with a building).
  final bool locked;
  const _Opt(this.id, this.name, {this.locked = false});
}

class _Cand {
  final PlayerState player;
  final int rank;
  final int count;
  const _Cand(this.player, this.rank, this.count);
}

/// The whole "new trade" flow in one view: who, what you give, what you
/// get, send.
class _Builder extends StatefulWidget {
  final String gameId;
  final String myUid;
  final TradeService service;
  final ValueListenable<Map<String, PlayerState>> players;
  final ValueListenable<Map<String, ProvinceState>> provinces;
  final Map<String, String> provinceNames;
  final VoidCallback onBack;
  final VoidCallback onClose;
  final VoidCallback onSent;

  const _Builder({
    required this.gameId,
    required this.myUid,
    required this.service,
    required this.players,
    required this.provinces,
    required this.provinceNames,
    required this.onBack,
    required this.onClose,
    required this.onSent,
  });

  @override
  State<_Builder> createState() => _BuilderState();
}

class _BuilderState extends State<_Builder> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _give = {};
  final Set<String> _get = {};
  int _giveGold = 0;
  int _getGold = 0;
  String? _partnerId;
  String _playerQuery = '';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _name(String id) => widget.provinceNames[id] ?? id;

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

  /// Other players that still own land, ranked like the leaderboard
  /// (total power, then name).
  List<_Cand> _candidates() {
    final power = <String, int>{};
    final count = <String, int>{};
    widget.provinces.value.forEach((id, s) {
      final o = s.ownerId;
      if (o == null) return;
      power[o] = (power[o] ?? 0) + s.troops.floor();
      count[o] = (count[o] ?? 0) + 1;
    });
    final ranked = widget.players.value.values.toList()
      ..sort((a, b) {
        final d = (power[b.uid] ?? 0).compareTo(power[a.uid] ?? 0);
        return d != 0 ? d : a.displayName.compareTo(b.displayName);
      });
    final out = <_Cand>[];
    for (var i = 0; i < ranked.length; i++) {
      final p = ranked[i];
      final c = count[p.uid] ?? 0;
      if (p.uid == widget.myUid || c == 0) continue;
      out.add(_Cand(p, i + 1, c));
    }
    return out;
  }

  void _pickPartner(PlayerState p) {
    setState(() {
      if (_partnerId != p.uid) {
        _get.clear();
        _getGold = 0;
      }
      _partnerId = p.uid;
      _error = null;
    });
  }

  int _myGoldNow() =>
      (widget.players.value[widget.myUid]?.goldAt(ServerClock.now()) ?? 0)
          .floor();

  /// Why the offer can't be sent yet (null = ready).
  String? get _problem {
    final partner = _partner;
    if (partner == null) return 'Choose who to trade with.';
    if (_give.isEmpty && _get.isEmpty && _giveGold == 0 && _getGold == 0) {
      return 'Add something to the trade.';
    }
    if (_giveGold > TradeService.maxGold || _getGold > TradeService.maxGold) {
      return 'Gold is limited to ${_n(TradeService.maxGold)}.';
    }
    final mine = _myGoldNow();
    if (_giveGold > mine) return 'You only have ${_n(mine)} gold.';
    if (_owned(widget.myUid) - _give.length + _get.length < 1) {
      return 'Keep at least one territory.';
    }
    if (_owned(partner.uid) - _get.length + _give.length < 1) {
      return '${partner.displayName} must keep at least one territory.';
    }
    return null;
  }

  bool get _touched =>
      _give.isNotEmpty || _get.isNotEmpty || _giveGold > 0 || _getGold > 0;

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
        giveGold: _giveGold,
        takeProvinces: _get.toList(),
        takeGold: _getGold,
      );
      if (mounted) widget.onSent();
    } on GameActionException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTerritories({
    required String title,
    required List<_Opt> options,
    required Set<String> target,
  }) async {
    final res = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _TerritoryPicker(
        title: title,
        options: options,
        initial: {...target},
      ),
    );
    if (res == null || !mounted) return;
    setState(() {
      target
        ..clear()
        ..addAll(res);
      _error = null;
    });
  }

  // ───────────── who to trade with (leaderboard-style rows) ─────────────

  Widget _playerRow(_Cand c, {required bool selected, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? ConqueraColors.ink.withAlpha(14) : null,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${c.rank}',
                style: ConqueraText.label.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Expanded(
              child: PlayerTag(
                name: c.player.displayName,
                color: c.player.color,
                style: ConqueraText.value.copyWith(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: ConqueraSpace.sm),
            Text(
              c.count == 1 ? '1 territory' : '${c.count} territories',
              style: ConqueraText.value.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _partnerSection(List<_Cand> all) {
    if (all.isEmpty) {
      return [Text('No other players yet.', style: ConqueraText.label)];
    }

    final partner = _partner;
    if (partner != null) {
      final chosen = all.where((c) => c.player.uid == partner.uid);
      if (chosen.isNotEmpty) {
        return [
          Row(
            children: [
              Expanded(child: _playerRow(chosen.first, selected: true)),
              const SizedBox(width: ConqueraSpace.sm),
              OutlinedButton(
                onPressed: () => setState(() {
                  _partnerId = null;
                  _search.clear();
                  _playerQuery = '';
                }),
                style: _tinted(ConqueraColors.ink, height: 30),
                child: const Text('Change'),
              ),
            ],
          ),
        ];
      }
    }

    final q = _playerQuery.toLowerCase();
    final shown = [
      for (final c in all)
        if (c.player.displayName.toLowerCase().contains(q)) c,
    ];
    return [
      if (all.length > 6) ...[
        ConqueraTextField(
          controller: _search,
          hint: 'Search players',
          onChanged: (v) => setState(() => _playerQuery = v),
        ),
        const SizedBox(height: ConqueraSpace.sm),
      ],
      if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('No match.', style: ConqueraText.label),
        )
      else
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: shown.length,
            itemBuilder: (_, i) => _playerRow(
              shown[i],
              selected: false,
              onTap: () => _pickPartner(shown[i].player),
            ),
          ),
        ),
    ];
  }

  // ───────────── one side of the trade ─────────────

  Widget _side({
    required String pickerTitle,
    required IconData icon,
    required Color tint,
    required Set<String> selected,
    required List<_Opt> options,
    required int gold,
    required int goldMax,
    required String caption,
    required ValueChanged<int> onGold,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DirSlot(icon: icon, color: tint, count: selected.length),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PickerField(
                    hint: 'Select territories',
                    label: selected.isEmpty
                        ? null
                        : '${selected.length} of '
                            '${TradeService.maxProvincesPerSide} selected',
                    onTap: () => _pickTerritories(
                      title: pickerTitle,
                      options: options,
                      target: selected,
                    ),
                  ),
                  if (selected.isNotEmpty) ...[
                    const SizedBox(height: ConqueraSpace.sm),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final id in selected)
                          _Chip(
                            text: _name(id),
                            onRemove: () => setState(() {
                              selected.remove(id);
                              _error = null;
                            }),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: ConqueraSpace.sm),
        _GoldSlider(
          value: gold,
          max: goldMax,
          caption: caption,
          onChanged: (v) => setState(() {
            onGold(v);
            _error = null;
          }),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.players, widget.provinces]),
      builder: (context, _) {
        final partner = _partner;
        final problem = _problem;
        final myGold = _myGoldNow();
        final shownError =
            _error ?? ((problem != null && _touched) ? problem : null);

        return SingleChildScrollView(
          padding: const EdgeInsets.all(ConqueraSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Header(
                title: 'New trade',
                onBack: widget.onBack,
                onClose: widget.onClose,
              ),
              const SizedBox(height: ConqueraSpace.sm),
              const _SectionTitle('Trade with'),
              const SizedBox(height: ConqueraSpace.sm),
              ..._partnerSection(_candidates()),
              if (partner != null) ...[
                ..._rule(),
                const _SectionTitle('You give'),
                const SizedBox(height: ConqueraSpace.sm),
                _side(
                  pickerTitle: 'You give',
                  icon: Icons.north_east,
                  tint: ConqueraColors.danger,
                  selected: _give,
                  options: _myOptions(),
                  gold: _giveGold,
                  goldMax: math.min(myGold, TradeService.maxGold),
                  caption: 'You have ${_n(myGold)}',
                  onGold: (v) => _giveGold = v,
                ),
                ..._rule(),
                const _SectionTitle('You get'),
                const SizedBox(height: ConqueraSpace.sm),
                _side(
                  pickerTitle: 'You get',
                  icon: Icons.south_west,
                  tint: ConqueraColors.success,
                  selected: _get,
                  options: _theirOptions(partner.uid),
                  gold: _getGold,
                  goldMax: _getGoldCap,
                  caption: 'Max ${_n(_getGoldCap)}',
                  onGold: (v) => _getGold = v,
                ),
                ..._rule(),
                _ActionRow(
                  info: shownError ?? '',
                  infoColor: ConqueraColors.danger,
                  button: FilledButton(
                    onPressed: (_busy || problem != null) ? null : _send,
                    child: Text(_busy ? 'Sending...' : 'Send offer'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── territory picker ─────────────────────────

/// The "Select territories" window: a searchable list, tap to tick. Returns
/// the chosen ids when Done is pressed.
class _TerritoryPicker extends StatefulWidget {
  final String title;
  final List<_Opt> options;
  final Set<String> initial;

  const _TerritoryPicker({
    required this.title,
    required this.options,
    required this.initial,
  });

  @override
  State<_TerritoryPicker> createState() => _TerritoryPickerState();
}

class _TerritoryPickerState extends State<_TerritoryPicker> {
  late final Set<String> _sel = {...widget.initial};
  final TextEditingController _q = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _toggle(_Opt o) {
    if (o.locked) return;
    setState(() {
      if (_sel.contains(o.id)) {
        _sel.remove(o.id);
      } else if (_sel.length < TradeService.maxProvincesPerSide) {
        _sel.add(o.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = [
      for (final o in widget.options)
        if (o.name.toLowerCase().contains(q)) o,
    ];

    return _Shell(
      child: Padding(
        padding: const EdgeInsets.all(ConqueraSpace.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              title: 'Select territories',
              onClose: () => Navigator.of(context).pop(),
            ),
            const SizedBox(height: ConqueraSpace.sm),
            if (widget.options.length > 8) ...[
              ConqueraTextField(
                controller: _q,
                hint: 'Search territories',
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: ConqueraSpace.sm),
            ],
            _SectionTitle(
              '${widget.title}  ·  ${_sel.length} / '
              '${TradeService.maxProvincesPerSide}',
            ),
            const SizedBox(height: ConqueraSpace.xs),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Center(
                          child: Text(
                            widget.options.isEmpty
                                ? 'No territories.'
                                : 'No match.',
                            style: ConqueraText.label,
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: shown.length,
                        itemBuilder: (_, i) {
                          final o = shown[i];
                          final on = _sel.contains(o.id);
                          return InkWell(
                            onTap: o.locked ? null : () => _toggle(o),
                            child: Opacity(
                              opacity: o.locked ? 0.45 : 1,
                              child: Container(
                                color: on
                                    ? ConqueraColors.ink.withAlpha(14)
                                    : null,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 12,
                                ),
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
                                          ? ConqueraColors.ink
                                          : ConqueraColors.muted,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        o.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ConqueraText.value.copyWith(
                                          fontSize: 16,
                                          fontWeight: on
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    if (o.locked)
                                      Text(
                                        'Has a building',
                                        style: ConqueraText.label,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: ConqueraSpace.md),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop({..._sel}),
                child: Text(_sel.isEmpty ? 'Done' : 'Done (${_sel.length})'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}