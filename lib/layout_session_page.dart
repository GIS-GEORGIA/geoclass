import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'files.dart';
import 'layout.dart';
import 'nicknames.dart';
import 'puzzle.dart' show GeoUnits, loadGeoUnits;
import 'session_base.dart';

/// One student's handed-in sheet.
class LayoutWork {
  final String participantId;
  final int score, createdAt;
  final Map<String, dynamic> answer;
  const LayoutWork(this.participantId, this.score, this.createdAt, this.answer);

  factory LayoutWork.fromJson(Map<String, dynamic> j) => LayoutWork(
    j['participantId'] as String,
    j['score'] as int? ?? 0,
    j['createdAt'] as int? ?? 0,
    j['answer'] as Map<String, dynamic>,
  );
}

String layoutToCsv(List<LayoutWork> works, String lang) {
  final out = StringBuffer('﻿nickname,score,title,grid,elements\r\n');
  for (final w in works) {
    final title = (w.answer['title'] as String? ?? '').replaceAll('"', '""');
    final elements = [for (final e in w.answer['elements'] as List? ?? const []) (e as Map)['kind']].join(' ');
    out.write('"${nickname(w.participantId, lang)}",${w.score},"$title",${w.answer['grid'] ?? 0},$elements\r\n');
  }
  return out.toString();
}

/// The map layout game: who handed in what, with each sheet to look at and print.
class LayoutSessionPage extends SessionPageBase {
  final GeoUnits? units;
  const LayoutSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen, this.units});
  @override
  State<LayoutSessionPage> createState() => _LayoutSessionPageState();
}

class _LayoutSessionPageState extends SessionPageState<LayoutSessionPage> {
  List<LayoutWork> _works = const [];
  SheetMap? _map;

  LayoutSpec get _spec => LayoutSpec.fromSettings(session.settings);

  @override
  void initState() {
    super.initState();
    final units = widget.units;
    (units != null ? Future.value(units) : loadGeoUnits()).then((u) {
      if (mounted) setState(() => _map = SheetMap.of(u, _spec.area));
    });
  }

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) =>
      _works = [for (final r in rows) LayoutWork.fromJson(r)]..sort((a, b) => b.score.compareTo(a.score));
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => _works.length;
  @override
  int get shownCount => _works.length;
  @override
  String exportCsv() => layoutToCsv(_works, lang);
  @override
  String exportGeoJson() => '{}';
  @override
  List<Widget> mapLayers() => const [];
  @override
  List<Widget> mapOverlays() => const [];

  Sheet _sheetOf(LayoutWork w) => Sheet.fromJson(w.answer, _map!.units.length);

  Widget _sheetView(Sheet sheet) => AspectRatio(
    aspectRatio: 1 / pageAspect,
    child: LayoutBuilder(
      builder: (context, box) => DecoratedBox(
        decoration: const BoxDecoration(boxShadow: [BoxShadow(blurRadius: 4, color: Color(0x33000000))]),
        child: CustomPaint(
          size: box.biggest,
          painter: SheetPainter(map: _map!, sheet: sheet, legend: _spec.legend, lang: lang),
        ),
      ),
    ),
  );

  void _open(LayoutWork w) {
    final sheet = _sheetOf(w);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${nickname(w.participantId, lang)} · ${s.f('layout_score', [w.score])}'),
        content: SizedBox(width: 900, child: _sheetView(sheet)),
        actions: [
          TextButton.icon(
            onPressed: () async =>
                saveBytes(await sheetPdf(_map!, sheet, _spec.legend, lang), 'geoclass-map', 'pdf', 'application/pdf'),
            icon: const Icon(Icons.picture_as_pdf),
            label: Text(s['layout_pdf']),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s['close'])),
        ],
      ),
    );
  }

  @override
  Widget panel() {
    final map = _map;
    final theme = Theme.of(context);
    if (map == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s['layout_legend'], style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < map.units.length; i++)
                          Chip(
                            avatar: CircleAvatar(backgroundColor: layoutPalette[_spec.legend[i]]),
                            label: Text(map.units[i].name(lang)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(s['layout_teacher_note'], style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_works.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(child: Text(s['no_results'])),
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final w in _works)
                    SizedBox(
                      width: 280,
                      child: Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _open(w),
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _sheetView(_sheetOf(w)),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        nickname(w.participantId, lang),
                                        style: theme.textTheme.titleSmall,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text('${w.score}', style: theme.textTheme.titleLarge),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
