import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'l10n.dart';
import 'plates.dart';

const _follow = Duration(seconds: 3);

/// The student's side of the plates game: the plate the teacher shows, on the student's own screen.
/// Nothing is sent: the class says the answer aloud.
class PlatesPlay extends StatefulWidget {
  final S s;
  final String lang;
  final String token;
  final Map<String, dynamic> settings;
  final Api api;
  final ValueChanged<String> onStopped; // the session was paused or closed
  final List<PlateShape>? shapes; // for tests
  const PlatesPlay({
    super.key,
    required this.s,
    required this.lang,
    required this.token,
    required this.settings,
    required this.api,
    required this.onStopped,
    this.shapes,
  });
  @override
  State<PlatesPlay> createState() => _PlatesPlayState();
}

class _PlatesPlayState extends State<PlatesPlay> with WidgetsBindingObserver {
  late Map<String, dynamic> _settings = widget.settings;
  List<PlateShape>? _shapes;
  final _cache = PlateCache();
  Timer? _poll;
  bool _visible = true;
  bool _noticeRead = false;

  S get s => widget.s;
  PlateSpec? get _plate {
    final p = _settings['plate'];
    return p is Map<String, dynamic> ? PlateSpec.fromJson(p) : null;
  }

  int get _at => _settings['at'] as int? ?? 0;
  int get _count => _settings['count'] as int? ?? 0;
  bool get _revealed => _settings['revealed'] as bool? ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shapes = widget.shapes;
    _noticeRead = _at > 0;
    if (_shapes == null) {
      loadPlateShapes().then((shapes) {
        if (mounted) setState(() => _shapes = shapes);
      });
    }
    _schedule();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  // A phone in a pocket doesn't keep asking.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
    if (visible == _visible) return;
    _visible = visible;
    _poll?.cancel();
    if (visible) _refresh();
  }

  void _schedule() {
    _poll?.cancel();
    if (mounted && _visible) _poll = Timer(_follow, _refresh);
  }

  Future<void> _refresh() async {
    try {
      final data = await widget.api.join(widget.token);
      if (!mounted) return;
      final status = data['status'] as String;
      if (status != 'open') {
        widget.onStopped(status);
        return;
      }
      setState(() => _settings = data['settings'] as Map<String, dynamic>? ?? const {});
    } on Exception {
      // No connection for a moment: the plate on screen stays, and the next try follows.
    }
    _schedule();
  }

  @override
  Widget build(BuildContext context) {
    final shapes = _shapes;
    if (shapes == null) return const Center(child: CircularProgressIndicator());
    if (!_noticeRead) {
      return platesNotice(
        context,
        (k) => s[k],
        note: s['plates_notice_student'],
        actions: [
          FilledButton(
            onPressed: () => setState(() => _noticeRead = true),
            child: Padding(padding: const EdgeInsets.all(8), child: Text(s['plates_understood'])),
          ),
        ],
      );
    }
    final plate = _plate;
    if (plate == null) return platesEnd(context, (k) => s[k]);
    final shape = shapes.where((x) => x.id == plate.shape).firstOrNull;
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('${_at + 1} / $_count', style: text.titleMedium),
        ),
        Expanded(
          child: PlateView(
            dots: _cache.dots(plate, shapes),
            revealed: _revealed,
            question: s['plates_question'],
            answer: shape?.label(widget.lang) ?? '?',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(s['plates_follow'], textAlign: TextAlign.center, style: text.bodySmall),
        ),
      ],
    );
  }
}
