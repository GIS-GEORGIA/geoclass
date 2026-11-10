import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'l10n.dart';

const privacyPoints = ['info_1', 'info_2', 'info_3', 'info_4', 'info_5', 'info_6'];

/// The ⓘ in the top bar: in short, what GeoClass doesn't ask for or collect, with a link to the full policy.
class PrivacyInfoButton extends StatelessWidget {
  final S s;
  const PrivacyInfoButton({super.key, required this.s});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: s['info_title'],
    icon: const Icon(Icons.info_outline),
    onPressed: () => showDialog<void>(
      context: context,
      builder: (_) => PrivacyInfoDialog(s: s),
    ),
  );
}

class PrivacyInfoDialog extends StatelessWidget {
  final S s;
  const PrivacyInfoDialog({super.key, required this.s});

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
