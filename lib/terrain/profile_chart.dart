import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../l10n.dart';
import 'profile.dart';

/// Height against distance for a [TerrainProfile], drawn with a [CustomPainter].
///
/// Gaps in the data stay gaps. Dashed lines mark where one section ends and the next begins; the lowest and
/// highest points are marked. Pointing at the chart (mouse, finger or stylus) picks the nearest sample and
/// hands it to [onCursor], so a map can show the same place; [cursor] is drawn as a vertical line.
class ProfileChart extends StatelessWidget {
  final TerrainProfile profile;
  final S s;
  final ProfileSample? cursor;
  final ValueChanged<ProfileSample?>? onCursor;
  final double height;

  const ProfileChart({
    super.key,
    required this.profile,
    required this.s,
    this.cursor,
    this.onCursor,
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = ProfileStyle(
      line: theme.colorScheme.primary,
      fill: theme.colorScheme.primary.withValues(alpha: 0.18),
      grid: theme.colorScheme.outlineVariant,
      text: theme.textTheme.labelSmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
      mark: theme.colorScheme.tertiary,
      cursor: theme.colorScheme.error,
    );
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final painter = ProfilePainter(profile, s, style, cursor);
          void point(Offset at) => onCursor?.call(painter.sampleAt(at, box.biggest));
          return Semantics(
            label: summaryLine(profile, s),
            child: MouseRegion(
              onHover: (e) => point(e.localPosition),
              onExit: (_) => onCursor?.call(null),
              child: GestureDetector(
                onPanDown: (d) => point(d.localPosition),
                onPanUpdate: (d) => point(d.localPosition),
                child: CustomPaint(size: box.biggest, painter: painter),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The chart's colours and text style, taken from the theme.
class ProfileStyle {
  final Color line, fill, grid, mark, cursor;
  final TextStyle text;
  const ProfileStyle({
    required this.line,
    required this.fill,
    required this.grid,
    required this.text,
    required this.mark,
    required this.cursor,
  });
}

/// A round step for axis labels: 1, 2 or 5 times a power of ten, giving about [count] steps over [span].
double niceStep(double span, int count) {
  if (span <= 0) return 1;
  final raw = span / count;
  final power = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  for (final m in [1, 2, 5, 10]) {
    if (m * power >= raw) return m * power;
  }
  return 10 * power;
}

/// Distance in metres as the chart and the summary write it.
String profileDistance(double metres, S s) {
  if (metres < 1000) return s.f('profile_m', [metres.round()]);
  final km = metres / 1000;
  return s.f('profile_km', [km.toStringAsFixed(km < 10 ? 2 : 1)]);
}

/// One line for screen readers and the summary.
String summaryLine(TerrainProfile p, S s) => [
  '${s['profile_length']}: ${profileDistance(p.length, s)}',
  if (p.lowest case final lo?) '${s['profile_min']}: ${s.f('profile_m', [lo.height!.round()])}',
  if (p.highest case final hi?) '${s['profile_max']}: ${s.f('profile_m', [hi.height!.round()])}',
].join(' · ');

class ProfilePainter extends CustomPainter {
  final TerrainProfile profile;
  final S s;
  final ProfileStyle style;
  final ProfileSample? cursor;

  ProfilePainter(this.profile, this.s, this.style, this.cursor);

  static const left = 48.0, right = 12.0, top = 14.0, bottom = 22.0;

  /// The height range on the axis: the profile's, padded (more below, for the lowest point's label).
  (double, double) get _range {
    final lo = profile.lowest?.height ?? 0, hi = profile.highest?.height ?? 0;
    final pad = math.max(10.0, (hi - lo) * 0.08);
    return (lo - 2 * pad, hi + pad);
  }

  Rect _plot(Size size) =>
      Rect.fromLTRB(left, top, math.max(left + 1, size.width - right), math.max(top + 1, size.height - bottom));

  /// The sample under a point of the chart, by its distance; null outside the plot's width.
  ProfileSample? sampleAt(Offset at, Size size) {
    final plot = _plot(size);
    if (at.dx < plot.left - 8 || at.dx > plot.right + 8) return null;
    final t = ((at.dx - plot.left) / plot.width).clamp(0.0, 1.0);
    return profile.nearest(t * profile.length);
  }

  void _label(Canvas canvas, String text, Offset at, {Alignment align = Alignment.center}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style.text),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset((align.x + 1) / 2 * tp.width, (align.y + 1) / 2 * tp.height));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _plot(size);
    final (lo, hi) = _range;
    final length = profile.length == 0 ? 1.0 : profile.length;
    double xOf(double d) => plot.left + d / length * plot.width;
    double yOf(double h) => plot.bottom - (h - lo) / (hi - lo) * plot.height;
    final gridPaint = Paint()
      ..color = style.grid
      ..strokeWidth = 1;

    // Height lines and labels.
    final hStep = niceStep(hi - lo, 4);
    for (var h = (lo / hStep).ceil() * hStep; h <= hi; h += hStep) {
      canvas.drawLine(Offset(plot.left, yOf(h)), Offset(plot.right, yOf(h)), gridPaint);
      _label(canvas, s.f('profile_m', [h.round()]), Offset(plot.left - 4, yOf(h)), align: Alignment.centerRight);
    }
    // Distance labels.
    final dStep = niceStep(length, math.max(2, (plot.width / 90).floor()));
    for (var d = 0.0; d <= length + 1e-6; d += dStep) {
      canvas.drawLine(Offset(xOf(d), plot.bottom), Offset(xOf(d), plot.bottom + 3), gridPaint);
      _label(canvas, profileDistance(d, s), Offset(xOf(d), plot.bottom + 4), align: Alignment.topCenter);
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, gridPaint);

    // Section boundaries, dashed, with each section's number above it.
    for (final sec in profile.sections) {
      final x0 = xOf(sec.start);
      if (sec.index > 0) {
        for (var y = plot.top; y < plot.bottom; y += 6) {
          canvas.drawLine(Offset(x0, y), Offset(x0, math.min(y + 3, plot.bottom)), gridPaint);
        }
      }
      _label(
        canvas,
        '${sec.index + 1}',
        Offset(xOf(sec.start + sec.length / 2), plot.top - 1),
        align: Alignment.bottomCenter,
      );
    }

    // The profile: a filled area and a line, both broken where there is no height.
    final linePaint = Paint()
      ..color = style.line
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()..color = style.fill;
    final run = <Offset>[];
    void flush() {
      if (run.length > 1) {
        final area = Path()..moveTo(run.first.dx, plot.bottom);
        for (final p in run) {
          area.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(
          area
            ..lineTo(run.last.dx, plot.bottom)
            ..close(),
          fillPaint,
        );
        canvas.drawPath(Path()..addPolygon(run, false), linePaint);
      } else if (run.length == 1) {
        canvas.drawCircle(run.single, 1.5, Paint()..color = style.line);
      }
      run.clear();
    }

    for (final sample in profile.samples) {
      final h = sample.height;
      if (h == null) {
        flush();
      } else {
        run.add(Offset(xOf(sample.distance), yOf(h)));
      }
    }
    flush();

    // Lowest and highest.
    final markPaint = Paint()..color = style.mark;
    for (final (sample, above) in [(profile.highest, true), (profile.lowest, false)]) {
      if (sample == null) continue;
      final at = Offset(xOf(sample.distance), yOf(sample.height!));
      canvas.drawCircle(at, 4, markPaint);
      final align = at.dx < plot.left + 40
          ? (above ? Alignment.bottomLeft : Alignment.topLeft)
          : at.dx > plot.right - 40
          ? (above ? Alignment.bottomRight : Alignment.topRight)
          : (above ? Alignment.bottomCenter : Alignment.topCenter);
      _label(canvas, s.f('profile_m', [sample.height!.round()]), at + Offset(0, above ? -5 : 5), align: align);
    }

    // The cursor.
    if (cursor case final c?) {
      final x = xOf(c.distance);
      final cursorPaint = Paint()
        ..color = style.cursor
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), cursorPaint);
      if (c.height case final h?) canvas.drawCircle(Offset(x, yOf(h)), 4.5, cursorPaint);
    }
  }

  @override
  bool shouldRepaint(ProfilePainter old) =>
      !identical(old.profile, profile) || old.cursor != cursor || old.style.line != style.line || old.s.lang != s.lang;
}

/// The profile's numbers under the chart: length, lowest, highest, climb, drop, the steepest section, and
/// what is under the [cursor].
class ProfileSummary extends StatelessWidget {
  final TerrainProfile profile;
  final S s;
  final ProfileSample? cursor;

  const ProfileSummary({super.key, required this.profile, required this.s, this.cursor});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = profile;
    Widget item(String label, String value, {Key? key}) => Text.rich(
      key: key,
      TextSpan(
        children: [
          TextSpan(text: '$label: ', style: text.bodySmall),
          TextSpan(
            text: value,
            style: text.bodyMedium!.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
    final steep = p.steepest;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        item(s['profile_length'], profileDistance(p.length, s)),
        if (p.lowest case final lo?) item(s['profile_min'], s.f('profile_m', [lo.height!.round()])),
        if (p.highest case final hi?) item(s['profile_max'], s.f('profile_m', [hi.height!.round()])),
        item(s['profile_ascent'], s.f('profile_m', [p.ascent.round()])),
        item(s['profile_descent'], s.f('profile_m', [p.descent.round()])),
        if (steep != null && p.sections.length > 1)
          item(
            s['profile_steepest'],
            s.f('profile_section_slope', [
              steep.index + 1,
              steep.slopeDegrees!.abs().toStringAsFixed(1),
              (steep.grade! * 100).round(),
            ]),
          )
        else if (steep != null)
          item(
            s['profile_slope'],
            s.f('profile_slope_value', [steep.slopeDegrees!.abs().toStringAsFixed(1), (steep.grade! * 100).round()]),
          ),
        if (cursor case final c?)
          item(
            s['profile_here'],
            '${profileDistance(c.distance, s)} · ${c.height == null ? s['terrain_no_height'] : s.f('profile_m', [c.height!.round()])}',
            key: const Key('profile_cursor'),
          ),
      ],
    );
  }
}
