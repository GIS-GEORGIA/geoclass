import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'export.dart';
import 'mapping.dart' show formatClock;
import 'nicknames.dart';
import 'puzzle.dart';
import 'session_base.dart';

/// The puzzle game: the clock, who finished and how fast, and which pieces were hard.
class PuzzleSessionPage extends SessionPageBase {
  /// Outlines already loaded; otherwise the page loads assets/ge_units.json itself.
  final GeoUnits? units;

  /// False in tests: the picture then stays in plain colours.
  final bool loadMap;
  const PuzzleSessionPage({
    super.key,
    required super.settings,
    required super.session,
    super.showQrOnOpen,
    this.units,
    this.loadMap = true,
  });
  @override
  State<PuzzleSessionPage> createState() => _PuzzleSessionPageState();
}

class _PuzzleSessionPageState extends SessionPageState<PuzzleSessionPage> {
  List<PuzzleTry> _tries = const [];
  int _minutes = 5;
  int _tab = 0; // leaderboard, hard pieces, the solved picture
  bool _showSolution = false;
  Timer? _tick;
  PuzzleBoard? _board;
  ui.Image? _art;
  bool _mapShown = false;
  Map<String, String> _regionNames = const {};

  PuzzleSpec get _spec => PuzzleSpec.fromSettings(session.settings);
  int? get _endsAt => session.settings['endsAt'] as int?;
  int get _left => (_endsAt ?? 0) - session.serverNow;
  bool get _running => _endsAt != null && _left > 0;
  int get _pieces => _board?.pieces.length ?? _spec.pieces;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2) setState(() {});
    });
    _prepare();
  }

  Future<void> _prepare() async {
    final units = widget.units ?? await loadGeoUnits();
    final spec = _spec;
    final board = buildBoard(
      units,
      widget.loadMap ? spec : PuzzleSpec.fromSettings({...spec.toJson(), 'look': 'color'}),
    );
    if (!mounted) return;
    setState(() {
      _board = board;
      _regionNames = {for (final r in units.regions) r.id: r.name(lang)};
    });
    final (art, map) = await puzzleArt(board);
    if (!mounted) {
      art.dispose();
      return;
    }
    setState(() {
      _art = art;
      _mapShown = map;
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _art?.dispose();
    super.dispose();
  }

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) => _tries = [for (final r in rows) PuzzleTry.fromJson(r)];
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => _tries.length;
  @override
  int get shownCount => _tries.length;
  @override
  String exportCsv() => puzzleToCsv(_tries, _pieces, session.settings['startedAt'] as int?, lang);
  @override
  String exportGeoJson() => '{}';
  @override
  List<Widget> mapLayers() => const [];
  @override
  List<Widget> mapOverlays() => const [];

  void _start() => run(() => api.setTimer(session.id, seconds: _minutes * 60));
  void _addMinute() => run(() => api.setTimer(session.id, seconds: (_left + 60).clamp(60, 3600)));
  void _stop() => run(() => api.setTimer(session.id, seconds: 0));

  Widget _clock() {
    final theme = Theme.of(context);
    if (_running) {
      return Card(
        color: _left <= 30 ? theme.colorScheme.errorContainer : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Text(formatClock(_left), style: theme.textTheme.displaySmall),
              const Spacer(),
              TextButton(onPressed: _addMinute, child: Text(s['mapping_more'])),
              IconButton(tooltip: s['mapping_stop'], icon: const Icon(Icons.stop_circle_outlined), onPressed: _stop),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_endsAt != null)
              Text(s['mapping_time_up'], textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
            Row(
              children: [
                IconButton(
                  tooltip: s['mapping_less'],
                  icon: const Icon(Icons.remove),
                  onPressed: _minutes > 1 ? () => setState(() => _minutes--) : null,
                ),
                Text(s.f('mapping_minutes', [_minutes]), style: theme.textTheme.titleMedium),
                IconButton(
                  tooltip: s['mapping_more'],
                  icon: const Icon(Icons.add),
                  onPressed: _minutes < 60 ? () => setState(() => _minutes++) : null,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: FilledButton(
                    onPressed: _start,
                    child: Text(s['mapping_start'], overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
            Text(
              _tries.isEmpty ? s['puzzle_note'] : s['mapping_kept'],
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  String _settingsLine() {
    final spec = _spec;
    final area = spec.area == 'georgia' ? s['puzzle_georgia'] : (_regionNames[spec.area] ?? spec.area);
    return [
      s['puzzle_kind_${spec.kind}'],
      area,
      s.f('puzzle_pieces', [_pieces]),
      s['cards_rot_${spec.rotation}'],
      s['puzzle_help_${spec.help}'],
      s['puzzle_look_${spec.look}'],
    ].join(' · ');
  }

  @override
  Widget panel() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _clock(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(_settingsLine(), style: Theme.of(context).textTheme.bodySmall),
            ),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(s['leaderboard'])),
                ButtonSegment(value: 1, label: Text(s['puzzle_hard'])),
                ButtonSegment(value: 2, label: Text(s['puzzle_solution'])),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() => _tab = v.first),
            ),
            const SizedBox(height: 8),
            ...switch (_tab) {
              0 => _leaderRows(),
              1 => _pieceRows(),
              _ => _solution(),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _leaderRows() {
    final rows = puzzleLeaderboard(_tries, _pieces, session.settings['startedAt'] as int?);
    if (rows.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Center(child: Text(s['no_results'])),
        ),
      ];
    }
    final text = Theme.of(context).textTheme;
    return [
      for (final (i, r) in rows.indexed)
        ListTile(
          leading: CircleAvatar(child: r.seconds != null ? const Icon(Icons.flag) : Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang), style: text.titleMedium),
          subtitle: Text(
            [
              s.f('puzzle_mistakes', [r.mistakes]),
              if (r.seconds != null) s.f('puzzle_time', [formatClock(r.seconds!)]),
            ].join(' · '),
          ),
          trailing: Text('${r.placed} / $_pieces', style: text.titleLarge),
        ),
    ];
  }

  List<Widget> _pieceRows() {
    final board = _board;
    if (board == null) return const [Center(child: CircularProgressIndicator())];
    final students = _tries.map((t) => t.participantId).toSet().length;
    return [
      for (final r in hardestPieces(_tries, board.pieces.length).take(15))
        ListTile(
          leading: SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: PieceView(
                piece: board.pieces[r.piece],
                art: _art,
                scale: 52 / board.pieces[r.piece].bounds.size.longestSide,
              ),
            ),
          ),
          title: Text(board.pieces[r.piece].name(lang)),
          subtitle: Text(s.f('puzzle_piece_stats', [r.placed, students, r.mistakes])),
        ),
    ];
  }

  List<Widget> _solution() {
    final board = _board;
    final theme = Theme.of(context);
    if (board == null) return const [Center(child: CircularProgressIndicator())];
    if (!_showSolution) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Text(s['puzzle_solution_hidden'], textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => setState(() => _showSolution = true),
                icon: const Icon(Icons.visibility),
                label: Text(s['puzzle_show']),
              ),
            ],
          ),
        ),
      ];
    }
    return [
      AspectRatio(
        aspectRatio: board.size.aspectRatio,
        child: LayoutBuilder(
          builder: (context, box) => CustomPaint(
            size: box.biggest,
            painter: BoardPainter(
              board: board,
              art: _art,
              placed: {for (final p in board.pieces) p.index},
              lang: lang,
              background: theme.colorScheme.surfaceContainerHighest,
              ink: theme.colorScheme.onSurface,
              scale: box.maxWidth / board.size.width,
            ),
          ),
        ),
      ),
      const SizedBox(height: 4),
      PuzzleCredit(spec: _spec, map: _mapShown),
    ];
  }
}
