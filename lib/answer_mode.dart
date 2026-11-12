import 'package:flutter/material.dart';

import 'l10n.dart';

/// The teacher's choice for games with a right answer: checked on the server (the default), or on the
/// student's device so the game works without internet, at the cost of the answers being on that device.
class OfflineAnswersSwitch extends StatelessWidget {
  final S s;
  final bool value;
  final ValueChanged<bool> onChanged;
  const OfflineAnswersSwitch({super.key, required this.s, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Card(
    child: SwitchListTile(
      secondary: Icon(value ? Icons.cloud_off : Icons.lock_outline),
      title: Text(s['answers_offline']),
      subtitle: Text(s[value ? 'answers_offline_on' : 'answers_offline_off']),
      value: value,
      onChanged: onChanged,
    ),
  );
}
