import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../stats/pass_elevation_profile.dart';
import '../stats/pass_explorer.dart' show Pass;
import '../theme.dart';

/// Height profile of a single pass: the climb from one foot up over the col and
/// down to the other foot, drawn to scale so the col sits at its real distance
/// along the road and each foot at its real elevation (the two sides are
/// usually neither the same height nor the same length).
///
/// Falls back to nothing when the pass lacks the elevations/geometry needed to
/// draw an honest profile — see [passElevationProfile].
class PassElevationChart extends StatelessWidget {
  const PassElevationChart({super.key, required this.pass});

  final Pass pass;

  @override
  Widget build(BuildContext context) {
    final points = passElevationProfile(pass);
    if (points.length < 2) return const SizedBox.shrink();

    final summit = (pass.summitEle ?? pass.ele)?.toDouble();
    final totalKm = points.last.km;
    final colKm = _colKm(points, summit);
    final colFrac = totalKm <= 0 ? 0.5 : (colKm / totalKm);

    var minEle = points.first.ele;
    var maxEle = points.first.ele;
    for (final p in points) {
      if (p.ele < minEle) minEle = p.ele;
      if (p.ele > maxEle) maxEle = p.ele;
    }

    final connects =
        (pass.connects != null && pass.connects!.length == 2) ? pass.connects! : null;
    final leftName = connects?[0] ?? 'Start';
    final rightName = connects?[1] ?? 'Ziel';

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
            Text(
              'Höhenprofil',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textMuted.withValues(alpha: 0.9),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 96,
              child: LayoutBuilder(
                builder: (context, c) {
                  // Place the summit tag over the col's real x-position, kept
                  // fully on-card at the extremes.
                  final tagLeft =
                      (colFrac * c.maxWidth - 26).clamp(0.0, c.maxWidth - 52);
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _PassProfilePainter(
                            points: points,
                            minEle: minEle,
                            maxEle: maxEle,
                            summit: summit,
                          ),
                        ),
                      ),
                      // Max / min elevation ticks on the left edge.
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
                      // Summit elevation tag at the col.
                      if (summit != null)
                        Positioned(
                          left: tagLeft,
                          top: -2,
                          child: _SummitTag(ele: summit.round()),
                        ),
                    ],
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
                  child: Text(
                    '${_fmtKm(totalKm)} km'
                    '${pass.heightGainM != null ? ' · ↑${pass.heightGainM} m' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
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

  /// The km of the highest anchor (the col), used to position the summit tag.
  double _colKm(List<PassElevationPoint> points, double? summit) {
    var best = points.first;
    for (final p in points) {
      if (p.ele > best.ele) best = p;
    }
    return best.km;
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
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

/// Paints the to-scale climb silhouette: a filled area under the profile line
/// with a dot at each surveyed anchor (the col dot accented). x is distance
/// along the road, y is elevation over the [minEle]…[maxEle] span.
class _PassProfilePainter extends CustomPainter {
  _PassProfilePainter({
    required this.points,
    required this.minEle,
    required this.maxEle,
    required this.summit,
  });

  final List<PassElevationPoint> points;
  final double minEle;
  final double maxEle;
  final double? summit;

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
    final fill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x66FF6B1A), Color(0x11FF6B1A)],
      ).createShader(Offset.zero & size);
    canvas.drawPath(fillPath, fill);

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

    // Anchor dots — accent the summit, subdue the feet.
    for (var i = 0; i < points.length; i++) {
      final isSummit = summit != null && (points[i].ele - summit!).abs() < 0.5;
      final o = offsets[i];
      canvas.drawCircle(o, isSummit ? 4 : 3,
          Paint()..color = isSummit ? AppColors.accent : AppColors.textMuted);
      canvas.drawCircle(
        o,
        isSummit ? 4 : 3,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PassProfilePainter old) =>
      old.points != points ||
      old.minEle != minEle ||
      old.maxEle != maxEle ||
      old.summit != summit;
}
