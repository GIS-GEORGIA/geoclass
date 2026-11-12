import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'l10n.dart';
import 'mapping.dart' show formatClock;
import 'models.dart';
import 'puzzle.dart';
import 'queue.dart';

/// The student's side of the puzzle: drag each piece from the tray to its place on the board.
class PuzzlePlay extends StatefulWidget {
  final S s;
  final String lang;
  final String token;
  final Map<String, dynamic> settings;
  final int now; // the server's clock, from the same reply as settings
  final Api api;
  final ValueChanged<String> onStopped;

  /// Outlines already loaded; otherwise the widget loads assets/ge_units.json itself.
  final GeoUnits? units;

  /// For the map tiles; tests pass one that never calls the network.
  final http.Client? tiles;
  const PuzzlePlay({
    super.key,
    required this.s,
    required this.lang,
    required this.token,
    required this.settings,
    required this.now,
    required this.api,
    required this.onStopped,
    this.units,
    this.tiles,
  });
  @override
  State<PuzzlePlay> createState() => _PuzzlePlayState();
}

class _PuzzlePlayState extends State<PuzzlePlay> {
  late Map<String, dynamic> _settings = widget.settings;
  late int _clockOffset = widget.now - deviceSeconds();
  Timer? _poll, _tick, _retry, _flash;
  String _participant = '';
  bool _loaded = false;
  bool _sending = false;

  PuzzleBoard? _board;
  ui.Image? _art;
  bool _mapShown = false;
  bool _artFailed = false;

  // The student's own tray: its order and each piece's turn, so neighbours' screens differ.
  List<int> _tray = const [];
  Map<int, int> _angle = {};
  final _placed = <int>{};
  var _mistakes = 0;
  int? _doneAt; // device seconds, server clock
  final _pending = <Map<String, dynamic>>[];
  String? _message;
  int? _wrongPiece;

  final _boardKey = GlobalKey();
  final _viewer = TransformationController();
  double _fit = 1;

  S get s => widget.s;
  PuzzleSpec get _spec => PuzzleSpec.fromSettings(_settings);
  String get _storeKey => 'puzzle_${widget.token}';
  int get _serverNow => deviceSeconds() + _clockOffset;
  int? get _endsAt => _settings['endsAt'] as int?;
  int? get _startedAt => _settings['startedAt'] as int?;
  int get _resetAt => _settings['resetAt'] as int? ?? 0;
  int get _left => (_endsAt ?? 0) - _serverNow;
  bool get _running => _endsAt != null && _left > 0;
  bool get _done => _board != null && _placed.length == _board!.pieces.length;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2 && !_done) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _retry?.cancel();
    _flash?.cancel();
    _viewer.dispose();
    _art?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final units = widget.units ?? await loadGeoUnits();
    final board = buildBoard(units, _spec);
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId(widget.token);
    _board = board;
    final saved = prefs.getString(_storeKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      final tray = (data['tray'] as List?)?.cast<int>();
      if (data['resetAt'] == _resetAt && tray != null && tray.every((i) => i >= 0 && i < board.pieces.length)) {
        _tray = tray;
        _angle = {
          for (final e in (data['angle'] as Map<String, dynamic>? ?? const {}).entries)
            int.parse(e.key): e.value as int,
        };
        _placed.addAll((data['placed'] as List).cast<int>());
        _mistakes = data['mistakes'] as int;
        _doneAt = data['doneAt'] as int?;
        _pending.addAll((data['pending'] as List).cast<Map<String, dynamic>>());
      }
    }
    if (_tray.isEmpty && _placed.isEmpty) _deal();
    if (!mounted) return;
    setState(() => _loaded = true);
    _loadArt(board);
    await _save();
    _send();
    _refresh();
  }

  Future<void> _loadArt(PuzzleBoard board) async {
    final (art, map) = await puzzleArt(board, client: widget.tiles);
    if (!mounted || board != _board) {
      art.dispose();
      return;
    }
    setState(() {
      _art?.dispose();
      _art = art;
      _mapShown = map;
      _artFailed = board.spec.look == 'map' && !map;
    });
  }

  /// A fresh tray: the pieces in a random order, each turned at random if the teacher chose turning.
  void _deal() {
    final board = _board!;
    final random = Random();
    _tray = [for (final p in board.pieces) p.index]..shuffle(random);
    final step = board.spec.step;
    _angle = {
      for (final i in _tray)
        if (step > 0) i: (1 + random.nextInt(360 ~/ step - 1)) * step,
    };
  }

  Future<void> _save() async {
    await (await SharedPreferences.getInstance()).setString(
      _storeKey,
      jsonEncode({
        'resetAt': _resetAt,
        'tray': _tray,
        'angle': {for (final e in _angle.entries) '${e.key}': e.value},
        'placed': _placed.toList(),
        'mistakes': _mistakes,
        'doneAt': _doneAt,
        'pending': _pending,
      }),
    );
  }

  /// Asks the server whether the clock changed. Quick while waiting, so everyone starts together.
  Future<void> _refresh() async {
    _poll?.cancel();
    try {
      final data = await widget.api.join(widget.token);
      if (!mounted) return;
      final status = data['status'] as String;
      if (status != 'open') {
        widget.onStopped(status);
        return;
      }
      final settings = data['settings'] as Map<String, dynamic>? ?? const {};
      setState(() {
        _clockOffset = (data['now'] as int? ?? deviceSeconds()) - deviceSeconds();
        final reset = (settings['resetAt'] as int? ?? 0) != _resetAt;
        _settings = settings;
        if (reset) {
          _placed.clear();
          _pending.clear();
          _mistakes = 0;
          _doneAt = null;
          _deal();
        }
      });
      await _save();
    } on ApiError catch (e) {
      if (e.status == 404) {
        widget.onStopped('closed');
        return;
      }
    } on NoConnection {
      // The clock keeps counting on the device.
    }
    if (mounted) {
      _poll = Timer(Duration(seconds: _endsAt == null ? 4 : (_running ? 10 : 15)), _refresh);
    }
  }

  /// Sends in the order played. A placement the server refuses is dropped: it can't be played again.
  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    _retry?.cancel();
    var again = false;
    while (mounted && _pending.isNotEmpty && !again) {
      final item = _pending.first;
      try {
        await widget.api.submit({
          'token': widget.token,
          'submissionId': item['id'],
          'participantId': _participant,
          'answer': {'ok': item['ok'], 'piece': item['piece']},
          'lat': 0,
          'lon': 0,
        });
        _pending.removeAt(0);
      } on NoConnection {
        again = true;
      } on ApiError catch (e) {
        if (e.status == 429 || e.status >= 500) {
          again = true;
        } else if (e.key == 'session_paused' || e.key == 'session_closed') {
          _sending = false;
          if (mounted) widget.onStopped(e.key.replaceFirst('session_', ''));
          return;
        } else {
          _pending.removeAt(0);
        }
      }
      await _save();
      if (mounted) setState(() {});
    }
    _sending = false;
    if (again && mounted) _retry = Timer(const Duration(seconds: 10), _send);
  }

  double get _zoom => _viewer.value.getMaxScaleOnAxis();

  void _turn(int piece) {
    final step = _spec.step;
    if (step == 0 || !_running) return;
    setState(() => _angle[piece] = ((_angle[piece] ?? 0) + step) % 360);
    _save();
  }

  void _say(String? message, {int? wrong}) {
    _flash?.cancel();
    setState(() {
      _message = message;
      _wrongPiece = wrong;
    });
    _flash = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() {
          _message = null;
          _wrongPiece = null;
        });
      }
    });
  }

  /// A piece was let go over the board, its centre at [global].
  void _drop(int index, Offset global) {
    final board = _board!;
    final box = _boardKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_running || _placed.contains(index)) return;
    final at = box.globalToLocal(global) / _fit;
    final piece = board.pieces[index];
    final tolerance = max(24 / (_fit * _zoom), 0.3 * min(piece.bounds.width, piece.bounds.height));
    final near = (at - piece.center).distance <= tolerance;
    final turned = (_angle[index] ?? 0) % 360 != 0;
    if (near && !turned) {
      setState(() {
        _placed.add(index);
        _tray = [..._tray]..remove(index);
        _pending.add({'id': randomId(), 'ok': true, 'piece': index});
        if (_done) _doneAt = _serverNow;
      });
      _say(null);
    } else {
      setState(() {
        _mistakes++;
        _pending.add({'id': randomId(), 'ok': false, 'piece': index});
      });
      _say(near ? s['puzzle_turn'] : s['puzzle_wrong'], wrong: index);
    }
    _save().then((_) => _send());
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (_endsAt == null) return _waiting();
    return Column(
      children: [
        _header(),
        // Over the board, so a message never moves it under the finger.
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: _boardView()),
              if (_message != null || _artFailed || !_running || _done)
                Positioned(top: 0, left: 0, right: 0, child: IgnorePointer(child: _banner())),
            ],
          ),
        ),
        if (_tray.isNotEmpty && _running) _trayView(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: PuzzleCredit(spec: _spec, map: _mapShown),
        ),
      ],
    );
  }

  Widget _waiting() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.extension, size: 56),
          const SizedBox(height: 16),
          Text(s['mapping_wait'], textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(s['puzzle_wait_body'], textAlign: TextAlign.center),
          const SizedBox(height: 24),
          const CircularProgressIndicator(),
        ],
      ),
    ),
  );

  Widget _header() {
    final theme = Theme.of(context);
    final hurry = _running && !_done && _left <= 30;
    return Material(
      color: hurry ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Icon(_running ? Icons.timer : Icons.timer_off),
            const SizedBox(width: 8),
            Text(_running ? formatClock(_left) : s['mapping_time_up'], style: theme.textTheme.titleLarge),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    children: [
                      if (_pending.isNotEmpty) ...[
                        Tooltip(
                          message: s['mapping_waiting_send'],
                          child: const Icon(Icons.cloud_upload_outlined, size: 20),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        s.f('puzzle_placed', [_placed.length, _board!.pieces.length]),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(width: 12),
                      Icon(Icons.close, size: 18, color: theme.colorScheme.error),
                      Text('$_mistakes', style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _banner() {
    final theme = Theme.of(context);
    final took = _doneAt == null ? null : max(0, _doneAt! - (_startedAt ?? _doneAt!));
    final text =
        _message ??
        (_done
            ? s.f('puzzle_done', [formatClock(took ?? 0)])
            : !_running
            ? s.f('puzzle_final', [_placed.length, _board!.pieces.length])
            : s['puzzle_map_failed']);
    final bad = _message != null && _wrongPiece != null;
    return Material(
      color: bad ? theme.colorScheme.errorContainer : theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(text, textAlign: TextAlign.center, style: theme.textTheme.titleSmall),
      ),
    );
  }

  Widget _boardView() {
    final board = _board!;
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        _fit = min(box.maxWidth / board.size.width, box.maxHeight / board.size.height);
        final size = board.size * _fit;
        return DragTarget<int>(
          onWillAcceptWithDetails: (_) => _running,
          onAcceptWithDetails: (d) {
            final piece = board.pieces[d.data];
            final shown = piece.bounds.size * _fit * _zoom;
            _drop(d.data, d.offset + Offset(shown.width / 2, shown.height / 2));
          },
          builder: (context, _, _) => InteractiveViewer(
            transformationController: _viewer,
            maxScale: 8,
            onInteractionEnd: (_) => setState(() {}),
            child: Center(
              child: CustomPaint(
                key: _boardKey,
                size: size,
                painter: BoardPainter(
                  board: board,
                  art: _art,
                  placed: {..._placed},
                  lang: widget.lang,
                  background: theme.colorScheme.surfaceContainerHighest,
                  ink: theme.colorScheme.onSurface,
                  scale: _fit,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _trayView() {
    final board = _board!;
    final theme = Theme.of(context);
    const box = 76.0;
    final names = _spec.names && !_spec.grid;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_spec.step > 0 ? s['puzzle_hint_turn'] : s['puzzle_hint'], style: theme.textTheme.bodySmall),
          ),
          SizedBox(
            height: box + (names ? 40 : 16),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              children: [for (final i in _tray) _trayPiece(board.pieces[i], box, names)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _trayPiece(PuzzlePiece piece, double box, bool names) {
    final angle = _angle[piece.index] ?? 0;
    final b = piece.bounds;
    // Fits by the diagonal when pieces turn, so a turned piece stays in its box.
    final scale = (box - 8) / (_spec.step > 0 ? b.size.longestSide * sqrt2 : b.size.longestSide);
    final shown = _fit * _zoom;
    final thumb = SizedBox(
      width: box,
      height: box,
      child: Center(
        child: PieceView(
          piece: piece,
          art: _art,
          scale: scale,
          angle: angle,
          tint: _wrongPiece == piece.index ? const Color(0x66FF1744) : null,
        ),
      ),
    );
    return Padding(
      key: ValueKey('piece-${piece.index}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SizedBox(
        width: names ? max(box, 84) : box,
        child: Column(
          children: [
            Draggable<int>(
              data: piece.index,
              // Up onto the board drags; sideways scrolls the tray.
              affinity: Axis.vertical,
              // Not before the picture is cut, so nobody drags a piece without its map.
              maxSimultaneousDrags: _running && _art != null ? 1 : 0,
              // The piece rides a little above the finger, so the finger doesn't hide where it goes.
              dragAnchorStrategy: (_, _, _) => Offset(b.width * shown / 2, b.height * shown / 2 + 28),
              feedback: Opacity(
                opacity: 0.85,
                child: PieceView(piece: piece, art: _art, scale: shown, angle: angle),
              ),
              childWhenDragging: Opacity(opacity: 0.25, child: thumb),
              child: Semantics(
                label: names ? piece.name(widget.lang) : null,
                button: true,
                child: GestureDetector(onTap: () => _turn(piece.index), child: thumb),
              ),
            ),
            if (names)
              Text(
                piece.name(widget.lang),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }
}
