import 'package:flutter/material.dart';

import 'home_page.dart';
import 'settings.dart';
import 'student_page.dart';
import 'terrain/areas_page.dart';

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

/// A route name as the patterns below expect it. Android can start the app with the whole link of a QR code
/// (`https://geoclass.qgis.ge/#/join/<token>`) as the first route, so a full URL is cut to its path and fragment.
String? routePath(String? routeName) {
  if (routeName == null || !routeName.startsWith(RegExp('https?://'))) return routeName;
  final uri = Uri.tryParse(routeName);
  if (uri == null) return routeName;
  final path = uri.path.isEmpty ? '/' : uri.path;
  return uri.hasFragment ? '$path#${uri.fragment}' : path;
}

/// Students arrive at `#/join/<token>`, everyone else gets the teacher side.
String? joinToken(String? routeName) =>
    RegExp(r'^/(?:#/)?join/([A-Za-z0-9_-]+)$').firstMatch(routePath(routeName) ?? '')?.group(1);

/// The terrain areas preview: `#/areas`.
bool isAreasRoute(String? routeName) => RegExp(r'^/(?:#/)?areas/?$').hasMatch(routePath(routeName) ?? '');

class App extends StatelessWidget {
  final Settings settings;
  const App({super.key, required this.settings});

  Route<void> _route(String? name) {
    final token = joinToken(name);
    return MaterialPageRoute(
      settings: RouteSettings(name: name),
      builder: (_) => token != null
          ? StudentPage(settings: settings, token: token)
          : isAreasRoute(name)
              ? AreasPage(s: settings.s)
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
