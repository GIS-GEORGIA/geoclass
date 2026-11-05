import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'cards.dart';
import 'l10n.dart';

const _randomCount = 6;

/// The teacher picks the pairs, how the cards are turned and whether a north arrow shows.
/// Returns the deck, with the turns already chosen so every student gets the same.
class CardsSetupPage extends StatefulWidget {
  final S s;
  final String lang;
  const CardsSetupPage({super.key, required this.s, required this.lang});
  @override
  State<CardsSetupPage> createState() => _CardsSetupPageState();
}

class _CardsSetupPageState extends State<CardsSetupPage> {
  List<CardPair>? _pairs;
  bool _failed = false;
  Set<String> _chosen = {}; // by first file
  String _rotation = 'none';
  bool _arrow = true;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final pairs = await loadCardPairs();
      if (mounted) {
        setState(() {
          _pairs = pairs;
          _chosen = {for (final p in pairs.take(_randomCount)) p.a};
        });
      }
    } on NoConnection {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _pickRandom() {
    final pool = [..._pairs!]..shuffle();
    setState(() => _chosen = {for (final p in pool.take(_randomCount)) p.a});
  }

  void _pickLevel(int level) {
    final pool = _pairs!.where((p) => p.level == level).take(maxPairs);
    setState(() => _chosen = {for (final p in pool) p.a});
  }

  void _toggle(CardPair p, bool on) {
    if (on && _chosen.length >= maxPairs) return;
    setState(() => on ? _chosen.add(p.a) : _chosen.remove(p.a));
  }

  void _finish() {
    final random = Random();
    final picked = [
      for (final p in _pairs!)
        if (_chosen.contains(p.a)) p,
    ]..shuffle(random);
    final deck = Deck(
      pairs: [
        for (final p in picked)
          () {
            final (ra, rb) = pickAngles(_rotation, random);
            return DeckPair(a: p.a, b: p.b, label: p.ka, labelEn: p.en, ra: ra, rb: rb);
          }(),
      ],
      arrow: _arrow,
      rotation: _rotation,
    );
    Navigator.pop(context, deck);
  }

  Widget _message(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );

  Widget _thumb(String file) => SizedBox(
    width: 44,
    height: 44,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        cardUrl(file),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black26),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pairs = _pairs;
    final enough = _chosen.length >= minPairs;
    return Scaffold(
      appBar: AppBar(
        title: Text(s['setup_cards']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: enough ? _finish : null, child: Text(s['create'])),
          ),
        ],
      ),
      body: _failed
          ? Center(
              child: FilledButton(onPressed: _load, child: Text(s['retry'])),
            )
          : pairs == null
          ? const Center(child: CircularProgressIndicator())
          : pairs.isEmpty
          ? _message(s['cards_none'])
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(s['cards_rotation'], style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 2)),
                      segments: [
                        for (final r in rotations)
                          ButtonSegment(
                            value: r,
                            label: FittedBox(fit: BoxFit.scaleDown, child: Text(s['cards_rot_$r'])),
                          ),
                      ],
                      selected: {_rotation},
                      onSelectionChanged: (v) => setState(() => _rotation = v.first),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _arrow && _rotation != 'none',
                      title: Text(s['cards_arrow']),
                      subtitle: Text(s['cards_arrow_note']),
                      onChanged: _rotation == 'none' ? null : (v) => setState(() => _arrow = v),
                    ),
                    const Divider(),
                    Row(
                      children: [
                        Expanded(child: Text(s.f('setup_chosen', [_chosen.length, pairs.length]))),
                        OutlinedButton.icon(
                          onPressed: _pickRandom,
                          icon: const Icon(Icons.casino),
                          label: Text(s.f('cards_random', [_randomCount])),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final level in const [1, 2, 3])
                          if (pairs.any((p) => p.level == level))
                            ActionChip(
                              label: Text(s.f('cards_level_pick', [level])),
                              onPressed: () => _pickLevel(level),
                            ),
                      ],
                    ),
                    if (!enough)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          s.f('cards_pick_more', [minPairs]),
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    for (final p in pairs)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _chosen.contains(p.a),
                        secondary: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [_thumb(p.a), const SizedBox(width: 4), _thumb(p.b)],
                        ),
                        title: Text(widget.lang == 'en' && p.en.isNotEmpty ? p.en : p.ka),
                        subtitle: Text(s.f('cards_level', [p.level])),
                        onChanged: (v) => _toggle(p, v!),
                      ),
                    const Center(child: CardsCredit()),
                  ],
                ),
              ),
            ),
    );
  }
}
