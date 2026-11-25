import 'package:flutter/material.dart';

import '../games/registry.dart';
import '../l10n.dart';
import 'session_filters.dart';
import 'session_widgets.dart';

/// The first step of a new session: pick a game from the grid, then name the session, with names offered for
/// that game right under it. Returns (game, name); the game's own setup, if any, comes after.
class CreateSessionPage extends StatefulWidget {
  final S s;

  /// How many sessions of each game the teacher has, for the numbered name.
  final Map<String, int> counts;
  const CreateSessionPage({super.key, required this.s, this.counts = const {}});
  @override
  State<CreateSessionPage> createState() => _CreateSessionPageState();
}

class _CreateSessionPageState extends State<CreateSessionPage> {
  final _name = TextEditingController();
  final _nameKey = GlobalKey();
  String? _game;
  bool _touched = false;

  S get s => widget.s;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _game != null && validSessionName(_name.text);

  void _pick(String game) {
    setState(() => _game = game);
    // On a narrow screen the naming part is under the grid: bring it into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _nameKey.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250));
    });
  }

  void _suggest(String name) => setState(() {
    _name.text = name;
    _name.selection = TextSelection.collapsed(offset: name.length);
    _touched = true;
  });

  void _done() {
    if (!_ready) {
      setState(() => _touched = true);
      return;
    }
    Navigator.pop(context, (_game!, _name.text.trim()));
  }

  Widget _gameGrid() {
    final scheme = Theme.of(context).colorScheme;
    // On a phone two tiles side by side cut the longer Georgian titles in the middle of a word: one column there.
    final oneColumn = MediaQuery.sizeOf(context).width < 520;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: oneColumn ? 520 : 240,
        mainAxisExtent: 64,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: pickableGames().length,
      itemBuilder: (context, i) {
        final g = pickableGames()[i];
        final selected = g == _game;
        return Material(
          color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: selected ? scheme.primary : scheme.outlineVariant, width: selected ? 2 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('create_game_$g'),
            onTap: () => _pick(g),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  GameCover(game: g, size: 40),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      gameTitle(s, g),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.normal),
                    ),
                  ),
                  if (selected) Icon(Icons.check_circle, color: scheme.primary, size: 20),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _naming() {
    final game = _game;
    final theme = Theme.of(context);
    if (game == null) {
      return Padding(
        key: _nameKey,
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(s['create_pick_game'], style: theme.textTheme.bodyMedium),
      );
    }
    final empty = _name.text.trim().isEmpty;
    return Column(
      key: _nameKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            GameCover(game: game, size: 36),
            const SizedBox(width: 10),
            Expanded(child: Text(gameTitle(s, game), style: theme.textTheme.titleSmall)),
          ],
        ),
        const SizedBox(height: 12),
        Text(s['create_suggestions'], style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (i, n) in suggestedNames(s, gameTitle(s, game), widget.counts[game] ?? 0).indexed)
              // Not an ActionChip: a chip keeps its label to one line (two only sometimes), and a long game title
              // would hide the part of the name that differs.
              Material(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  key: Key('create_suggestion_$i'),
                  onTap: () => _suggest(n),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    child: Text(n, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('create_name'),
          controller: _name,
          maxLength: maxSessionName,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: s['session_name'],
            hintText: s['session_name_hint'],
            border: const OutlineInputBorder(),
            errorText: _touched && empty ? s['session_name_required'] : null,
            helperText: _touched && empty ? null : s['session_name_help'],
          ),
          onChanged: (_) => setState(() => _touched = true),
          onSubmitted: (_) => _done(),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSetup = _game != null && (gameModule(_game!)?.hasSetup ?? _game != 'mapping');
    return Scaffold(
      appBar: AppBar(title: Text(s['new_session'])),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(s['cancel'])),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('create_submit'),
                onPressed: _ready ? _done : null,
                child: Text(hasSetup ? s['next'] : s['create']),
              ),
            ],
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final grid = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s['create_step_game'], style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _gameGrid(),
            ],
          );
          final naming = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s['create_step_name'], style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _naming(),
            ],
          );
          if (wide) {
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: grid),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 2,
                      child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: naming),
                    ),
                  ],
                ),
              ),
            );
          }
          // Not a lazy ListView: the naming part must exist, far under the games, for _pick to scroll to it.
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [grid, const SizedBox(height: 24), naming],
            ),
          );
        },
      ),
    );
  }
}
