import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/api.dart';
import 'package:geoclass/queue.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The offline queue with a fake send function: nothing lost, nothing sent twice, each session on its own.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> answer(String id, [String token = 'token-a']) => {'token': token, 'submissionId': id};

  test('an answer added while others are being sent is not lost', () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final queue = SubmissionQueue('token-a', (item) async {
      if (item['submissionId'] == 'a') await gate.future; // the network is slow for the first one
      sent.add(item['submissionId'] as String);
    });
    await queue.add(answer('a'));
    final flushing = queue.flush();
    await Future<void>.delayed(Duration.zero);
    await queue.add(answer('b')); // the student answers the next task meanwhile
    gate.complete();
    await flushing;
    await queue.flush();
    expect(sent, ['a', 'b']);
    expect(await queue.pending(), 0);
  });

  test('two flushes at once send each answer once, in order', () async {
    final sent = <String>[];
    final queue = SubmissionQueue('token-a', (item) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sent.add(item['submissionId'] as String);
    });
    for (final id in ['a', 'b', 'c']) {
      await queue.add(answer(id));
    }
    // The retry timer and the student's button fire together, from two copies of the queue.
    final other = SubmissionQueue('token-a', queue.send);
    await Future.wait([queue.flush(), other.flush(), queue.flush()]);
    expect(sent, ['a', 'b', 'c']);
    expect(await queue.pending(), 0);
  });

  test('a flush that starts while another runs also sends what was added after the first began', () async {
    final gate = Completer<void>();
    final sent = <String>[];
    final queue = SubmissionQueue('token-a', (item) async {
      if (item['submissionId'] == 'a') await gate.future;
      sent.add(item['submissionId'] as String);
    });
    await queue.add(answer('a'));
    final first = queue.flush();
    await Future<void>.delayed(Duration.zero);
    await queue.add(answer('b'));
    final second = queue.flush();
    gate.complete();
    await Future.wait([first, second]);
    expect(sent, ['a', 'b']);
  });

  test('the same answer added twice is kept and sent once', () async {
    final sent = <String>[];
    final queue = SubmissionQueue('token-a', (item) async => sent.add(item['submissionId'] as String));
    await queue.add(answer('a'));
    await queue.add(answer('a'));
    expect(await queue.pending(), 1);
    await queue.flush();
    expect(sent, ['a']);
  });

  test('each session sends only its own answers', () async {
    final sent = <String>[];
    Future<void> send(Map<String, dynamic> item) async => sent.add(item['submissionId'] as String);
    final a = SubmissionQueue('token-a', send);
    final b = SubmissionQueue('token-b', send);
    await a.add(answer('a1'));
    await b.add(answer('b1', 'token-b'));
    await a.flush();
    expect(sent, ['a1']);
    expect(await b.pending(), 1);
  });

  test('answers in the old shared list move to their own session, once', () async {
    SharedPreferences.setMockInitialValues({
      'pending_submissions': jsonEncode([answer('a1'), answer('b1', 'token-b'), answer('a2')]),
    });
    final sent = <String>[];
    final a = SubmissionQueue('token-a', (item) async => sent.add(item['submissionId'] as String));
    expect(await a.pending(), 2);
    await a.flush();
    expect(sent, ['a1', 'a2']);
    final p = await SharedPreferences.getInstance();
    expect(jsonDecode(p.getString('pending_submissions')!), [answer('b1', 'token-b')]);
    expect(await SubmissionQueue('token-b', (_) async {}).pending(), 1);
    expect(p.getString('pending_submissions'), isNull);
  });

  test('a paused session keeps the answer, and it goes once the session is open again', () async {
    var paused = true;
    final sent = <String>[];
    final queue = SubmissionQueue('token-a', (item) async {
      if (paused) throw ApiError(409, 'session_paused');
      sent.add(item['submissionId'] as String);
    });
    await queue.add(answer('a'));
    expect(await queue.flush(), 'session_paused');
    expect(await queue.pending(), 1);
    paused = false;
    expect(await queue.flush(), isNull);
    expect(sent, ['a']);
  });

  test('keeps the answer on a timeout or a reply it can’t read; drops what is refused for good', () async {
    for (final error in [ApiError(408, 'timeout'), const FormatException('bad reply')]) {
      SharedPreferences.setMockInitialValues({});
      final queue = SubmissionQueue('token-a', (_) async => throw error);
      await queue.add(answer('a'));
      await queue.flush();
      expect(await queue.pending(), 1, reason: '$error');
    }
    for (final (status, key) in [(400, 'bad_answer'), (404, 'not_found'), (409, 'time_up')]) {
      SharedPreferences.setMockInitialValues({});
      final queue = SubmissionQueue('token-a', (_) async => throw ApiError(status, key));
      await queue.add(answer('a'));
      await queue.add(answer('b'));
      expect(await queue.flush(), key);
      expect(await queue.pending(), 0, reason: key);
    }
  });

  test('a retry after a lost reply sends the same id, so the server keeps one copy', () async {
    // A fake server: it stores by submission id, and the first reply is lost on the way back.
    final stored = <String, Map<String, dynamic>>{};
    var lose = true;
    final queue = SubmissionQueue('token-a', (item) async {
      final id = item['submissionId'] as String;
      final duplicate = stored.containsKey(id);
      stored.putIfAbsent(id, () => item);
      if (lose) {
        lose = false;
        throw NoConnection();
      }
      return {'ok': true, 'duplicate': duplicate};
    });
    final replies = <Map<String, dynamic>>[];
    final watching = SubmissionQueue('token-a', queue.send, onReply: (_, reply) => replies.add(reply));
    await watching.add(answer('a'));
    await watching.flush();
    expect(await watching.pending(), 1);
    await watching.flush();
    expect(stored.keys, ['a']);
    expect(replies, [
      {'ok': true, 'duplicate': true},
    ]);
    expect(await watching.pending(), 0);
  });

  test('starting over deletes the session’s waiting answers, not another session’s', () async {
    final a = SubmissionQueue('token-a', (_) async => throw NoConnection());
    final b = SubmissionQueue('token-b', (_) async => throw NoConnection());
    await a.add(answer('a1'));
    await b.add(answer('b1', 'token-b'));
    await forgetSessionOnDevice('token-a');
    expect(await a.pending(), 0);
    expect(await b.pending(), 1);
  });
}
