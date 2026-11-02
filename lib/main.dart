import 'package:flutter/material.dart';

import 'home_page.dart';
import 'settings.dart';
import 'student_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();
  runApp(App(settings: settings));
}

ThemeData _theme(Brightness brightness) => ThemeData(
      colorSchemeSeed: const Color(0xFF00796B),
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'NotoSansGeorgian',
    );

/// Students arrive at `#/join/<token>`, everyone else gets the teacher side.
String? joinToken(String? routeName) =>
    RegExp(r'^/join/([A-Za-z0-9_-]+)$').firstMatch(routeName ?? '')?.group(1);

class App extends StatelessWidget {
  final Settings settings;
  const App({super.key, required this.settings});

  Route<void> _route(String? name) {
    final token = joinToken(name);
    return MaterialPageRoute(
      settings: RouteSettings(name: name),
      builder: (_) => token != null
          ? StudentPage(settings: settings, token: token)
          : HomePage(settings: settings),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: settings,
        builder: (_, _) => MaterialApp(
          title: settings.s['app_title'],
          debugShowCheckedModeBanner: false,
          themeMode: settings.theme,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          onGenerateInitialRoutes: (name) => [_route(name)],
          onGenerateRoute: (r) => _route(r.name),
        ),
      );
}
