import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../stats/pass_elevation_profile.dart';
import '../stats/pass_explorer.dart' show Pass;
import '../theme.dart';

/// Height profile of a single pass: the climb from one foot up over the col and
/// down to the other, drawn to scale (real distance along x, height over sea
/// level on y). Detailed when per-vertex elevations are available, falling back
/// to a 3-anchor sketch otherwise.
///
/// Interactive: dragging across the chart reports the distance along the pass
/// via [onScrub]; the owner turns that into a moving marker on the segment map.
/// [cursorKm] (fed back by the owner) draws the matching readout + indicator
/// here so the chart and the map stay in lock-step.
class PassElevationChart extends StatelessWidget {
  const PassElevationChart({
    super.key,
    required this.pass,
    required this.points,
    this.cursorKm,
    this.onScrub,
  });

  final Pass pass;
  final List<PassElevationPoint> points;

  /// Distance along the pass currently highlighted (km), or null for none.
  final double? cursorKm;

  /// Called with the distance (km) the rider drags to, for live map tracking.
  final ValueChanged<double?>? onScrub;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) return const SizedBox.shrink();

    final totalKm = points.last.km;
    var minEle = points.first.ele;
    var maxEle = points.first.ele;
    var summitKm = points.first.km;
    for (final p in points) {
      if (p.ele < minEle) minEle = p.ele;
      if (p.ele > maxEle) {
        maxEle = p.ele;
        summitKm = p.km;
      }
    }
    final summitFrac = totalKm <= 0 ? 0.5 : (summitKm / totalKm);

    final cursorEle = cursorKm == null ? null : eleAtKm(points, cursorKm!);

    final connects =
        (pass.connects != null && pass.connects!.length == 2) ? pass.connects! : null;
    final leftName = connects?[0] ?? 'Start';
    final rightName = connects?[1] ?? 'Ziel';

    void reportAt(double dx, double width) {
      if (onScrub == null || width <= 0) return;
      final frac = (dx / width).clamp(0.0, 1.0);
      onScrub!(frac * totalKm);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.gridLine.withValues(alpha: 0.6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Höhenprofil',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted.withValues(alpha: 0.9),
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                if (cursorKm != null && cursorEle != null)
                  Text(
                    '${_fmtKm(cursorKm!)} km · ${cursorEle.round()} m',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppColors.accent,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 100,
              child: LayoutBuilder(
                builder: (context, c) {
                  final tagLeft =
                      (summitFrac * c.maxWidth - 26).clamp(0.0, c.maxWidth - 52);
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => reportAt(d.localPosition.dx, c.maxWidth),
                    onHorizontalDragStart: (d) =>
                        reportAt(d.localPosition.dx, c.maxWidth),
                    onHorizontalDragUpdate: (d) =>
                        reportAt(d.localPosition.dx, c.maxWidth),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _PassProfilePainter(
                              points: points,
                              minEle: minEle,
                              maxEle: maxEle,
                              summitKm: summitKm,
                              cursorKm: cursorKm,
                              cursorEle: cursorEle,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          child: _AxisLabel('${maxEle.round()} m'),
                        ),
                        Positioned(
                          left: 0,
                          bottom: 0,
                          child: _AxisLabel('${minEle.round()} m'),
                        ),
                        Positioned(
                          left: tagLeft,
                          top: -2,
                          child: _SummitTag(ele: maxEle.round()),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _ProfileFootLabel(
                  name: leftName,
                  ele: points.first.ele.round(),
                  align: CrossAxisAlignment.start,
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_fmtKm(totalKm)} km'
                        '${pass.heightGainM != null ? ' · ↑${pass.heightGainM} m' : ''}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (onScrub != null)
                        Text(
                          'Profil ziehen ↔',
                          style: TextStyle(
                            fontSize: 9,
                            color: AppColors.textMuted.withValues(alpha: 0.7),
                          ),
                        ),
                    ],
                  ),
                ),
                _ProfileFootLabel(
                  name: rightName,
                  ele: points.last.ele.round(),
                  align: CrossAxisAlignment.end,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtKm(double km) =>
    km >= 10 ? km.toStringAsFixed(0) : km.toStringAsFixed(1);

class _AxisLabel extends StatelessWidget {
  const _AxisLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 9,
          color: AppColors.textMuted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SummitTag extends StatelessWidget {
  const _SummitTag({required this.ele});
  final int ele;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.terrain_rounded, size: 11, color: AppColors.accent),
        const SizedBox(width: 2),
        Text(
          '$ele m',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: AppColors.accent,
          ),
        ),
      ],
    );
  }
}

class _ProfileFootLabel extends StatelessWidget {
  const _ProfileFootLabel({
    required this.name,
    required this.ele,
    required this.align,
  });
  final String name;
  final int ele;
  final CrossAxisAlignment align;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: align,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign:
                align == CrossAxisAlignment.end ? TextAlign.end : TextAlign.start,
            style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '$ele m',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: AppColors.text,
          ),
        ),
      ],
    );
  }
}

/// Paints the to-scale climb silhouette: filled area under the profile line, a
/// dot at the summit, and — while scrubbing — a vertical indicator + dot at the
/// cursor. x is distance along the road, y is elevation over [minEle]…[maxEle].
class _PassProfilePainter extends CustomPainter {
  _PassProfilePainter({
    required this.points,
    required this.minEle,
    required this.maxEle,
    required this.summitKm,
    required this.cursorKm,
    required this.cursorEle,
  });

  final List<PassElevationPoint> points;
  final double minEle;
  final double maxEle;
  final double summitKm;
  final double? cursorKm;
  final double? cursorEle;

  @override
  void paint(Canvas canvas, Size size) {
    final totalKm = points.last.km;
    final span = (maxEle - minEle).clamp(1.0, double.infinity);
    const topPad = 14.0; // room for the summit tag
    const botPad = 4.0;

    double x(double km) => totalKm <= 0 ? 0 : (km / totalKm) * size.width;
    double y(double ele) {
      final t = (ele - minEle) / span; // 0 at lowest, 1 at highest
      return size.height - botPad - t * (size.height - topPad - botPad);
    }

    final offsets = [for (final p in points) Offset(x(p.km), y(p.ele))];

    // Filled area.
    final fillPath = ui.Path()..moveTo(offsets.first.dx, size.height);
    for (final o in offsets) {
      fillPath.lineTo(o.dx, o.dy);
    }
    fillPath
      ..lineTo(offsets.last.dx, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66FF6B1A), Color(0x11FF6B1A)],
        ).createShader(Offset.zero & size),
    );

    // Profile line.
    final linePath = ui.Path()..moveTo(offsets.first.dx, offsets.first.dy);
    for (final o in offsets.skip(1)) {
      linePath.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      linePath,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    // Summit dot.
    final summit = Offset(x(summitKm), y(maxEle));
    canvas.drawCircle(summit, 4, Paint()..color = AppColors.accent);
    canvas.drawCircle(
      summit,
      4,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Scrub cursor.
    if (cursorKm != null && cursorEle != null) {
      final cx = x(cursorKm!);
      canvas.drawLine(
        Offset(cx, topPad - 6),
        Offset(cx, size.height),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = 1.5,
      );
      final cp = Offset(cx, y(cursorEle!));
      canvas.drawCircle(cp, 5, Paint()..color = Colors.white);
      canvas.drawCircle(cp, 4, Paint()..color = AppColors.accent);
    }
  }

  @override
  bool shouldRepaint(covariant _PassProfilePainter old) =>
      old.points != points ||
      old.minEle != minEle ||
      old.maxEle != maxEle ||
      old.cursorKm != cursorKm;
}
