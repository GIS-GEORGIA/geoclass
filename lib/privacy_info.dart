import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'l10n.dart';

const privacyPoints = ['info_1', 'info_2', 'info_3', 'info_4', 'info_5', 'info_6'];

/// The ⓘ in the top bar: in short, what GeoClass doesn't ask for or collect, with a link to the full policy.
class PrivacyInfoButton extends StatelessWidget {
  final S s;

  /// On a student's page: erases this device's answers in the session. Returns how many were deleted.
  final Future<int> Function()? onForget;
  const PrivacyInfoButton({super.key, required this.s, this.onForget});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: s['info_title'],
    icon: const Icon(Icons.info_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => PrivacyInfoDialog(s: s, onForget: onForget),
    ),
  );
}

class PrivacyInfoDialog extends StatelessWidget {
  final S s;
  final Future<int> Function()? onForget;
  const PrivacyInfoDialog({super.key, required this.s, this.onForget});

  Future<void> _forget(BuildContext context) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['forget_title']),
        content: Text(s['forget_body']),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s['forget_do']),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final n = await onForget!();
      if (context.mounted) Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(s.f('forget_done', [n]))));
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(s.f('failed', [s[e.key]]))));
    } on NoConnection {
      messenger.showSnackBar(SnackBar(content: Text(s.f('failed', [s['no_connection']]))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      icon: Icon(Icons.shield_outlined, color: Theme.of(context).colorScheme.primary),
      title: Text(s['info_title']),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s['info_intro'], style: text.titleSmall),
              const SizedBox(height: 12),
              for (final k in privacyPoints)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1, right: 8),
                        child: Icon(Icons.check_circle_outline, size: 18),
                      ),
                      Expanded(child: Text(s[k])),
                    ],
                  ),
                ),
              Text(s['info_technical'], style: text.bodySmall),
              if (onForget != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _forget(context),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(s['forget_title']),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => launchUrl(Uri.parse('$publicUrl/privacy/')), child: Text(s['privacy'])),
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(s['close'])),
      ],
    );
  }
}
