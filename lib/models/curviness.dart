/// How twisty the planner should make a route.
///
/// Each level maps to a BRouter profile plus a strategy for how many
/// alternative routes to fetch and whether to pick the *curviest* of them
/// (using [curvinessScore]). All profiles are motor-vehicle profiles — we
/// never route a motorcycle onto a cycleway or footpath.
enum Curviness {
  /// Get there quickly — fastest sensible roads.
  fast,

  /// A reasonable everyday mix of speed and scenery.
  balanced,

  /// Prefer the bendy back roads; scan alternatives and keep the curviest.
  curvy,

  /// Maximum fun — small, winding roads, longest detours accepted.
  extra;

  /// BRouter profile name sent to the routing server.
  String get profile => switch (this) {
        Curviness.fast => 'car-fast',
        Curviness.balanced => 'car-eco',
        Curviness.curvy => 'car-eco',
        Curviness.extra => 'moped',
      };

  /// How many alternative routes (alternativeidx 0..n-1) to request. When > 1
  /// the planner keeps whichever alternative scores curviest.
  int get alternatives => switch (this) {
        Curviness.fast => 1,
        Curviness.balanced => 1,
        Curviness.curvy => 3,
        Curviness.extra => 3,
      };

  /// Short German label for the slider / summary.
  String get label => switch (this) {
        Curviness.fast => 'Schnell',
        Curviness.balanced => 'Normal',
        Curviness.curvy => 'Kurvig',
        Curviness.extra => 'Maximal kurvig',
      };

  static Curviness fromIndex(int i) =>
      Curviness.values[i.clamp(0, Curviness.values.length - 1)];
}
