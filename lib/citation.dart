import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n.dart';

const authorOrcid = 'https://orcid.org/0009-0006-4193-5939';

/// How to cite GeoClass. Kept in step with CITATION.cff at the repository root.
const citationApa =
    'Kapanadze, G. (2026). GeoClass: ინტერაქციული გეოგრაფიული თამაშები სკოლის მოსწავლეებისთვის / Interactive Geography Games for School Students (Version 1.0.0) [Computer software]. '
    'Business and Technology University (BTU). https://github.com/GIS-GEORGIA/geoclass';

const citationBibtex = '''@software{kapanadze_geoclass_2026,
  author      = {Kapanadze, Giorgi},
  title       = {{GeoClass}: ინტერაქციული გეოგრაფიული თამაშები სკოლის მოსწავლეებისთვის / {Interactive Geography Games for School Students}},
  year        = {2026},
  version     = {1.0.0},
  institution = {{Business and Technology University (BTU)}},
  url         = {https://github.com/GIS-GEORGIA/geoclass}
}''';

/// Shows both citation formats, each with a copy button.
Future<void> showCitation(BuildContext context, S s) => showDialog<void>(
  context: context,
  builder: (ctx) {
    final theme = Theme.of(ctx);
    Widget block(String label, String text) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
            IconButton(
              tooltip: s['cite_copy'],
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(s['cite_copied'])));
                }
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            text,
            style: label == 'BibTeX' ? const TextStyle(fontFamily: 'monospace', fontSize: 12) : null,
          ),
        ),
      ],
    );
    return AlertDialog(
      title: Text(s['cite_title']),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s['cite_intro']),
              const SizedBox(height: 6),
              SelectableText('Giorgi Kapanadze · ORCID $authorOrcid', style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              block('APA', citationApa),
              const SizedBox(height: 12),
              block('BibTeX', citationBibtex),
            ],
          ),
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(s['close']))],
    );
  },
);
