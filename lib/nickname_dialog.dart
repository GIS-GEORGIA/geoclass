import 'package:flutter/material.dart';

import 'l10n.dart';
import 'nicknames.dart';

/// The student picks a made-up name for this session, from suggestions or typed. Returns the new nickname,
/// '' to go back to the automatic one, or null if nothing changed.
class NicknameDialog extends StatefulWidget {
  final S s;
  final String lang;
  final String current;
  const NicknameDialog({super.key, required this.s, required this.lang, required this.current});
  @override
  State<NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<NicknameDialog> {
  final _ctl = TextEditingController();
  late List<String> _suggested = suggestedNicknames(widget.lang);
  String? _error;

  S get s => widget.s;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _save() {
    final clean = cleanNickname(_ctl.text);
    if (clean == null || clean.isEmpty) {
      setState(() => _error = s['nick_bad']);
      return;
    }
    Navigator.pop(context, clean);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(s['nick_title']),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.f('nick_current', [widget.current])),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(s['nick_warning'], style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Text(s['nick_pick'], style: theme.textTheme.titleSmall)),
                  IconButton(
                    tooltip: s['nick_more'],
                    icon: const Icon(Icons.refresh),
                    onPressed: () => setState(() => _suggested = suggestedNicknames(widget.lang)),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final n in _suggested) ActionChip(label: Text(n), onPressed: () => Navigator.pop(context, n)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _ctl,
                maxLength: maxNicknameChars,
                decoration: InputDecoration(
                  labelText: s['nick_own'],
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, ''), child: Text(s['nick_auto'])),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(s['cancel'])),
        FilledButton(onPressed: _save, child: Text(s['nick_save'])),
      ],
    );
  }
}
