import 'dart:math';

import 'package:flutter/material.dart';

import 'answer_mode.dart';
import 'api.dart';
import 'l10n.dart';
import 'models.dart';
import 'photos.dart';

const _maxTasks = 30;

CoordTask taskFromPhoto(Photo p) => CoordTask(lat: p.lat, lon: p.lon, mode: 'photo', format: 'dd', label: p.ka, labelEn: p.en, photo: p.file);

/// The teacher picks which photos the class guesses. Returns the tasks in a random order, and whether the
/// answers are checked on the students' devices (offline) instead of the server.
class AerialSetupPage extends StatefulWidget {
  final S s;
  final String lang;
  const AerialSetupPage({super.key, required this.s, required this.lang});
  @override
  State<AerialSetupPage> createState() => _AerialSetupPageState();
}

class _AerialSetupPageState extends State<AerialSetupPage> {
  List<Photo>? _photos;
  bool _failed = false;
  Set<String> _chosen = {};
  bool _offline = false;

  S get s => widget.s;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final photos = await loadPhotos();
      if (mounted) {
        setState(() {
          _photos = photos;
          _chosen = {for (final p in photos.take(_maxTasks)) p.file};
        });
      }
    } on NoConnection {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _pickRandom() {
    final pool = [..._photos!]..shuffle();
    setState(() => _chosen = {for (final p in pool.take(5)) p.file});
  }

  void _toggle(Photo p, bool on) {
    if (on && _chosen.length >= _maxTasks) return;
    setState(() => on ? _chosen.add(p.file) : _chosen.remove(p.file));
  }

  void _finish() {
    final tasks = [
      for (final p in _photos!)
        if (_chosen.contains(p.file)) taskFromPhoto(p),
    ]..shuffle(Random());
    Navigator.pop(context, (tasks, _offline));
  }

  Widget _message(String text) => Center(
        child: Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center)),
      );

  @override
  Widget build(BuildContext context) {
    final photos = _photos;
    return Scaffold(
      appBar: AppBar(
        title: Text(s['setup_photos']),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _chosen.isEmpty ? null : _finish, child: Text(s['create'])),
          ),
        ],
      ),
      body: _failed
          ? Center(child: FilledButton(onPressed: _load, child: Text(s['retry'])))
          : photos == null
              ? const Center(child: CircularProgressIndicator())
              : photos.isEmpty
                  ? _message(s['aerial_none'])
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text(s.f('setup_chosen', [_chosen.length, photos.length]))),
                                OutlinedButton.icon(
                                  onPressed: _pickRandom,
                                  icon: const Icon(Icons.casino),
                                  label: Text(s['setup_random_photos']),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            OfflineAnswersSwitch(s: s, value: _offline, onChanged: (v) => setState(() => _offline = v)),
                            const SizedBox(height: 8),
                            for (final p in photos)
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: _chosen.contains(p.file),
                                secondary: SizedBox(width: 96, child: TaskPhoto(s: s, file: p.file, height: 64)),
                                title: Text(widget.lang == 'en' && p.en.isNotEmpty ? p.en : p.ka),
                                onChanged: (v) => _toggle(p, v!),
                              ),
                          ],
                        ),
                      ),
                    ),
    );
  }
}
