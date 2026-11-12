import 'package:flutter/material.dart';

/// A full-screen note on the student page: an icon, a title, an optional text and button.
class StudentMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final VoidCallback? action;
  final String? actionLabel;
  const StudentMessage(this.icon, this.title, {super.key, this.body, this.action, this.actionLabel});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          if (body != null) ...[const SizedBox(height: 8), Text(body!, textAlign: TextAlign.center)],
          if (action != null) ...[
            const SizedBox(height: 24),
            FilledButton(onPressed: action, child: Text(actionLabel!)),
          ],
        ],
      ),
    ),
  );
}
