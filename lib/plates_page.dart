import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';
import 'plates.dart';

const plateGroups = ['all', 'continent', 'country'];
const plateCounts = [6, 9, 12];

enum _Stage { notice, setup, plates, end }

/// Colour plates for the class screen. The class says the answers aloud: nothing is sent or stored.
class PlatesPage extends StatefulWidget {
  final S s;
  final String lang;

  /// Outlines already loaded; otherwise the page loads assets/plates.json itself.
  final List<PlateShape>? shapes;
  const PlatesPage({super.key, required this.s, required this.lang, this.shapes});
  @override
  State<PlatesPage> createState() => _PlatesPageState();
}

class _PlatesPageState extends State<PlatesPage> {
  _Stage _stage = _Stage.notice;
  List<PlateShape>? _shapes;
  String _group = 'all';
  int _count = 9;
  String _palette = 'mix';

  List<(PlateShape, PlatePalette, int)> _deck = const [];
  final _drawn = <int, List<PlateDot>>{};
  int _at = 0;
  bool _revealed = false;
  final _focus = FocusNode();

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _shapes = widget.shapes;
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

  void _start() {
    final r = Random();
    final pool = _shapes!.where((x) => _group == 'all' || x.group == _group).toList()..shuffle(r);
    setState(() {
      _deck = [
        for (final (i, shape) in pool.take(_count).indexed)
          (
            shape,
            _palette == 'mix'
                ? platePalettes[i % platePalettes.length]
                : platePalettes.firstWhere((p) => p.id == _palette),
            r.nextInt(1 << 31),
          ),
      ];
      _drawn.clear();
      _at = 0;
      _revealed = false;
      _stage = _Stage.plates;
    });
    _focus.requestFocus();
  }

  List<PlateDot> _dots(int i) => _drawn.putIfAbsent(i, () => makePlate(_deck[i].$1, _deck[i].$2, _deck[i].$3));

  void _go(int to) {
    if (to >= _deck.length) {
      setState(() => _stage = _Stage.end);
      return;
    }
    if (to < 0) return;
    setState(() {
      _at = to;
      _revealed = false;
    });
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (_stage != _Stage.plates || e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.pageDown) {
      _go(_at + 1);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.pageUp) {
      _go(_at - 1);
    } else if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      setState(() => _revealed = !_revealed);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _key,
    child: Scaffold(
      appBar: AppBar(
        title: Text(s['plates_title']),
        actions: [
          if (_stage == _Stage.plates)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${_at + 1} / ${_deck.length}', style: Theme.of(context).textTheme.titleMedium),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.notice => _notice(),
          _Stage.setup => _setup(),
          _Stage.plates => _plate(),
          _Stage.end => _end(),
        },
      ),
    ),
  );

  Widget _page(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(padding: const EdgeInsets.all(20), children: children),
    ),
  );

  Widget _notice() {
    final text = Theme.of(context).textTheme;
    return _page([
      Icon(Icons.campaign_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 8),
      Text(s['plates_notice_title'], textAlign: TextAlign.center, style: text.headlineSmall),
      const SizedBox(height: 4),
      Text(s['plates_notice_read'], textAlign: TextAlign.center, style: text.bodySmall),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final k in const ['plates_notice_1', 'plates_notice_2', 'plates_notice_3', 'plates_notice_4'])
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(padding: EdgeInsets.only(top: 2, right: 8), child: Icon(Icons.check_circle_outline, size: 20)),
                      Expanded(child: Text(s[k], style: text.titleMedium)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(s['plates_notice_teacher'], style: text.bodySmall),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => setState(() => _stage = _Stage.setup),
        icon: const Icon(Icons.check),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_agree'])),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_decline'])),
      ),
    ]);
  }

  Widget _segments<T>(String title, List<T> values, T value, String Function(T) label, ValueChanged<T> onChanged) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 6),
      SegmentedButton<T>(
        showSelectedIcon: false,
        segments: [
          for (final v in values) ButtonSegment(value: v, label: FittedBox(fit: BoxFit.scaleDown, child: Text(label(v)))),
        ],
        selected: {value},
        onSelectionChanged: (v) => onChanged(v.first),
      ),
      const SizedBox(height: 16),
    ],
  );

  Widget _setup() {
    final shapes = _shapes;
    if (shapes == null) return const Center(child: CircularProgressIndicator());
    final available = shapes.where((x) => _group == 'all' || x.group == _group).length;
    return _page([
      _segments(s['plates_group'], plateGroups, _group, (g) => s['plates_group_$g'], (v) => setState(() => _group = v)),
      _segments(s['plates_count'], plateCounts, _count, (c) => '$c', (v) => setState(() => _count = v)),
      _segments(
        s['plates_palette'],
        ['mix', for (final p in platePalettes) p.id],
        _palette,
        (p) => s['plates_palette_$p'],
        (v) => setState(() => _palette = v),
      ),
      if (available < _count) Text(s.f('plates_only', [available]), style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      Text(s['plates_keys'], style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _start,
        icon: const Icon(Icons.play_arrow),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_start'])),
      ),
    ]);
  }

  Widget _plate() {
    final (shape, _, _) = _deck[_at];
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GestureDetector(
              onTap: () => setState(() => _revealed = !_revealed),
              child: AspectRatio(
                aspectRatio: 1,
                child: CustomPaint(painter: PlatePainter(_dots(_at), revealed: _revealed)),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: Center(
            child: _revealed
                ? Text(shape.label(widget.lang), style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700))
                : Text(s['plates_question'], style: text.titleMedium),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: Row(
            children: [
              IconButton.outlined(
                tooltip: s['plates_back'],
                onPressed: _at > 0 ? () => _go(_at - 1) : null,
                icon: const Icon(Icons.arrow_back),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility),
                  label: FittedBox(fit: BoxFit.scaleDown, child: Text(s[_revealed ? 'plates_hide' : 'plates_reveal'])),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: s['next'],
                onPressed: () => _go(_at + 1),
                icon: const Icon(Icons.arrow_forward),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _end() {
    final text = Theme.of(context).textTheme;
    return _page([
      Icon(Icons.palette_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 8),
      Text(s['plates_end_title'], textAlign: TextAlign.center, style: text.headlineSmall),
      const SizedBox(height: 16),
      for (final k in const ['plates_end_1', 'plates_end_2', 'plates_end_3'])
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(s[k], style: text.titleMedium))),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: () => setState(() => _stage = _Stage.setup),
        icon: const Icon(Icons.replay),
        label: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_again'])),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: Padding(padding: const EdgeInsets.all(8), child: Text(s['close'])),
      ),
    ]);
  }
}
