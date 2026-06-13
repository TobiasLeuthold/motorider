import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'geo.dart';

/// On-disk slippy-tile cache, so a planned tour's map still renders with no
/// signal (mountain passes, tunnels). Tiles live at
/// `<cache>/map_tiles/{z}/{x}/{y}.png`.
///
/// Two halves:
///   • [CachedTileProvider] — a flutter_map [TileProvider] that reads a tile
///     from disk if present, otherwise fetches it from the network and writes
///     it through. Used as the map's live tile source, so panning around also
///     warms the cache for free.
///   • [downloadCorridor] — proactively fetches every tile within a buffer of a
///     route's geometry, for the zoom levels you'll actually navigate at.
class TileCache {
  TileCache._(this.directory);

  final Directory directory;

  static TileCache? _instance;
  static Future<TileCache> instance() async {
    if (_instance != null) return _instance!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'map_tiles'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _instance = TileCache._(dir);
  }

  File fileFor(int z, int x, int y) =>
      File(p.join(directory.path, '$z', '$x', '$y.png'));

  /// Total bytes currently cached on disk.
  Future<int> sizeBytes() async {
    var total = 0;
    if (!directory.existsSync()) return 0;
    await for (final e in directory.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {/* file vanished mid-scan; ignore */}
      }
    }
    return total;
  }

  Future<void> clear() async {
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    directory.createSync(recursive: true);
  }

  /// Which {z}/{x}/{y} tiles cover a [bufferMeters]-wide band around [route]
  /// at the given [zooms]. Deduplicated.
  List<_Tile> _tilesForCorridor(
    List<LatLng> route,
    List<int> zooms,
    double bufferMeters,
  ) {
    final out = <_Tile>{};
    for (final z in zooms) {
      for (final pt in route) {
        // Convert the buffer (in meters) to a tile radius at this lat/zoom.
        final mpp = metersPerPixel(pt.latitude, z);
        final radiusTiles = (bufferMeters / (mpp * 256)).ceil();
        final cx = lonToTileX(pt.longitude, z);
        final cy = latToTileY(pt.latitude, z);
        for (var dx = -radiusTiles; dx <= radiusTiles; dx++) {
          for (var dy = -radiusTiles; dy <= radiusTiles; dy++) {
            out.add(_Tile(z, cx + dx, cy + dy));
          }
        }
      }
    }
    return out.toList();
  }

  /// Estimate tile count for a corridor download without fetching anything.
  int estimateTileCount(
    List<LatLng> route,
    List<int> zooms,
    double bufferMeters,
  ) =>
      _tilesForCorridor(route, zooms, bufferMeters).length;

  /// Download every tile in the corridor that isn't already cached, emitting
  /// progress as `(done, total)`. Throttled and low-concurrency to respect the
  /// OSM tile usage policy. Cancellable via [shouldCancel].
  Stream<TileDownloadProgress> downloadCorridor({
    required List<LatLng> route,
    required String urlTemplate,
    required Map<String, String> headers,
    List<int> zooms = const [11, 12, 13, 14],
    double bufferMeters = 550,
    int concurrency = 4,
    bool Function()? shouldCancel,
  }) async* {
    final tiles = _tilesForCorridor(route, zooms, bufferMeters)
        .where((t) => !fileFor(t.z, t.x, t.y).existsSync())
        .toList();
    final total = tiles.length;
    if (total == 0) {
      yield const TileDownloadProgress(done: 0, total: 0);
      return;
    }
    final client = http.Client();
    var done = 0;
    var failed = 0;
    try {
      for (var i = 0; i < tiles.length; i += concurrency) {
        if (shouldCancel?.call() ?? false) break;
        final batch = tiles.skip(i).take(concurrency);
        await Future.wait(batch.map((t) async {
          final ok = await _downloadTile(client, t, urlTemplate, headers);
          if (!ok) failed++;
        }));
        done += batch.length;
        yield TileDownloadProgress(done: done, total: total, failed: failed);
        // Be polite to the tile server between batches.
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } finally {
      client.close();
    }
    yield TileDownloadProgress(done: done, total: total, failed: failed);
  }

  Future<bool> _downloadTile(
    http.Client client,
    _Tile t,
    String urlTemplate,
    Map<String, String> headers,
  ) async {
    final url = urlTemplate
        .replaceAll('{z}', '${t.z}')
        .replaceAll('{x}', '${t.x}')
        .replaceAll('{y}', '${t.y}');
    try {
      final res = await client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return false;
      final f = fileFor(t.z, t.x, t.y);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(res.bodyBytes, flush: false);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class TileDownloadProgress {
  const TileDownloadProgress({
    required this.done,
    required this.total,
    this.failed = 0,
  });
  final int done;
  final int total;
  final int failed;
  double get fraction => total == 0 ? 1 : done / total;
  bool get isComplete => done >= total;
}

class _Tile {
  const _Tile(this.z, this.x, this.y);
  final int z, x, y;
  @override
  bool operator ==(Object other) =>
      other is _Tile && other.z == z && other.x == x && other.y == y;
  @override
  int get hashCode => Object.hash(z, x, y);
}

/// flutter_map tile provider that serves from [TileCache] first and falls back
/// to the network, writing fetched tiles through to disk. Returns a
/// transparent tile on failure so the map degrades gracefully offline instead
/// of showing red error squares.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({required this.cache, super.headers});

  final TileCache cache;
  final http.Client _client = http.Client();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final file = cache.fileFor(coordinates.z, coordinates.x, coordinates.y);
    return _CachedTileImage(
      url: url,
      file: file,
      headers: headers,
      client: _client,
    );
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

@immutable
class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  const _CachedTileImage({
    required this.url,
    required this.file,
    required this.headers,
    required this.client,
  });

  final String url;
  final File file;
  final Map<String, String> headers;
  final http.Client client;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    // 1. Disk cache hit.
    try {
      if (file.existsSync() && await file.length() > 0) {
        final bytes = await file.readAsBytes();
        return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      }
    } catch (_) {/* fall through to network */}

    // 2. Network, write-through.
    try {
      final res = await client
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        unawaited(_persist(res.bodyBytes));
        return decode(await ui.ImmutableBuffer.fromUint8List(res.bodyBytes));
      }
    } catch (_) {/* offline & uncached — fall through to transparent */}

    // 3. Graceful blank tile.
    return decode(
      await ui.ImmutableBuffer.fromUint8List(TileProvider.transparentImage),
    );
  }

  Future<void> _persist(Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {/* best effort */}
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
