import 'dart:math';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'layout.dart';
import 'puzzle.dart' show GeoUnits, loadGeoUnits;

/// The teacher chooses what students colour, and gets a legend with a colour for each unit.
class LayoutSetupPage extends StatefulWidget {
  final S s;
  final String lang;

  /// Outlines already loaded; otherwise the page loads assets/ge_units.json itself.
  final GeoUnits? units;
  const LayoutSetupPage({super.key, required this.s, required this.lang, this.units});
  @override
  State<LayoutSetupPage> createState() => _LayoutSetupPageState();
}

class _LayoutSetupPageState extends State<LayoutSetupPage> {
  GeoUnits? _units;
  String _area = 'georgia';
  final _random = Random();
  List<int> _legend = const [];

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _units = widget.units;
    if (_units == null) {
      loadGeoUnits().then((u) {
        if (mounted) setState(() => _units = u);
      });
    }
  }

  void _newLegend(int count) => _legend = makeLegend(count, _random);

  @override
  Widget build(BuildContext context) {
    final units = _units;
    final theme = Theme.of(context);
    if (units == null) {
      return Scaffold(
        appBar: AppBar(title: Text(s['layout_title'])),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final map = SheetMap.of(units, _area);
    if (_legend.length != map.units.length) _newLegend(map.units.length);
    final areas = ['georgia', for (final r in layoutRegions(units)) r.id];
    return Scaffold(
      appBar: AppBar(title: Text(s['layout_title'])),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              Text(s['layout_how'], style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              Text(s['layout_area'], style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _area,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                items: [
                  for (final a in areas)
                    DropdownMenuItem(
                      value: a,
                      child: Text(
                        a == 'georgia'
                            ? s['layout_area_georgia']
                            : s.f('layout_area_region', [units.region(a)!.name(widget.lang)]),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _area = v ?? 'georgia';
                  _legend = const [];
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text(s['layout_legend'], style: theme.textTheme.titleSmall)),
                  TextButton.icon(
                    onPressed: () => setState(() => _newLegend(map.units.length)),
                    icon: const Icon(Icons.shuffle),
                    label: Text(s['layout_shuffle']),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < map.units.length; i++)
                    Chip(
                      avatar: CircleAvatar(backgroundColor: layoutPalette[_legend[i]]),
                      label: Text(map.units[i].name(widget.lang)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(s['layout_preview'], style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              AspectRatio(
                aspectRatio: 1 / pageAspect,
                child: LayoutBuilder(
                  builder: (context, box) => DecoratedBox(
                    decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 6, color: Color(0x44000000))]),
                    child: CustomPaint(
                      size: box.biggest,
                      painter: SheetPainter(
                        map: map,
                        sheet: Sheet(
                          List.of(_legend),
                          [for (final k in layoutElements) SheetElement.initial(k, map.units.length)],
                          grid: 1,
                          title: s['layout_sample_title'],
                        ),
                        legend: _legend,
                        lang: widget.lang,
                      ),
                    ),
                  ),
                ),
              ),
              if (_area == 'georgia')
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(s['layout_occupied'], style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pop(context, LayoutSpec(_area, _legend)),
        icon: const Icon(Icons.check),
        label: Text(s['create']),
      ),
    );
  }
}
