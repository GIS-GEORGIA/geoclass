import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'cards.dart';
import 'l10n.dart';
import 'mapping.dart' show formatClock;
import 'models.dart';
import 'queue.dart';

const _wrongShownFor = Duration(milliseconds: 900);

/// The student's side of the cards game: find the cards that show the same place.
class CardsPlay extends StatefulWidget {
  final S s;
  final String token;
  final Map<String, dynamic> settings;
  final int now; // the server's clock, from the same reply as settings
  final Api api;
  final ValueChanged<String> onStopped; // the session was paused or closed while playing
  const CardsPlay({
    super.key,
    required this.s,
    required this.token,
    required this.settings,
    required this.now,
    required this.api,
    required this.onStopped,
  });
  @override
  State<CardsPlay> createState() => _CardsPlayState();
}

class _CardsPlayState extends State<CardsPlay> {
  late Map<String, dynamic> _settings = widget.settings;
  late Deck _deck = Deck.fromSettings(widget.settings);
  late int _clockOffset = widget.now - deviceSeconds();
  Timer? _poll, _tick, _retry, _wrongTimer;
  String _participant = '';
  bool _loaded = false;
  bool _sending = false;

  // The student's own table: nobody can copy from a neighbour's screen.
  List<DeckCard> _cards = const [];
  final _found = <int>{}; // pairs
  var _mistakes = 0;
  final _pending = <Map<String, dynamic>>[]; // tries the server hasn't got yet
  final _selected = <int>[]; // positions on the table
  List<int> _wrong = const [];

  S get s => widget.s;
  String get _storeKey => 'cards_${widget.token}';
  int? get _endsAt => _settings['endsAt'] as int?;
  int get _resetAt => _settings['resetAt'] as int? ?? 0;
  int get _left => (_endsAt ?? 0) - (deviceSeconds() + _clockOffset);
  bool get _running => _endsAt != null && _left > 0;
  bool get _done => _deck.pairs.isNotEmpty && _found.length == _deck.pairs.length;

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _endsAt != null && _left > -2) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    _retry?.cancel();
    _wrongTimer?.cancel();
    super.dispose();
  }

  List<DeckCard> _canonical() => [
    for (final (i, p) in _deck.pairs.indexed) ...[DeckCard(i, 0, p.a, p.ra), DeckCard(i, 1, p.b, p.rb)],
  ];

  // Reopening the link keeps the table and what was found, until the teacher clears the session.
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _participant = await participantId();
    final canonical = _canonical();
    final saved = prefs.getString(_storeKey);
    if (saved != null) {
      final data = jsonDecode(saved) as Map<String, dynamic>;
      final order = (data['order'] as List?)?.cast<int>();
      if (data['resetAt'] == _resetAt &&
          order != null &&
          order.length == canonical.length &&
          order.every((i) => i >= 0 && i < canonical.length)) {
        _cards = [for (final i in order) canonical[i]];
        _found.addAll((data['found'] as List).cast<int>());
        _mistakes = data['mistakes'] as int;
        _pending.addAll((data['pending'] as List).cast<Map<String, dynamic>>());
      }
    }
    if (_cards.isEmpty) _cards = dealCards(_deck, Random());
    if (!mounted) return;
    setState(() => _loaded = true);
    await _save();
    _send();
    _refresh();
  }

  Future<void> _save() async {
    final canonical = _canonical();
    final order = [for (final c in _cards) canonical.indexWhere((x) => x.pair == c.pair && x.side == c.side)];
    await (await SharedPreferences.getInstance()).setString(
      _storeKey,
      jsonEncode({
        'resetAt': _resetAt,
        'order': order,
        'found': _found.toList(),
        'mistakes': _mistakes,
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
        if ((settings['resetAt'] as int? ?? 0) != _resetAt) {
          _found.clear();
          _pending.clear();
          _selected.clear();
          _wrong = const [];
          _mistakes = 0;
          _cards = dealCards(Deck.fromSettings(settings), Random());
        }
        _settings = settings;
        _deck = Deck.fromSettings(settings);
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

  /// Sends in the order played. A try the server refuses is dropped: it can't be played again.
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
          'answer': {
            for (final k in const ['ok', 'pair', 'x', 'y'])
              if (item.containsKey(k)) k: item[k],
          },
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

  void _tap(int position) {
    final taken = _selected.contains(position) || _found.contains(_cards[position].pair);
    if (!_running || _wrong.isNotEmpty || taken) return;
    if (_selected.isEmpty) {
      setState(() => _selected.add(position));
      return;
    }
    final first = _cards[_selected.first], second = _cards[position];
    if (first.pair == second.pair) {
      setState(() {
        _selected.clear();
        _found.add(first.pair);
        _pending.add({'id': randomId(), 'ok': true, 'pair': first.pair});
      });
    } else {
      setState(() {
        _wrong = [_selected.first, position];
        _mistakes++;
        _pending.add({'id': randomId(), 'ok': false, 'x': first.pair, 'y': second.pair});
      });
      _wrongTimer = Timer(_wrongShownFor, () {
        if (mounted) {
          setState(() {
            _wrong = const [];
            _selected.clear();
          });
        }
      });
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
        Expanded(child: _table()),
      ],
    );
  }

  Widget _waiting() => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hourglass_top, size: 56),
          const SizedBox(height: 16),
          Text(s['mapping_wait'], textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(s['cards_wait_body'], textAlign: TextAlign.center),
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
            // Georgian words are long: the counters shrink before they would overflow a narrow phone.
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
                      Text(s.f('cards_found', [_found.length, _deck.pairs.length]), style: theme.textTheme.titleMedium),
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

  Widget _table() {
    final theme = Theme.of(context);
    final message = _done
        ? s['cards_all_found']
        : (!_running ? s.f('cards_final', [_found.length, _deck.pairs.length]) : null);
    return LayoutBuilder(
      builder: (context, box) {
        final columns = _cards.length <= 12 ? (box.maxWidth >= 700 ? 4 : 3) : (box.maxWidth >= 700 ? 6 : 4);
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                if (message != null)
                  Card(
                    color: theme.colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(message, textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(s['cards_hint'], textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
                  ),
                GridView.count(
                  crossAxisCount: columns,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final (i, card) in _cards.indexed)
                      CardTile(
                        card: card,
                        arrow: _deck.showsArrow,
                        selected: _selected.contains(i) && !_wrong.contains(i),
                        found: _found.contains(card.pair),
                        wrong: _wrong.contains(i),
                        onTap: () => _tap(i),
                        onZoom: () => showCardZoom(context, s, card, arrow: _deck.showsArrow),
                      ),
                  ],
                ),
                const Center(child: CardsCredit()),
              ],
            ),
          ),
        );
      },
    );
  }
}
