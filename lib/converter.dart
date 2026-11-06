import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'coords.dart';
import 'l10n.dart';

/// A coordinate converter like the one in the BTC field app: DD, DM or DMS to every format, or UTM back.
class CoordConverter extends StatefulWidget {
  final S s;
  const CoordConverter({super.key, required this.s});
  @override
  State<CoordConverter> createState() => _CoordConverterState();
}

class _CoordConverterState extends State<CoordConverter> {
  bool _fromUtm = false;
  int _zone = 38;
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _easting = TextEditingController();
  final _northing = TextEditingController();

  S get s => widget.s;

  @override
  void dispose() {
    for (final c in [_lat, _lon, _easting, _northing]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The point typed in, or null while it isn't a valid one.
  (double, double)? get _point {
    if (_fromUtm) {
      final e = double.tryParse(_easting.text.trim().replaceAll(',', '.'));
      final n = double.tryParse(_northing.text.trim().replaceAll(',', '.'));
      if (e == null || n == null || e < 100000 || e > 900000 || n < 0 || n > 10000000) return null;
      final p = fromUtm(_zone, e, n);
      return (p.latitude, p.longitude);
    }
    final lat = parseOne(_lat.text), lon = parseOne(_lon.text);
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
    return (lat, lon);
  }

  Widget _field(TextEditingController c, String label, {String? hint}) => TextField(
    controller: c,
    onChanged: (_) => setState(() {}),
    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
    decoration: InputDecoration(labelText: label, hintText: hint, isDense: true, border: const OutlineInputBorder()),
  );

  Widget _result(String label, String value) => Row(
    children: [
      SizedBox(width: 76, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
      Expanded(child: SelectableText(value)),
      IconButton(
        tooltip: s['ev_copy'],
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s['ev_copied']), duration: const Duration(seconds: 1)));
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final point = _point;
    String utm(int zone) {
      final u = toUtm(point!.$1, point.$2, zone: zone);
      return 'E ${u.easting.round()}  N ${u.northing.round()}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('DD / DM / DMS → UTM')),
            ButtonSegment(value: true, label: Text('UTM → DD')),
          ],
          selected: {_fromUtm},
          onSelectionChanged: (v) => setState(() => _fromUtm = v.first),
        ),
        const SizedBox(height: 12),
        if (_fromUtm) ...[
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 37, label: Text('UTM 37N')),
              ButtonSegment(value: 38, label: Text('UTM 38N')),
            ],
            selected: {_zone},
            onSelectionChanged: (v) => setState(() => _zone = v.first),
          ),
          const SizedBox(height: 8),
          _field(_easting, 'Easting (E)', hint: '483482'),
          const SizedBox(height: 8),
          _field(_northing, 'Northing (N)', hint: '4615799'),
        ] else ...[
          _field(_lat, s.f('play_lat', ['N']), hint: '41.6938 · 41 41.63 · 41 41 38'),
          const SizedBox(height: 8),
          _field(_lon, s.f('play_lon', ['E']), hint: '44.8015 · 44 48.09 · 44 48 05'),
        ],
        const SizedBox(height: 8),
        if (point == null)
          Text(s['ev_conv_empty'], style: Theme.of(context).textTheme.bodySmall)
        else ...[
          _result('DD', formatDd(point.$1, point.$2)),
          _result('DM', formatDm(point.$1, point.$2)),
          _result('DMS', formatDms(point.$1, point.$2)),
          _result('UTM 37N', utm(37)),
          _result('UTM 38N', utm(38)),
        ],
      ],
    );
  }
}
