import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'puzzle.dart';

/// The teacher chooses what the puzzle is cut from and how hard it is. Returns the settings.
class PuzzleSetupPage extends StatefulWidget {
  final S s;
  final String lang;

  /// Outlines already loaded; otherwise the page loads assets/ge_units.json itself.
  final GeoUnits? units;

  /// False in tests: the preview then stays in plain colours and loads no map.
  final bool loadMap;
  const PuzzleSetupPage({super.key, required this.s, required this.lang, this.units, this.loadMap = true});
  @override
  State<PuzzleSetupPage> createState() => _PuzzleSetupPageState();
}

class _PuzzleSetupPageState extends State<PuzzleSetupPage> {
  GeoUnits? _units;
  String _kind = 'regions';
  String _area = 'georgia';
  int _size = 16;
  String _rotation = 'none';
  String _help = 'outline';
  bool _names = true;
  String _look = 'map';
  String _base = 'osm';
  final int _seed = Random().nextInt(1 << 30);

  PuzzleBoard? _board;
  ui.Image? _art;
  Object? _artFor;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _units = widget.units;
    if (_units == null) {
      loadGeoUnits().then((units) {
        if (mounted) setState(() => _units = units);
      });
    }
  }

  @override
  void dispose() {
    _art?.dispose();
    super.dispose();
  }

  PuzzleSpec _spec(GeoUnits units) {
    var spec = PuzzleSpec(
      kind: _kind,
      area: _kind == 'regions' ? 'georgia' : _area,
      rotation: _rotation,
      help: _help,
      names: _names && _kind != 'grid',
      look: _look,
      base: _base,
      seed: _seed,
    );
    if (spec.grid) {
      // The board's shape decides the rows and columns.
      final (rows, cols) = gridFor(buildBoard(units, spec.copyWith(rows: 3, cols: 3)).size, _size);
      spec = spec.copyWith(rows: rows, cols: cols);
    }
    return spec;
  }

  /// Rebuilds the board and its picture when something that changes them changes.
  void _prepare(GeoUnits units) {
    final spec = _spec(units);
    final key = (spec.kind, spec.area, spec.rows, spec.cols, widget.loadMap ? spec.look : 'color', spec.base);
    if (key == _artFor) return;
    _artFor = key;
    final board = buildBoard(units, spec);
    _board = board;
    final look = widget.loadMap
        ? board
        : buildBoard(units, PuzzleSpec.fromSettings({...spec.toJson(), 'look': 'color'}));
    puzzleArt(look).then((result) {
      if (!mounted || _artFor != key) {
        result.$1.dispose();
        return;
      }
      setState(() {
        _art?.dispose();
        _art = result.$1;
      });
    });
  }

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _choice(List<String> values, String selected, String prefix, ValueChanged<String> onSelected) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final v in values)
        ChoiceChip(
          label: Text(s['$prefix$v']),
          selected: v == selected,
          onSelected: (_) => setState(() => onSelected(v)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final units = _units;
    final theme = Theme.of(context);
    if (units == null) {
      return Scaffold(
        appBar: AppBar(title: Text(s['puzzle_title'])),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_kind == 'municipalities' && _area != 'georgia' && !units.divisible.any((r) => r.id == _area)) {
      _area = 'georgia';
    }
    _prepare(units);
    final spec = _spec(units);
    final board = _board!;
    final areas = [
      'georgia',
      ...[for (final r in _kind == 'municipalities' ? units.divisible : units.regions) r.id],
    ];
    String areaName(String id) => id == 'georgia' ? s['puzzle_georgia'] : units.region(id)!.name(widget.lang);

    return Scaffold(
      appBar: AppBar(title: Text(s['puzzle_title'])),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              _title(s['puzzle_kind']),
              _choice(puzzleKinds, _kind, 'puzzle_kind_', (v) => _kind = v),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(s['puzzle_kind_${_kind}_note'], style: theme.textTheme.bodySmall),
              ),
              if (_kind != 'regions') ...[
                _title(s['puzzle_area']),
                DropdownButtonFormField<String>(
                  key: ValueKey(_kind),
                  initialValue: _area,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [for (final a in areas) DropdownMenuItem(value: a, child: Text(areaName(a)))],
                  onChanged: (v) => setState(() => _area = v ?? 'georgia'),
                ),
              ],
              if (_kind == 'grid') ...[
                _title(s['puzzle_size']),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final n in puzzleSizes)
                      ChoiceChip(label: Text('$n'), selected: n == _size, onSelected: (_) => setState(() => _size = n)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    s.f('puzzle_size_value', [spec.rows, spec.cols, spec.rows * spec.cols]),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
              _title(s['puzzle_rotation']),
              _choice(puzzleRotations, _rotation, 'cards_rot_', (v) => _rotation = v),
              _title(s['puzzle_help']),
              _choice(puzzleHelps, _help, 'puzzle_help_', (v) => _help = v),
              if (_kind != 'grid') ...[
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s['puzzle_names']),
                  subtitle: Text(s['puzzle_names_note']),
                  value: _names,
                  onChanged: (v) => setState(() => _names = v),
                ),
              ],
              _title(s['puzzle_look']),
              _choice(puzzleLooks, _look, 'puzzle_look_', (v) => _look = v),
              if (_look == 'map') ...[
                _title(s['puzzle_base']),
                _choice(puzzleBases, _base, 'puzzle_base_', (v) => _base = v),
              ],
              _title(s['puzzle_preview']),
              Text(s.f('puzzle_pieces', [board.pieces.length]), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: board.size.aspectRatio,
                child: LayoutBuilder(
                  builder: (context, box) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CustomPaint(
                      size: box.biggest,
                      painter: BoardPainter(
                        board: board,
                        art: _art,
                        placed: {for (final p in board.pieces) p.index},
                        lang: widget.lang,
                        background: theme.colorScheme.surfaceContainerHighest,
                        ink: theme.colorScheme.onSurface,
                        scale: box.maxWidth / board.size.width,
                        names: _names,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              PuzzleCredit(spec: spec, map: _look == 'map'),
              if (spec.area == 'georgia' && !spec.grid)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(s['puzzle_occupied'], style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, spec.copyWith(pieces: board.pieces.length)),
        icon: const Icon(Icons.check),
        label: Text(s['create']),
      ),
    );
  }
}
