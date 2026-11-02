import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';

Future<void> saveText(String text, String name, String extension, String mime) => FileSaver.instance.saveFile(
      name: name,
      bytes: Uint8List.fromList(utf8.encode(text)),
      fileExtension: extension,
      mimeType: MimeType.custom,
      customMimeType: mime,
    );

Future<void> saveJsonBackup(Map<String, dynamic> backup, String label) {
  final date = DateTime.now().toIso8601String().substring(0, 10);
  return saveText(
    const JsonEncoder.withIndent(' ').convert(backup),
    'geoclass-backup-$label-$date',
    'json',
    'application/json',
  );
}
