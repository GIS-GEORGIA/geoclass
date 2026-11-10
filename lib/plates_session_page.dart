import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import 'plates.dart';
import 'session_base.dart';

/// The plates game on the teacher's screen. The teacher moves the plates; students' phones show the same one.
/// Nobody sends an answer: the class says it aloud.
class PlatesSessionPage extends SessionPageBase {
  /// Outlines already loaded, for tests; otherwise the page loads them itself.
  final List<PlateShape>? shapes;
  const PlatesSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.shapes,
  });
  @override
  State<PlatesSessionPage> createState() => _PlatesSessionPageState();
}

class _PlatesSessionPageState extends SessionPageState<PlatesSessionPage> {
  List<PlateShape>? _shapes;
  final _cache = PlateCache();
  final _focus = FocusNode();
  bool _noticeRead = false;
  // What the teacher just chose, shown before the server confirms it.
  ({int at, bool revealed})? _pending;
  int _sent = 0;

  List<PlateSpec> get _deck => PlateSpec.listFrom(session.settings);
  int get _at => _pending?.at ?? (session.settings['at'] as int? ?? 0);
  bool get _revealed => _pending?.revealed ?? (session.settings['revealed'] as bool? ?? false);

  @override
  void initState() {
    super.initState();
    _shapes = widget.shapes;
    // Opened again in the middle of the game: the class has heard the notice.
    _noticeRead = _at > 0;
    if (_shapes == null) {
      loadPlateShapes().then((shapes) {
        if (mounted) setState(() => _shapes = shapes);
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) {}
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => 0;
  @override
  int get shownCount => 0;
  @override
  String exportCsv() => [
    'number,ka,en,palette',
    for (final (i, p) in _deck.indexed)
      () {
        final shape = _shapes?.where((x) => x.id == p.shape).firstOrNull;
        return '${i + 1},"${shape?.ka ?? p.shape}","${shape?.en ?? p.shape}",${p.palette}';
      }(),
  ].join('\n');
  @override
  String exportGeoJson() => '{}';
  @override
  List<Widget> mapLayers() => const [];
  @override
  List<Widget> mapOverlays() => const [];

  Future<void> _show(int at, bool revealed) async {
    if (at < 0 || at > _deck.length) return;
    final n = ++_sent;
    setState(() => _pending = (at: at, revealed: revealed && at < _deck.length));
    await run(() async {
      final updated = await api.setPlate(session.id, at: at, revealed: revealed);
      if (mounted && n == _sent) setState(() => session = updated);
    });
    if (mounted && n == _sent) setState(() => _pending = null);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (!_noticeRead || e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown) {
      _show(_at + 1, false);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      _show(_at - 1, false);
    } else if ((k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) && _at < _deck.length) {
      _show(_at, !_revealed);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget panel() {
    final shapes = _shapes;
    if (shapes == null) return const Center(child: CircularProgressIndicator());
    final deck = _deck;
    if (!_noticeRead) {
      return platesNotice(
        context,
        (k) => s[k],
        note: s['plates_notice_teacher'],
        actions: [
          FilledButton.icon(
            onPressed: () {
              setState(() => _noticeRead = true);
              _focus.requestFocus();
            },
            icon: const Icon(Icons.check),
            label: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_agree'])),
          ),
        ],
      );
    }
    if (_at >= deck.length) {
      return platesEnd(
        context,
        (k) => s[k],
        actions: [
          FilledButton.icon(
            onPressed: () => _show(0, false),
            icon: const Icon(Icons.replay),
            label: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_again'])),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _show(deck.length - 1, false),
            child: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_back'])),
          ),
        ],
      );
    }
    final spec = deck[_at];
    final shape = shapes.where((x) => x.id == spec.shape).firstOrNull;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('${_at + 1} / ${deck.length}', style: Theme.of(context).textTheme.titleMedium),
          ),
          Expanded(
            child: PlateView(
              dots: _cache.dots(spec, shapes),
              revealed: _revealed,
              question: s['plates_question'],
              answer: shape?.label(lang) ?? '?',
              onTap: () => _show(_at, !_revealed),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(
              children: [
                IconButton.outlined(
                  tooltip: s['plates_back'],
                  onPressed: _at > 0 ? () => _show(_at - 1, false) : null,
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => _show(_at, !_revealed),
                    icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(s[_revealed ? 'plates_hide' : 'plates_reveal']),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: s['next'],
                  onPressed: () => _show(_at + 1, false),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(s['plates_keys'], style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
