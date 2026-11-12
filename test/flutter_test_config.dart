import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/queue.dart';

/// Runs around every test file: each test starts with no queue lock left over from the one before.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(SubmissionQueue.forgetRunning);
  await testMain();
}
