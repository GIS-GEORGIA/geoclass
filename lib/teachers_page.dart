import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'l10n.dart';
import 'settings.dart';

/// A date as the app shows it: 2026-12-31.
String dayOf(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
}

class Teacher {
  final String id, name;
  final int createdAt, expiresAt, sessions;
  final int? revokedAt;
  final bool active;
  const Teacher(this.id, this.name, this.createdAt, this.expiresAt, this.revokedAt, this.active, this.sessions);

  factory Teacher.fromJson(Map<String, dynamic> j) => Teacher(
    j['id'] as String,
    j['name'] as String,
    j['createdAt'] as int,
    j['expiresAt'] as int,
    j['revokedAt'] as int?,
    j['active'] as bool,
    j['sessions'] as int? ?? 0,
  );
}

/// The message the owner sends a new teacher, in both languages, with the key and how long it works.
String keyMessage(String name, String key, int expiresAt, String url) =>
    'გამარჯობა, $name!\n'
    'შენი GeoClass მასწავლებლის გასაღები: $key\n'
    'შედი $url-ზე, ჩაწერე გასაღები და დააჭირე „შესვლას“. გასაღები მოქმედებს ${dayOf(expiresAt)}-მდე. '
    'ნუ გაუზიარებ სხვას: ვისაც ის აქვს, შენს სესიებს ხედავს.\n'
    '\n'
    'Hello, $name!\n'
    'Your GeoClass teacher key: $key\n'
    'Open $url, enter the key and press "Sign in". The key works until ${dayOf(expiresAt)}. '
    'Do not share it: whoever has it sees your sessions.';

/// The owner's list of teachers: add one with a validity, see until when each works, revoke or extend.
class TeachersPage extends StatefulWidget {
  final Settings settings;
  const TeachersPage({super.key, required this.settings});
  @override
  State<TeachersPage> createState() => _TeachersPageState();
}

class _TeachersPageState extends State<TeachersPage> {
  List<Teacher>? _teachers;
  String? _error;

  S get s => widget.settings.s;
  Api get _api => Api(teacherKey: widget.settings.teacherKey);

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _problem(Object e) => s.f('failed', [e is ApiError ? s[e.key] : s['no_connection']]);

  Future<void> _load() async {
    try {
      final list = await _api.teachers();
      if (mounted) {
        setState(() {
          _teachers = list.map(Teacher.fromJson).toList();
          _error = null;
        });
      }
    } on Exception catch (e) {
      if (mounted) setState(() => _error = _problem(e));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await _load();
    } on Exception catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_problem(e))));
    }
  }

  Future<void> _add() async {
    final picked = await showDialog<(String, int, String)>(
      context: context,
      builder: (_) => ValidityDialog(s: s, askName: true),
    );
    if (picked == null) return;
    await _run(() async {
      final (teacher, key) = await _api.createTeacher(picked.$1, picked.$2, picked.$3);
      if (mounted) await _showKey(Teacher.fromJson(teacher), key);
    });
  }

  Future<void> _showKey(Teacher t, String key) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final message = keyMessage(t.name, key, t.expiresAt, publicUrl);
      Future<void> copy(String text) async {
        await Clipboard.setData(ClipboardData(text: text));
        if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(s['cite_copied'])));
      }

      return AlertDialog(
        title: Text(s.f('teacher_key_for', [t.name])),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s['teacher_key_once']),
                const SizedBox(height: 12),
                SelectableText(key, style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 16),
                Text(s['teacher_message'], style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(message),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(onPressed: () => copy(key), icon: const Icon(Icons.key), label: Text(s['teacher_copy_key'])),
          TextButton.icon(
            onPressed: () => copy(message),
            icon: const Icon(Icons.copy),
            label: Text(s['teacher_copy_message']),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s['close'])),
        ],
      );
    },
  );

  Future<void> _extend(Teacher t) async {
    final picked = await showDialog<(String, int, String)>(
      context: context,
      builder: (_) => ValidityDialog(s: s, askName: false),
    );
    if (picked == null) return;
    await _run(() => _api.updateTeacher(t.id, {'amount': picked.$2, 'unit': picked.$3}));
  }

  String _state(Teacher t) {
    if (t.revokedAt != null) return s['teacher_revoked'];
    if (!t.active) return s.f('teacher_expired', [dayOf(t.expiresAt)]);
    return s.f('teacher_until', [dayOf(t.expiresAt)]);
  }

  @override
  Widget build(BuildContext context) {
    final teachers = _teachers;
    return Scaffold(
      appBar: AppBar(title: Text(s['teachers'])),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add),
        label: Text(s['teacher_add']),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _error != null
              ? Center(child: Text(_error!))
              : teachers == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  children: [
                    Text(s['teachers_note'], style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    if (teachers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(child: Text(s['teachers_none'])),
                      ),
                    for (final t in teachers)
                      Card(
                        child: ListTile(
                          leading: Icon(t.active ? Icons.person : Icons.person_off),
                          title: Text(t.name),
                          subtitle: Text('${_state(t)} · ${s.f('teacher_sessions', [t.sessions])}'),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => switch (v) {
                              'extend' => _extend(t),
                              'revoke' => _run(() => _api.updateTeacher(t.id, {'revoked': true})),
                              _ => _run(() => _api.updateTeacher(t.id, {'revoked': false})),
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(value: 'extend', child: Text(s['teacher_extend'])),
                              if (t.revokedAt == null)
                                PopupMenuItem(value: 'revoke', child: Text(s['teacher_revoke']))
                              else
                                PopupMenuItem(value: 'restore', child: Text(s['teacher_unrevoke'])),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Asks for how long a key works (a number of days, months or years) and, for a new teacher, their name.
/// Returns (name, amount, unit).
class ValidityDialog extends StatefulWidget {
  final S s;
  final bool askName;
  const ValidityDialog({super.key, required this.s, required this.askName});
  @override
  State<ValidityDialog> createState() => _ValidityDialogState();
}

class _ValidityDialogState extends State<ValidityDialog> {
  final _name = TextEditingController();
  final _amount = TextEditingController(text: '30');
  String _unit = 'day';

  S get s => widget.s;

  int? get _number {
    final n = int.tryParse(_amount.text.trim());
    final max = switch (_unit) {
      'day' => 1825,
      'month' => 60,
      _ => 5,
    };
    return n != null && n >= 1 && n <= max ? n : null;
  }

  bool get _ok => _number != null && (!widget.askName || _name.text.trim().isNotEmpty);

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.askName ? s['teacher_add'] : s['teacher_extend']),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.askName) ...[
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 100,
              decoration: InputDecoration(labelText: s['teacher_name'], border: const OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(labelText: s['teacher_valid_for'], border: const OutlineInputBorder()),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _unit,
                items: [
                  for (final u in const ['day', 'month', 'year']) DropdownMenuItem(value: u, child: Text(s['unit_$u'])),
                ],
                onChanged: (v) => setState(() => _unit = v ?? 'day'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(s['teacher_valid_note'], style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(s['cancel'])),
      FilledButton(
        onPressed: _ok ? () => Navigator.pop(context, (_name.text.trim(), _number!, _unit)) : null,
        child: Text(widget.askName ? s['create'] : s['save']),
      ),
    ],
  );
}
