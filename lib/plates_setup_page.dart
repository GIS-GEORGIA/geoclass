import 'dart:math';

import 'package:flutter/material.dart';

import 'l10n.dart';
import 'plates.dart';

/// The teacher chooses what the plates hide, how many and in which colours. Returns the deck.
class PlatesSetupPage extends StatefulWidget {
  final S s;

  /// Outlines already loaded; otherwise the page loads assets/plates.json itself.
  final List<PlateShape>? shapes;
  const PlatesSetupPage({super.key, required this.s, this.shapes});
  @override
  State<PlatesSetupPage> createState() => _PlatesSetupPageState();
}

class _PlatesSetupPageState extends State<PlatesSetupPage> {
  List<PlateShape>? _shapes;
  final _groups = <String>{'ge_region', 'country'};
  int _count = 9;
  String _palette = 'mix';

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

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );

  @override
  Widget build(BuildContext context) {
    final shapes = _shapes;
    final text = Theme.of(context).textTheme;
    final available = shapes?.where((x) => _groups.contains(x.group)).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(s['plates_title'])),
      body: shapes == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    _title(s['plates_group']),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final g in plateGroups)
                          FilterChip(
                            label: Text('${s['plates_group_$g']} · ${shapes.where((x) => x.group == g).length}'),
                            selected: _groups.contains(g),
                            onSelected: (on) => setState(() => on ? _groups.add(g) : _groups.remove(g)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _title(s['plates_count']),
                    SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: [for (final c in plateCounts) ButtonSegment(value: c, label: Text('$c'))],
                      selected: {_count},
                      onSelectionChanged: (v) => setState(() => _count = v.first),
                    ),
                    const SizedBox(height: 20),
                    _title(s['plates_palette']),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: [
                        for (final p in ['mix', for (final p in platePalettes) p.id])
                          ButtonSegment(
                            value: p,
                            label: FittedBox(fit: BoxFit.scaleDown, child: Text(s['plates_palette_$p'])),
                          ),
                      ],
                      selected: {_palette},
                      onSelectionChanged: (v) => setState(() => _palette = v.first),
                    ),
                    const SizedBox(height: 16),
                    if (_groups.isEmpty)
                      Text(
                        s['plates_none'],
                        style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error),
                      )
                    else if (available < _count)
                      Text(s.f('plates_only', [available]), style: text.bodySmall),
                    const SizedBox(height: 8),
                    Text(s['plates_how'], style: text.bodySmall),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _groups.isEmpty
                          ? null
                          : () => Navigator.pop(context, makeDeck(shapes, _groups, _count, _palette, Random())),
                      icon: const Icon(Icons.check),
                      label: Padding(padding: const EdgeInsets.all(8), child: Text(s['create'])),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
