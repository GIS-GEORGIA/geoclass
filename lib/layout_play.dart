import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'files.dart';
import 'l10n.dart';
import 'layout.dart';
import 'puzzle.dart' show GeoUnits, loadGeoUnits;
import 'queue.dart';

/// The student's side of the map layout: colour the units as the legend says, put the map's elements on the
/// A4 page, hand it in and print it as a PDF.
class LayoutPlay extends StatefulWidget {
  final S s;
  final String lang;
  final String token;
  final Map<String, dynamic> settings;
  final Api api;
  final ValueChanged<String> onStopped;

  /// Outlines already loaded; otherwise the widget loads assets/ge_units.json itself.
  final GeoUnits? units;
  const LayoutPlay({
    super.key,
    required this.s,
    required this.lang,
    required this.token,
    required this.settings,
    required this.api,
    required this.onStopped,
    this.units,
  });
  @override
  State<LayoutPlay> createState() => _LayoutPlayState();
}

enum _Drag { none, move, resize }

class _LayoutPlayState extends State<LayoutPlay> {
  late final LayoutSpec _spec = LayoutSpec.fromSettings(widget.settings);
  SheetMap? _map;
  Sheet? _sheet;
  int _colour = -2; // a legend row; -1 rubs out, -2 nothing chosen yet
  String? _selected;
  int? _score;
  bool _sending = false;
  final _title = TextEditingController();

  var _drag = _Drag.none;
  Rect _start = Rect.zero;
  Offset _from = Offset.zero;

  S get s => widget.s;
  String get _storeKey => 'layout_${widget.token}';
  int get _resetAt => widget.settings['resetAt'] as int? ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final units = widget.units ?? await loadGeoUnits();
    final map = SheetMap.of(units, _spec.area);
    final prefs = await SharedPreferences.getInstance();
    var sheet = Sheet.empty(map.units.length);
    final saved = prefs.getString(_storeKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      if (data['resetAt'] == _resetAt) {
        sheet = Sheet.fromJson(data['sheet'] as Map<String, dynamic>, map.units.length);
        _score = data['score'] as int?;
      }
    }
    if (!mounted) return;
    _title.text = sheet.title;
    setState(() {
      _map = map;
      _sheet = sheet;
    });
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(
    _storeKey,
    jsonEncode({'resetAt': _resetAt, 'sheet': _sheet!.toJson(), 'score': _score}),
  );

  void _changed() {
    setState(() {});
    _save();
  }

  Offset _page(Offset local, Size size) => Offset(local.dx / size.width, local.dy / size.height);

  SheetElement? _elementAt(Offset f) {
    for (final e in _sheet!.elements.reversed) {
      if (e.rect.inflate(0.01).contains(f)) return e;
    }
    return null;
  }

  bool _onHandle(Offset local, Size size) {
    final e = _selected == null ? null : _sheet!.element(_selected!);
    if (e == null) return false;
    final corner = Offset(e.rect.right * size.width, e.rect.bottom * size.height);
    return (local - corner).distance <= 24;
  }

  void _tap(Offset local, Size size) {
    final f = _page(local, size);
    final e = _elementAt(f);
    if (e != null) {
      setState(() => _selected = e.kind);
      return;
    }
    final unit = _map!.unitAt(Offset(f.dx, f.dy * pageAspect));
    if (unit == null || _colour == -2) {
      setState(() => _selected = null);
      if (unit != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s['layout_pick_colour'])));
      }
      return;
    }
    _sheet!.fills[unit] = _colour < 0 ? -1 : _spec.legend[_colour];
    _selected = null;
    _changed();
  }

  void _panStart(Offset local, Size size) {
    if (_onHandle(local, size)) {
      _drag = _Drag.resize;
    } else {
      final e = _elementAt(_page(local, size));
      if (e == null) {
        _drag = _Drag.none;
        return;
      }
      _drag = _Drag.move;
      _selected = e.kind;
    }
    _start = _sheet!.element(_selected!)!.rect;
    _from = local;
    setState(() {});
  }

  void _panUpdate(Offset local, Size size) {
    if (_drag == _Drag.none) return;
    final e = _sheet!.element(_selected!)!;
    final d = Offset((local.dx - _from.dx) / size.width, (local.dy - _from.dy) / size.height);
    setState(() {
      if (_drag == _Drag.move) {
        final x = (_start.left + d.dx).clamp(-_start.width / 2, 1 - _start.width / 2);
        final y = (_start.top + d.dy).clamp(-_start.height / 2, 1 - _start.height / 2);
        e.rect = Rect.fromLTWH(x, y, _start.width, _start.height);
      } else {
        // Keeps the element's shape: the width leads, the height follows.
        final w = (_start.width + d.dx).clamp(0.03, 0.95);
        final h = _start.height * w / _start.width;
        if (h <= 0.95) e.rect = Rect.fromLTWH(_start.left, _start.top, w, h);
      }
    });
  }

  void _toggle(String kind, bool on) {
    final sheet = _sheet!;
    if (on) {
      sheet.elements.add(SheetElement.initial(kind, _map!.units.length));
      _selected = kind;
    } else {
      sheet.elements.removeWhere((e) => e.kind == kind);
      if (_selected == kind) _selected = null;
    }
    _changed();
  }

  Future<void> _handIn() async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data = await widget.api.submit({
        'token': widget.token,
        'submissionId': randomId(),
        'participantId': await participantId(widget.token),
        'answer': _sheet!.toJson(),
        'lat': 0,
        'lon': 0,
      });
      _score = data['score'] as int? ?? layoutScore(_spec.legend, _sheet!);
      await _save();
      messenger.showSnackBar(SnackBar(content: Text(s.f('layout_handed_in', [_score]))));
    } on ApiError catch (e) {
      if (e.key == 'session_paused' || e.key == 'session_closed') {
        widget.onStopped(e.key.replaceFirst('session_', ''));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(s.f('failed', [s[e.key]]))));
      }
    } on NoConnection {
      messenger.showSnackBar(SnackBar(content: Text(s.f('failed', [s['no_connection']]))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pdf() async {
    final bytes = await sheetPdf(_map!, _sheet!, _spec.legend, widget.lang);
    await saveBytes(bytes, 'geoclass-map', 'pdf', 'application/pdf');
  }

  @override
  Widget build(BuildContext context) {
    if (_map == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 900;
        final sheet = Padding(
          padding: const EdgeInsets.all(8),
          child: Center(child: _sheetView()),
        );
        if (wide) {
          return Row(
            children: [
              Expanded(child: sheet),
              SizedBox(width: 340, child: _tools()),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: sheet),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: box.maxHeight * 0.48),
              child: _tools(),
            ),
          ],
        );
      },
    );
  }

  Widget _sheetView() => AspectRatio(
    aspectRatio: 1 / pageAspect,
    child: LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final selected = _selected == null ? null : _sheet!.element(_selected!);
        return DecoratedBox(
          decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Color(0x44000000))]),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              GestureDetector(
                onTapUp: (d) => _tap(d.localPosition, size),
                onPanStart: (d) => _panStart(d.localPosition, size),
                onPanUpdate: (d) => _panUpdate(d.localPosition, size),
                onPanEnd: (_) {
                  if (_drag != _Drag.none) _save();
                  _drag = _Drag.none;
                },
                child: CustomPaint(
                  key: const ValueKey('sheet'),
                  size: size,
                  painter: SheetPainter(
                    map: _map!,
                    sheet: _sheet!,
                    legend: _spec.legend,
                    lang: widget.lang,
                    selected: _selected,
                  ),
                ),
              ),
              if (selected != null)
                Positioned(
                  left: selected.rect.right * size.width - 12,
                  top: selected.rect.bottom * size.height - 12,
                  child: IgnorePointer(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.open_in_full, size: 14, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _tools() {
    final theme = Theme.of(context);
    final sheet = _sheet!;
    final map = _map!;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(s['layout_colour_hint'], style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < map.units.length; i++)
                ChoiceChip(
                  avatar: CircleAvatar(backgroundColor: layoutPalette[_spec.legend[i]]),
                  label: Text(map.units[i].name(widget.lang)),
                  selected: _colour == i,
                  onSelected: (_) => setState(() => _colour = i),
                ),
              ChoiceChip(
                avatar: const Icon(Icons.auto_fix_off, size: 18),
                label: Text(s['layout_erase']),
                selected: _colour == -1,
                onSelected: (_) => setState(() => _colour = -1),
              ),
            ],
          ),
          const Divider(height: 24),
          Text(s['layout_elements'], style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in layoutElements)
                FilterChip(
                  label: Text(s['layout_el_$k']),
                  selected: sheet.element(k) != null,
                  onSelected: (on) => _toggle(k, on),
                ),
            ],
          ),
          if (sheet.element('title') != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: TextField(
                controller: _title,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: s['layout_title_text'],
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) {
                  sheet.title = v.trim();
                  _changed();
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(s['layout_move_hint'], style: theme.textTheme.bodySmall),
          ),
          const Divider(height: 24),
          Text(s['layout_grid'], style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          SegmentedButton<double>(
            segments: [
              for (final g in layoutGrids)
                ButtonSegment(value: g, label: Text(g == 0 ? s['layout_grid_none'] : (g == 1 ? '1°' : '0.5°'))),
            ],
            selected: {sheet.grid},
            onSelectionChanged: (v) {
              sheet.grid = v.first;
              _changed();
            },
          ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: Text(s['layout_pdf']),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sending ? null : _handIn,
                  icon: const Icon(Icons.send),
                  label: Text(_score == null ? s['layout_hand_in'] : s['layout_hand_in_again']),
                ),
              ),
            ],
          ),
          if (_score != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                s.f('layout_score', [_score]),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
          const SizedBox(height: 8),
          Text('© OpenStreetMap contributors', textAlign: TextAlign.center, style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}
