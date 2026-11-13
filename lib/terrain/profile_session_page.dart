import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../coordinates_session_page.dart' show scoreColor;
import '../export.dart' show LeaderRow;
import '../nicknames.dart';
import '../session_base.dart';
import 'profile_game.dart';

/// One student's answer to one question, as the teacher's list of responses gives it.
class ProfileAnswer {
  final String participantId, kind;
  final int round, score, createdAt;
  final double value;
  const ProfileAnswer(this.participantId, this.round, this.kind, this.value, this.score, this.createdAt);

  factory ProfileAnswer.fromJson(Map<String, dynamic> j) {
    final a = j['answer'] as Map<String, dynamic>;
    return ProfileAnswer(
      j['participantId'] as String,
      j['round'] as int,
      a['kind'] as String,
      (a['value'] as num).toDouble(),
      (j['score'] as num?)?.toInt() ?? 0,
      (j['createdAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Highest total first; with equal totals, fewer answers first (as in the coordinates game).
List<LeaderRow> profileLeaderboard(List<ProfileAnswer> answers) {
  final score = <String, int>{}, count = <String, int>{};
  for (final a in answers) {
    score[a.participantId] = (score[a.participantId] ?? 0) + a.score;
    count[a.participantId] = (count[a.participantId] ?? 0) + 1;
  }
  return [for (final id in score.keys) LeaderRow(id, score[id]!, count[id]!)]..sort((x, y) {
    final byScore = y.score.compareTo(x.score);
    return byScore != 0 ? byScore : x.answered.compareTo(y.answered);
  });
}

String _csv(String v) => '"${v.replaceAll('"', '""')}"';

/// One row per answer: who, which question, what they said, the right answer and the score.
String profileAnswersToCsv(List<ProfileAnswer> answers, List<ProfileQuestion> questions, String lang) {
  final out = StringBuffer('﻿nickname,question,kind,answer,right_answer,score,created_at\r\n');
  for (final a in answers) {
    final q = a.round < questions.length ? questions[a.round] : null;
    out.write(
      [
        _csv(nickname(a.participantId, lang)),
        a.round + 1,
        a.kind,
        a.kind == 'steepest' ? a.value.round() + 1 : a.value,
        q?.answer == null ? '' : (a.kind == 'steepest' ? q!.answer!.round() + 1 : q!.answer),
        a.score,
        DateTime.fromMillisecondsSinceEpoch(a.createdAt * 1000, isUtc: true).toIso8601String(),
      ].join(','),
    );
    out.write('\r\n');
  }
  return out.toString();
}

/// The line, with the questions and their right answers as its properties. Answers have no place of their own.
String profileToGeoJson(ProfileGameSettings settings) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'geometry': {
        'type': 'LineString',
        'coordinates': [
          for (final p in settings.line) [p.longitude, p.latitude],
        ],
      },
      'properties': {
        'area': settings.areaId,
        'area_version': settings.areaVersion,
        'length_m': settings.length,
        'questions': [for (final q in settings.questions) q.toJson()],
      },
    },
  ],
});

/// The teacher's page for a terrain profile session: the line on the map, the leaderboard, and each question
/// with its right answer and how the class did.
class ProfileSessionPage extends SessionPageBase {
  const ProfileSessionPage({super.key, required super.settings, required super.session, super.showQrOnOpen});
  @override
  State<ProfileSessionPage> createState() => _ProfileSessionPageState();
}

class _ProfileSessionPageState extends SessionPageState<ProfileSessionPage> {
  List<ProfileAnswer> _answers = const [];
  bool _showQuestions = false;

  ProfileGameSettings? get _settings {
    try {
      return ProfileGameSettings.fromJson(session.settings);
    } on FormatException {
      return null;
    }
  }

  @override
  void onRows(List<Map<String, dynamic>> rows) => _answers = [for (final r in rows) ProfileAnswer.fromJson(r)];

  @override
  List<LatLng> get fitPoints => _settings?.line ?? const [];
  @override
  double get fitMaxZoom => 14;
  @override
  int get answerCount => _answers.length;
  @override
  int get shownCount => _answers.length;
  @override
  String exportCsv() => profileAnswersToCsv(_answers, _settings?.questions ?? const [], lang);
  @override
  String exportGeoJson() {
    final settings = _settings;
    return settings == null ? '{"type":"FeatureCollection","features":[]}' : profileToGeoJson(settings);
  }

  @override
  List<Widget> mapLayers() {
    final settings = _settings;
    return settings == null ? const [] : profileLineLayers(settings.line, Theme.of(context).colorScheme);
  }

  @override
  List<Widget> mapOverlays() => const [];

  @override
  Widget panel() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, label: Text(s['leaderboard'])),
            ButtonSegment(value: true, label: Text(s['profile_questions'])),
          ],
          selected: {_showQuestions},
          onSelectionChanged: (v) => setState(() => _showQuestions = v.first),
        ),
      ),
      Expanded(child: _showQuestions ? _questionList() : _leaderboard()),
    ],
  );

  Widget _leaderboard() {
    final rows = profileLeaderboard(_answers);
    if (rows.isEmpty) return Center(child: Text(s['no_results']));
    final total = _settings?.questions.length ?? 0;
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (_, i) {
        final r = rows[i];
        return ListTile(
          leading: CircleAvatar(child: Text('${i + 1}')),
          title: Text(nickname(r.participantId, lang)),
          subtitle: Text(s.f('profile_answered_of', [r.answered, total])),
          trailing: Text(s.f('points', [r.score]), style: Theme.of(context).textTheme.titleSmall),
        );
      },
    );
  }

  Widget _questionList() {
    final questions = _settings?.questions ?? const [];
    return ListView.builder(
      itemCount: questions.length,
      itemBuilder: (_, i) {
        final q = questions[i];
        final answers = _answers.where((a) => a.round == i).toList();
        final average = answers.isEmpty
            ? null
            : (answers.map((a) => a.score).reduce((x, y) => x + y) / answers.length).round();
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: average == null ? null : scoreColor(average),
            foregroundColor: average == null ? null : Colors.white,
            child: Text('${i + 1}'),
          ),
          title: Text(q.title(s)),
          subtitle: Text(
            [
              if (q.answer != null) s.f('profile_right', [profileValue(q.kind, q.answer!, s)]),
              s.f('profile_question_stats', [answers.length, average ?? '–']),
            ].join('\n'),
          ),
          isThreeLine: true,
        );
      },
    );
  }
}
