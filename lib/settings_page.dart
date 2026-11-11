import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'citation.dart';
import 'files.dart';
import 'l10n.dart';
import 'settings.dart';

class SettingsPage extends StatefulWidget {
  final Settings settings;

  /// Students see language, theme and project info only.
  final bool teacherTools;
  const SettingsPage({super.key, required this.settings, required this.teacherTools});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Settings get settings => widget.settings;
  S get s => settings.s;
  Api get _api => Api(teacherKey: settings.teacherKey);

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _problem(Object e) => s.f('failed', [e is ApiError ? s[e.key] : s['no_connection']]);

  Future<void> _backup() async {
    try {
      await saveJsonBackup(await _api.backup(), 'all');
      if (mounted) _say(s['saved']);
    } on Exception catch (e) {
      if (mounted) _say(_problem(e));
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['json']);
    final bytes = await picked?.xFile.readAsBytes();
    if (bytes == null || !mounted) return;

    Map<String, dynamic> file;
    try {
      file = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (file['format'] != 'geoclass-backup') throw const FormatException();
    } on Exception catch (_) {
      _say(s['restore_bad']);
      return;
    } on TypeError catch (_) {
      _say(s['restore_bad']);
      return;
    }

    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s['restore']),
        content: Text(s.f('restore_confirm', [(file['sessions'] as List?)?.length ?? 0, (file['responses'] as List?)?.length ?? 0])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s['cancel'])),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s['restore'])),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await _api.restore(file);
      if (mounted) _say(s['restore_done']);
    } on ApiError catch (e) {
      if (mounted) _say(e.key == 'bad_backup' ? s['restore_bad'] : _problem(e));
    } on NoConnection catch (e) {
      if (mounted) _say(_problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: settings,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(s['settings'])),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _title(s['language']),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'ka', label: Text('ქართული')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {settings.lang},
                    onSelectionChanged: (v) => settings.setLang(v.first),
                  ),
                  _title(s['theme']),
                  SegmentedButton<ThemeMode>(
                    segments: [
                      ButtonSegment(value: ThemeMode.system, label: Text(s['theme_system'])),
                      ButtonSegment(value: ThemeMode.light, label: Text(s['theme_light'])),
                      ButtonSegment(value: ThemeMode.dark, label: Text(s['theme_dark'])),
                    ],
                    selected: {settings.theme},
                    onSelectionChanged: (v) => settings.setTheme(v.first),
                  ),
                  if (widget.teacherTools) ...[
                    _title(s['data']),
                    Text(s['backup_note']),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.download),
                      title: Text(s['backup_all']),
                      onTap: _backup,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.upload),
                      title: Text(s['restore']),
                      onTap: _restore,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.logout),
                      title: Text(s['sign_out']),
                      onTap: () async {
                        await settings.setTeacherKey(null);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  ],
                  _title(s['about']),
                  Text(s['about_text']),
                  const SizedBox(height: 8),
                  Text(s['about_author'], style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.format_quote),
                    title: Text(s['cite_title']),
                    onTap: () => showCitation(context, s),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.privacy_tip_outlined),
                    title: Text(s['privacy']),
                    onTap: () => launchUrl(Uri.parse('$publicUrl/privacy/')),
                  ),
                  const SizedBox(height: 8),
                  Text(s['credits'], style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 24),
                  GithubCard(s: s),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _title(String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );
}

/// The link to the code, at the bottom of the settings, with a playing cat.
class GithubCard extends StatelessWidget {
  final S s;
  const GithubCard({super.key, required this.s});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(githubUrl)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            children: [
              SizedBox(
                width: 260,
                height: 111, // the animation is 1070 × 456
                child: Lottie.asset(
                  'assets/lottie/playing_cat.json',
                  // A still cat instead of nothing, where the animation can't load.
                  errorBuilder: (_, _, _) => Icon(Icons.pets, size: 64, color: theme.colorScheme.primary),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.code, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text(s['github'], style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                githubUrl.replaceFirst('https://', ''),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
