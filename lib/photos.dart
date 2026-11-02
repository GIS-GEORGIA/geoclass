import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'l10n.dart';

/// One picture in web/aerial/index.json.
class Photo {
  final String file, ka, en;
  final double lat, lon;
  const Photo({required this.file, required this.ka, required this.en, required this.lat, required this.lon});
}

final _fileName = RegExp(r'^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$');

/// Reads the list of photos. An entry with a mistake is left out, and test/logic_test.dart names it.
List<Photo> parsePhotos(String json) {
  final photos = <Photo>[];
  for (final e in jsonDecode(json) as List) {
    if (e is! Map) continue;
    final file = e['file'], ka = e['ka'], lat = e['lat'], lon = e['lon'];
    if (file is! String || !_fileName.hasMatch(file) || ka is! String || ka.isEmpty || lat is! num || lon is! num) continue;
    if (lat.abs() > 90 || lon.abs() > 180) continue;
    final en = e['en'];
    photos.add(Photo(file: file, ka: ka, en: en is String ? en : '', lat: lat.toDouble(), lon: lon.toDouble()));
  }
  return photos;
}

String photoUrl(String file) => '$publicUrl/aerial/$file';

/// The photos on the server. A missing list means no photos have been added yet.
Future<List<Photo>> loadPhotos() async {
  final http.Response response;
  try {
    response = await http.get(Uri.parse('$publicUrl/aerial/index.json')).timeout(const Duration(seconds: 15));
  } on Exception {
    throw NoConnection();
  }
  if (response.statusCode == 404) return const [];
  if (response.statusCode != 200) throw NoConnection();
  return parsePhotos(utf8.decode(response.bodyBytes));
}

/// A photo that opens full screen, where it can be zoomed, when tapped.
class TaskPhoto extends StatelessWidget {
  final S s;
  final String file;
  final double height;
  const TaskPhoto({super.key, required this.s, required this.file, required this.height});

  Widget _image(BoxFit fit) => Image.network(
        photoUrl(file),
        fit: fit,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(s['photo_missing'], textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
          ),
        ),
      );

  void _open(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(child: InteractiveViewer(maxScale: 8, child: Center(child: _image(BoxFit.contain)))),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filledTonal(
                  tooltip: s['close'],
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: height,
          child: Material(
            color: Colors.black,
            child: InkWell(
              onTap: () => _open(context),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _image(BoxFit.contain),
                  const Positioned(
                    right: 8,
                    bottom: 8,
                    child: Icon(Icons.zoom_in, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
