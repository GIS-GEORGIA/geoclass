import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'cards.dart';
import 'export.dart';
import 'mapping.dart' show formatClock;
import 'nicknames.dart';
import 'session_base.dart';

/// The cards game: the clock, who has found the most pairs, and which pairs were hard.
class CardsSessionPage extends SessionPageBase {
  const CardsSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<CardsSessionPage> createState() => _CardsSessionPageState();
}

class _CardsSessionPageState extends SessionPageState<CardsSessionPage> {
  List<CardTry> _tries = const [];
  int _minutes = 3;
  bool _showPairs = false;
  Timer? _tick;

  Deck get _deck => Deck.fromSettings(session.settings);
  int? get _endsAt => session.settings['endsAt'] as int?;
  int get _left => (_endsAt ?? 0) - session.serverNow;
  bool get _running => _endsAt != null && _left > 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  bool get hasMap => false;
  @override
  void onRows(List<Map<String, dynamic>> rows) => _tries = [for (final r in rows) CardTry.fromJson(r)];
  @override
  List<LatLng> get fitPoints => const [];
  @override
  int get answerCount => _tries.length;
  @override
  int get shownCount => _tries.length;
  @override
  String exportCsv() => cardsToCsv(_tries, _deck.pairs.length, lang);
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
              _tries.isEmpty ? s['cards_deck_note'] : s['mapping_kept'],
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget panel() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _clock(),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(s['leaderboard'])),
              ButtonSegment(value: true, label: Text(s['cards_pairs'])),
            ],
            selected: {_showPairs},
            onSelectionChanged: (v) => setState(() => _showPairs = v.first),
          ),
          const SizedBox(height: 8),
          if (_showPairs) ...[..._pairRows(), const Center(child: CardsCredit())] else ..._leaderRows(),
        ],
      ),
    ),
  );

  List<Widget> _leaderRows() {
    final rows = cardsLeaderboard(_tries);
    if (rows.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(32), child: Center(child: Text(s['no_results'])))];
    }
    final total = _deck.pairs.length;
    final text = Theme.of(context).textTheme;
    return [
      for (final (i, r) in rows.indexed)
        ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang), style: text.titleMedium),
          subtitle: Text(s.f('cards_mistakes', [r.mistakes])),
          trailing: Text('${r.found} / $total', style: text.titleLarge),
        ),
    ];
  }

  List<Widget> _pairRows() {
    final deck = _deck;
    final stats = pairStats(_tries, deck.pairs.length);
    final students = _tries.map((t) => t.participantId).toSet().length;
    return [
      for (final (i, p) in deck.pairs.indexed)
        ListTile(
          leading: SizedBox(
            width: 96,
            child: Row(
              children: [
                for (final f in [p.a, p.b])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: TurnedImage(url: cardUrl(f), angle: 0, fill: false),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          title: Text(p.labelFor(lang).isEmpty ? '${i + 1}' : p.labelFor(lang)),
          subtitle: Text(s.f('cards_pair_stats', [stats.found[i], students, stats.confused[i]])),
        ),
    ];
  }
}
