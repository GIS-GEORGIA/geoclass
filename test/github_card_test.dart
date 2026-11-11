import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoclass/l10n.dart';
import 'package:geoclass/settings.dart';
import 'package:geoclass/settings_page.dart';
import 'package:lottie/lottie.dart';

void main() {
  test('the loading cat is a valid animation, with its licence beside it', () async {
    final composition = await LottieComposition.fromBytes(File('assets/lottie/loading_cat.json').readAsBytesSync());
    expect(composition.duration, greaterThan(Duration.zero));
    expect(File('assets/lottie/LICENSE.txt').readAsStringSync(), contains('Lottie Simple License'));
  });

  testWidgets('the GitHub card shows the cat, the link and the credit', (tester) async {
    const s = S('ka');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: GithubCard(s: s))));
    expect(find.byType(LottieBuilder), findsOneWidget);
    expect(find.text(s['github']), findsOneWidget);
    expect(find.text(githubUrl.replaceFirst('https://', '')), findsOneWidget);
    expect(find.text(s['cat_credit']), findsOneWidget);
  });
}
