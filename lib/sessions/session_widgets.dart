import 'package:flutter/material.dart';

import '../games/registry.dart';
import '../l10n.dart';
import '../models.dart';
import '../teachers_page.dart' show dayOf;
import 'session_filters.dart';

/// A game's title, from its module or the strings of the games not moved to modules yet.
String gameTitle(S s, String game) => gameModule(game)?.title(s) ?? s['game_$game'];

/// A colour of a game's own, the same every time: no game has a cover picture, so its icon on this colour
/// stands for it. Picked from the game's id, so a new game gets one without a list to keep up.
Color gameColour(String game, Brightness brightness) {
  var h = 0;
  for (final c in game.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.55, brightness == Brightness.dark ? 0.62 : 0.42).toColor();
}

/// A small square for a game: its icon on its colour, rounded.
class GameCover extends StatelessWidget {
  final String game;
  final double size;
  const GameCover({super.key, required this.game, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final colour = gameColour(game, Theme.of(context).brightness);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size / 4),
        border: Border.all(color: colour.withValues(alpha: 0.45)),
      ),
      child: Icon(gameIcon(game), color: colour, size: size * 0.55),
    );
  }
}

/// A session's status as a small coloured label: open green, paused amber, closed grey.
class StatusBadge extends StatelessWidget {
  final S s;
  final String status;
  const StatusBadge({super.key, required this.s, required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colour = switch (status) {
      'open' => dark ? Colors.greenAccent.shade400 : Colors.green.shade700,
      'paused' => dark ? Colors.amber.shade300 : Colors.orange.shade800,
      _ => scheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: colour),
          const SizedBox(width: 4),
          Text(
            s['status_$status'],
            style: TextStyle(fontSize: 12, color: colour, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

enum SessionAction { open, qr, delete }

/// One session in the list's grid: the game, the name, who made it and when, its status, an Open button and a
/// menu. Every card is the same height ([sessionCardHeight]).
const sessionCardHeight = 132.0;

class SessionCard extends StatelessWidget {
  final S s;
  final SessionInfo session;
  final ValueChanged<SessionAction> onAction;
  const SessionCard({super.key, required this.s, required this.session, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final x = session;
    return Card(
      key: Key('session_card_${x.id}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onAction(SessionAction.open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GameCover(game: x.game, size: 44),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          x.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(gameTitle(s, x.game), maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                        Text(
                          [
                            x.teacherName == null ? s['creator_me'] : s.f('session_by', [x.teacherName!]),
                            if (x.createdAt > 0) dayOf(x.createdAt),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<SessionAction>(
                    key: Key('session_menu_${x.id}'),
                    tooltip: s['session_actions'],
                    icon: const Icon(Icons.more_vert),
                    onSelected: onAction,
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: SessionAction.open,
                        child: ListTile(leading: const Icon(Icons.open_in_new), title: Text(s['session_open'])),
                      ),
                      PopupMenuItem(
                        value: SessionAction.qr,
                        child: ListTile(leading: const Icon(Icons.qr_code), title: Text(s['session_show_qr'])),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        key: const Key('session_delete'),
                        value: SessionAction.delete,
                        child: ListTile(
                          leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                          title: Text(s['delete_session'], style: TextStyle(color: theme.colorScheme.error)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    StatusBadge(s: s, status: x.status),
                    const SizedBox(width: 6),
                    if (x.archived)
                      Text(s['archived'], style: muted)
                    else
                      Flexible(
                        child: Text(
                          s.f('answers_count', [x.responses ?? 0]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: muted,
                        ),
                      ),
                    const Spacer(),
                    FilledButton.tonal(
                      key: Key('session_open_${x.id}'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: () => onAction(SessionAction.open),
                      child: Text(s['session_open']),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The filters above the grid: search, status, who made it (only when there is more than one), order, reset.
class SessionToolbar extends StatelessWidget {
  final S s;
  final SessionFilter filter;
  final List<String> creators;
  final TextEditingController search;
  final ValueChanged<SessionFilter> onChanged;
  const SessionToolbar({
    super.key,
    required this.s,
    required this.filter,
    required this.creators,
    required this.search,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final f = filter;
    final dense = const InputDecoration(isDense: true, border: OutlineInputBorder());
    String creatorLabel(String c) => c == mine ? s['creator_me'] : c;
    // On a phone the four status words don't fit side by side: a drop-down there instead.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 260,
          child: TextField(
            key: const Key('session_search'),
            controller: search,
            decoration: dense.copyWith(
              hintText: s['search_sessions'],
              prefixIcon: const Icon(Icons.search, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 36),
            ),
            onChanged: (v) => onChanged(f.copyWith(query: v)),
          ),
        ),
        if (narrow)
          _dropdown<String>(
            key: const Key('session_status'),
            width: 170,
            label: s['filter_status'],
            value: f.status ?? 'all',
            items: {
              'all': s['filter_all'],
              for (final st in const ['open', 'paused', 'closed']) st: s['status_$st'],
            },
            onChanged: (v) => onChanged(f.copyWith(status: () => v == 'all' ? null : v)),
          )
        else
          SegmentedButton<String>(
            key: const Key('session_status'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              ButtonSegment(value: 'all', label: Text(s['filter_all'])),
              for (final st in const ['open', 'paused', 'closed'])
                ButtonSegment(value: st, label: Text(s['status_$st'])),
            ],
            selected: {f.status ?? 'all'},
            onSelectionChanged: (v) => onChanged(f.copyWith(status: () => v.first == 'all' ? null : v.first)),
          ),
        if (creators.length > 1)
          _dropdown<String>(
            key: const Key('session_creator'),
            width: 200,
            label: s['filter_creator'],
            value: f.creator ?? '*',
            items: {'*': s['filter_everyone'], for (final c in creators) c: creatorLabel(c)},
            onChanged: (v) => onChanged(f.copyWith(creator: () => v == '*' ? null : v)),
          ),
        _dropdown<SessionSort>(
          key: const Key('session_sort'),
          width: 170,
          label: s['sort'],
          value: f.sort,
          items: {for (final o in SessionSort.values) o: s['sort_${o.name}']},
          onChanged: (v) => onChanged(f.copyWith(sort: v)),
        ),
        TextButton.icon(
          key: const Key('session_reset'),
          onPressed: f.isFiltered
              ? () {
                  search.clear();
                  onChanged(f.reset());
                }
              : null,
          icon: const Icon(Icons.filter_alt_off, size: 18),
          label: Text(s['filter_reset']),
        ),
      ],
    );
  }

  /// A labelled drop-down that shows [value] as given, so resetting the filters shows at once.
  static Widget _dropdown<T>({
    required Key key,
    required double width,
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T> onChanged,
  }) => SizedBox(
    width: width,
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: key,
          value: value,
          isDense: true,
          isExpanded: true,
          items: [for (final e in items.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    ),
  );
}
