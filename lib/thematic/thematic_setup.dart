import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../puzzle.dart' show GeoUnit, GeoUnits, loadGeoUnits;
import 'thematic.dart';
import 'thematic_map.dart';

/// The teacher's setup: a table from a file (or the sample), its rows matched to regions or municipalities
/// with the unmatched ones picked by hand, up to four number columns, and the mode with its target.
class ThematicSetupPage extends StatefulWidget {
  final S s;
  final String lang;
  final GeoUnits? units;

  /// Stands in for the file picker in tests: the file's name and bytes.
  final Future<(String, Uint8List)?> Function()? pick;
  const ThematicSetupPage({super.key, required this.s, required this.lang, this.units, this.pick});

  @override
  State<ThematicSetupPage> createState() => _ThematicSetupPageState();
}

class _ThematicSetupPageState extends State<ThematicSetupPage> {
  GeoUnits? _all;
  String _level = 'regions';
  ThematicTable? _table;
  String _fileName = '';
  int _nameColumn = 0;
  List<String?> _rowUnits = const [];
  final _columns = <int>[];
  final _kinds = <int, String>{};
  final _title = TextEditingController();
  String _mode = 'target';
  ThematicChoice _target = const ThematicChoice(field: 0);
  String? _error;

  S get s => widget.s;
  String get lang => widget.lang;
  List<GeoUnit> get _units => levelUnits(_all!, _level);

  @override
  void initState() {
    super.initState();
    final u = widget.units;
    (u != null ? Future.value(u) : loadGeoUnits()).then((all) {
      if (mounted) setState(() => _all = all);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final (String, Uint8List)? file;
    if (widget.pick != null) {
      file = await widget.pick!();
    } else {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt', 'tsv', 'json', 'geojson'],
      );
      final bytes = await picked?.xFile.readAsBytes();
      file = bytes == null ? null : (picked!.xFile.name, bytes);
    }
    if (file == null || !mounted) return;
    _load(file.$1, file.$2);
  }

  void _sample() => _load(
    s['thematic_sample_name'],
    Uint8List.fromList(utf8.encode(sampleCsv(_units, lang))),
    kinds: const {1: 'rate'},
  );

  void _load(String name, Uint8List bytes, {Map<int, String> kinds = const {}}) {
    setState(() {
      _error = null;
      try {
        final t = readTable(bytes, name);
        final m = matchUnits(t, _units);
        _table = t;
        _fileName = name;
        _nameColumn = m.column;
        _rowUnits = m.units;
        _columns
          ..clear()
          ..addAll(numericColumns(t).where((c) => c != m.column).take(thematicFieldsMax));
        _kinds
          ..clear()
          ..addAll({for (final c in _columns) c: kinds[c] ?? 'count'});
        if (_title.text.isEmpty) _title.text = name.replaceFirst(RegExp(r'\.[A-Za-z]+$'), '');
        _target = const ThematicChoice(field: 0);
        if (_columns.isEmpty) _error = 'thematic_no_numbers';
      } on TableError catch (e) {
        _table = null;
        _error = e.key;
      }
    });
  }

  void _setLevel(String level) {
    setState(() {
      _level = level;
      final t = _table;
      if (t != null) _rowUnits = matchColumn(t, _nameColumn, _units);
    });
  }

  ThematicSettings? get _settings {
    final t = _table;
    if (t == null || _columns.isEmpty || _rowUnits.whereType<String>().length < 2) return null;
    return settingsFrom(
      table: t,
      level: _level,
      title: _title.text.trim(),
      mode: _mode,
      rowUnits: _rowUnits,
      columns: _columns,
      kinds: [for (final c in _columns) _kinds[c] ?? 'count'],
      target: _mode == 'target' ? _target : null,
    );
  }

  void _create() {
    final st = _settings;
    if (st == null) return;
    if (st.fields.any((f) => f.values.every((v) => v == null))) {
      setState(() => _error = 'thematic_field_empty');
      return;
    }
    final json = st.toJson();
    if (utf8.encode(jsonEncode(json)).length > thematicSettingsMax) {
      setState(() => _error = 'thematic_too_big');
      return;
    }
    Navigator.of(context).pop({'thematic': json});
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final st = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(s['game_thematic']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: st == null ? null : _create, child: Text(s['create'])),
          ),
        ],
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, box) {
                final form = _form(st);
                final preview = st == null ? null : _preview(all, st);
                if (box.maxWidth >= 1000 && preview != null) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 520, child: form),
                      Expanded(child: preview),
                    ],
                  );
                }
                return ListView(
                  children: [
                    form,
                    if (preview != null) SizedBox(height: 460, child: preview),
                  ],
                );
              },
            ),
    );
  }

  Widget _preview(GeoUnits all, ThematicSettings st) {
    final base = ThematicBase.of(all, st);
    final choice = st.target ?? ThematicChoice(field: _target.field, ramp: _target.ramp);
    final v = ThematicView.of(base, st, choice);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s[_mode == 'target' ? 'thematic_preview_target' : 'thematic_preview'],
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Expanded(
            child: ChoroplethView(view: v, s: s, lang: lang),
          ),
          ThematicLegend(view: v, s: s),
        ],
      ),
    );
  }

  Widget _form(ThematicSettings? st) {
    final theme = Theme.of(context);
    final t = _table;
    final unmatched = [
      for (var i = 0; i < _rowUnits.length; i++)
        if (_rowUnits[i] == null) i,
    ];
    final used = _rowUnits.whereType<String>().toSet();
    final numeric = t == null ? const <int>[] : numericColumns(t).where((c) => c != _nameColumn).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s['thematic_setup_hint'], style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final l in thematicLevels)
                ChoiceChip(
                  key: Key('thematic_level_$l'),
                  label: Text(s['thematic_level_$l']),
                  selected: _level == l,
                  onSelected: (_) => _setLevel(l),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.icon(
                key: const Key('thematic_file'),
                onPressed: _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(s['thematic_file']),
              ),
              OutlinedButton(key: const Key('thematic_sample'), onPressed: _sample, child: Text(s['thematic_sample'])),
            ],
          ),
          Text(s['thematic_file_hint'], style: theme.textTheme.bodySmall),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                s[_error!],
                key: const Key('thematic_error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (t != null) ...[
            const Divider(height: 24),
            Text(_fileName, style: theme.textTheme.titleSmall),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(s['thematic_name_column']),
                DropdownButton<int>(
                  value: _nameColumn,
                  items: [
                    for (var c = 0; c < t.columns.length; c++) DropdownMenuItem(value: c, child: Text(t.columns[c])),
                  ],
                  onChanged: (c) => setState(() {
                    _nameColumn = c!;
                    _rowUnits = matchColumn(t, c, _units);
                    _columns.remove(c);
                  }),
                ),
              ],
            ),
            Text(
              s.f('thematic_matched', [used.length, t.rows.length, _units.length]),
              key: const Key('thematic_matched'),
            ),
            if (unmatched.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s['thematic_unmatched'], style: theme.textTheme.titleSmall),
              for (final i in unmatched.take(30))
                Row(
                  children: [
                    Expanded(child: Text(t.rows[i][_nameColumn] ?? '—', overflow: TextOverflow.ellipsis)),
                    Expanded(
                      child: DropdownButton<String>(
                        key: Key('thematic_fix_$i'),
                        isExpanded: true,
                        hint: Text(s['thematic_pick_unit']),
                        items: [
                          for (final u in _units)
                            if (!used.contains(u.id)) DropdownMenuItem(value: u.id, child: Text(u.name(lang))),
                        ],
                        onChanged: (id) => setState(() => _rowUnits = [..._rowUnits]..[i] = id),
                      ),
                    ),
                  ],
                ),
              if (unmatched.length > 30) Text(s.f('thematic_more_rows', [unmatched.length - 30])),
            ],
            const Divider(height: 24),
            Text(s.f('thematic_columns', [thematicFieldsMax]), style: theme.textTheme.titleSmall),
            for (final c in numeric)
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Checkbox(
                    key: Key('thematic_column_$c'),
                    value: _columns.contains(c),
                    onChanged: (on) => setState(() {
                      if (on == true && _columns.length < thematicFieldsMax) {
                        _columns.add(c);
                        _kinds[c] ??= 'count';
                      } else if (on == false) {
                        _columns.remove(c);
                      }
                      if (_target.field >= _columns.length) _target = _target.copyWith(field: 0);
                    }),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: Text(t.columns[c], overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  if (_columns.contains(c))
                    SegmentedButton<String>(
                      segments: [
                        for (final k in thematicKinds) ButtonSegment(value: k, label: Text(s['thematic_kind_$k'])),
                      ],
                      selected: {_kinds[c] ?? 'count'},
                      onSelectionChanged: (k) => setState(() => _kinds[c] = k.first),
                    ),
                ],
              ),
            Text(s['thematic_kind_hint'], style: theme.textTheme.bodySmall),
            const Divider(height: 24),
            TextField(
              key: const Key('thematic_title'),
              controller: _title,
              maxLength: 80,
              decoration: InputDecoration(labelText: s['thematic_title'], border: const OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final m in thematicModes)
                  ChoiceChip(
                    key: Key('thematic_mode_$m'),
                    label: Text(s['thematic_mode_$m']),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ],
            ),
            Text(s['thematic_mode_${_mode}_hint'], style: theme.textTheme.bodySmall),
            if (_mode == 'target' && st != null && _all != null) ...[
              const SizedBox(height: 8),
              ThematicChoiceEditor(
                settings: st,
                base: ThematicBase.of(_all!, st),
                choice: _target,
                target: true,
                s: s,
                onChanged: (c) => setState(() => _target = c),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
