import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' show min;
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as md;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const green = Color(0xFF1DB954);
const _exts = {
  '.mp3',
  '.m4a',
  '.aac',
  '.wav',
  '.ogg',
  '.opus',
  '.flac',
  '.webm',
};
const kRepo = String.fromEnvironment('REPO');
const kBuild = int.fromEnvironment('BUILD', defaultValue: 0);
const kTag = String.fromEnvironment('TAG', defaultValue: '');
// Self-hosted yt-dlp backend (see ytdlp_api.py) — primary download path.
// yt-dlp is updated almost daily to counter YouTube's changes; nothing that
// runs purely on-device can keep up with that, so this is the reliable path.
const kYtApiBase = String.fromEnvironment('YT_API_BASE', defaultValue: '');
const kYtApiKey = String.fromEnvironment('YT_API_KEY', defaultValue: '');
final player = AudioPlayer();
// Palette cache: song.id → dominant color extracted from album art
final _paletteCache = <String, Color>{};

/// Disk-backed cache for data that should not make the library index large.
/// Writes are atomic so a process kill cannot leave a half-written cache file.
class LocalCache {
  Directory? _root;
  Future<void>? _initFuture;

  Future<void> init() async {
    final pending = _initFuture;
    if (pending != null) return pending;
    final future = _initialize();
    _initFuture = future;
    try {
      await future;
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> _initialize() async {
    _root = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'cache'),
    );
    await Directory(p.join(_root!.path, 'art')).create(recursive: true);
    await Directory(p.join(_root!.path, 'lyrics')).create(recursive: true);
  }

  Future<File> _file(String dir, String name) async {
    await init();
    return File(p.join(_root!.path, dir, name));
  }

  Future<String?> saveArt(String id, List<int> bytes) async {
    if (bytes.isEmpty) return null;
    final file = await _file('art', '$id.img');
    try {
      await _atomicBytes(file, bytes);
      return await validFile(file.path) ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeArt(String id) async {
    try {
      await (await _file('art', '$id.img')).delete();
    } catch (_) {}
  }

  Future<void> saveLyrics(String id, String? plain, String? synced) async {
    if ((plain == null || plain.isEmpty) && (synced == null || synced.isEmpty))
      return;
    final file = await _file('lyrics', '$id.json');
    await _atomicText(file, jsonEncode({'plain': plain, 'synced': synced}));
  }

  Future<Map<String, String?>?> readLyrics(String id) async {
    final file = await _file('lyrics', '$id.json');
    try {
      if (!await file.exists() || await file.length() == 0) return null;
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) throw const FormatException('invalid lyric cache');
      final plain = value['plain'] as String?;
      final synced = value['synced'] as String?;
      if ((plain == null || plain.isEmpty) &&
          (synced == null || synced.isEmpty))
        return null;
      return {'plain': plain, 'synced': synced};
    } catch (_) {
      // A broken cache entry is disposable; the song itself is still usable.
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> removeLyrics(String id) async {
    try {
      await (await _file('lyrics', '$id.json')).delete();
    } catch (_) {}
  }

  Future<void> remove(String id) async {
    for (final file in [
      await _file('art', '$id.img'),
      await _file('lyrics', '$id.json'),
    ]) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<bool> validFile(String? path) async {
    if (path == null || path.isEmpty) return false;
    try {
      final file = File(path);
      return await file.exists() && await file.length() > 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _atomicBytes(File file, List<int> bytes) async {
    final tmp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      // Windows cannot replace an existing file with rename. Removing the old
      // cache entry first still leaves a complete temporary file on failure.
      if (Platform.isWindows && await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _atomicText(File file, String text) async {
    final tmp = File(
      '${file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    } finally {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
    }
  }
}

// ---- in-app debug log (visible when lyrics fail)
final List<String> lyricLog = [];
void _lyricLog(String s) {
  debugPrint(s);
  final t = DateTime.now().toIso8601String().substring(11, 19);
  lyricLog.add('$t  $s');
  if (lyricLog.length > 200) lyricLog.removeAt(0);
}

// ---- metadata enrichment helpers
Future<Map<String, String?>?> _lookupMusicBrainz(
  String title,
  String artist,
) async {
  try {
    final q = Uri.encodeComponent(
      artist == 'Unknown artist' ? title : '$title $artist',
    );
    final r = await http
        .get(
          Uri.parse(
            'https://musicbrainz.org/ws/2/recording/?query=$q&limit=1&fmt=json',
          ),
          headers: {'User-Agent': 'SoundWave/1.0 (soundwave-app)'},
        )
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final recs = j['recordings'] as List?;
    if (recs == null || recs.isEmpty) return null;
    final rec = recs.first as Map;
    final foundTitle = rec['title'] as String?;
    String? foundArtist;
    final credits = rec['artist-credit'] as List?;
    if (credits != null && credits.isNotEmpty) {
      foundArtist = (credits.first as Map)['artist']?['name'] as String?;
    }
    String? releaseId;
    final releases = rec['releases'] as List?;
    if (releases != null && releases.isNotEmpty) {
      releaseId = (releases.first as Map)['id'] as String?;
    }
    return {'title': foundTitle, 'artist': foundArtist, 'releaseId': releaseId};
  } catch (_) {
    return null;
  }
}

const _artAgent = 'SoundWave/1.0 (github.com/Havoczt/soundwave)';
const _maxArtBytes = 12 * 1024 * 1024;

class _ArtCandidate {
  final String url;
  final double score;
  const _ArtCandidate(this.url, this.score);
}

String _artKey(String value) =>
    _cleanTitle(value)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();

double _artScore(
  String title,
  String artist,
  String candidateTitle,
  String candidateArtist,
) {
  final titleScore = _similarity(_artKey(title), _artKey(candidateTitle));
  if (titleScore < 0.55) return 0;
  if (artist == 'Unknown artist' || artist.trim().isEmpty) return titleScore;
  final artistScore = _similarity(_artKey(artist), _artKey(candidateArtist));
  if (artistScore < 0.45) return 0;
  return titleScore * .7 + artistScore * .3;
}

String? _largeArtworkUrl(dynamic value) {
  if (value is! String || value.trim().isEmpty) return null;
  return value
      .replaceAll('100x100bb', '600x600bb')
      .replaceAll('200x200bb', '600x600bb')
      .replaceAll('300x300bb', '600x600bb');
}

Future<List<_ArtCandidate>> _fetchItunesArts(
  String title,
  String artist,
) async {
  try {
    final q = Uri.encodeComponent(
      artist == 'Unknown artist' ? title : '$title $artist',
    );
    final r = await http
        .get(
          Uri.parse(
            'https://itunes.apple.com/search?term=$q&media=music&entity=song&limit=10',
          ),
          headers: {'User-Agent': _artAgent},
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return [];
    final results = (jsonDecode(r.body) as Map)['results'] as List?;
    if (results == null) return [];
    return [
      for (final raw in results)
        if (raw is Map)
          if (_largeArtworkUrl(raw['artworkUrl100']) case final url?)
            if (_artScore(
                  title,
                  artist,
                  '${raw['trackName'] ?? ''}',
                  '${raw['artistName'] ?? raw['collectionArtistName'] ?? ''}',
                ) >=
                .55)
              _ArtCandidate(
                url,
                _artScore(
                  title,
                  artist,
                  '${raw['trackName'] ?? ''}',
                  '${raw['artistName'] ?? raw['collectionArtistName'] ?? ''}',
                ),
              ),
    ]..sort((a, b) => b.score.compareTo(a.score));
  } catch (_) {
    return [];
  }
}

// Deezer has a public search endpoint and usually has better coverage than
// iTunes for regional releases and older albums.
Future<List<_ArtCandidate>> _fetchDeezerArts(
  String title,
  String artist,
) async {
  try {
    final q = Uri.encodeComponent(
      artist == 'Unknown artist' ? title : '$artist $title',
    );
    final r = await http
        .get(
          Uri.parse('https://api.deezer.com/search?q=$q&limit=10'),
          headers: {'User-Agent': _artAgent},
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return [];
    final data = (jsonDecode(r.body) as Map)['data'] as List?;
    if (data == null) return [];
    return [
      for (final raw in data)
        if (raw is Map)
          if (_largeArtworkUrl(raw['album']?['cover_xl']) case final url?)
            if (_artScore(
                  title,
                  artist,
                  '${raw['title'] ?? ''}',
                  '${raw['artist']?['name'] ?? ''}',
                ) >=
                .55)
              _ArtCandidate(
                url,
                _artScore(
                  title,
                  artist,
                  '${raw['title'] ?? ''}',
                  '${raw['artist']?['name'] ?? ''}',
                ),
              ),
    ]..sort((a, b) => b.score.compareTo(a.score));
  } catch (_) {
    return [];
  }
}

Future<List<_ArtCandidate>> _fetchLastFmArts(
  String title,
  String artist,
) async {
  if (artist == 'Unknown artist') return [];
  try {
    final t = Uri.encodeComponent(title);
    final a = Uri.encodeComponent(artist);
    final r = await http
        .get(
          Uri.parse(
            'https://ws.audioscrobbler.com/2.0/?method=track.getInfo&api_key=43693facbb24d1ac893a5d813b137c15&track=$t&artist=$a&format=json',
          ),
          headers: {'User-Agent': _artAgent},
        )
        .timeout(const Duration(seconds: 8));
    if (r.statusCode != 200) return [];
    final track = (jsonDecode(r.body) as Map)['track'] as Map?;
    final images = track?['album']?['image'] as List?;
    final foundTitle = '${track?['name'] ?? ''}';
    final foundArtist = '${track?['artist']?['name'] ?? artist}';
    final score = _artScore(title, artist, foundTitle, foundArtist);
    if (score < .55 || images == null) return [];
    final urls = <_ArtCandidate>[];
    for (final image in images.reversed) {
      if (image is Map) {
        final url = _largeArtworkUrl(image['#text']);
        if (url != null && !url.contains('2a96cbd8b46e442fc41c2b86b821562f')) {
          urls.add(_ArtCandidate(url, score));
        }
      }
    }
    return urls;
  } catch (_) {
    return [];
  }
}

// MusicBrainz release → Cover Art Archive. The archive is a useful final
// fallback because it is community-curated and does not require an API key.
Future<List<_ArtCandidate>> _fetchCoverArtArchive(
  String title,
  String artist,
) async {
  try {
    final q = Uri.encodeComponent(
      artist == 'Unknown artist'
          ? 'release:"$title"'
          : 'release:"$title" AND artist:"$artist"',
    );
    final mb = await http
        .get(
          Uri.parse(
            'https://musicbrainz.org/ws/2/release/?query=$q&limit=5&fmt=json',
          ),
          headers: {'User-Agent': _artAgent},
        )
        .timeout(const Duration(seconds: 8));
    if (mb.statusCode != 200) return [];
    final releases = (jsonDecode(mb.body) as Map)['releases'] as List?;
    if (releases == null) return [];
    final candidates = <_ArtCandidate>[];
    for (final raw in releases) {
      if (raw is! Map) continue;
      final mbid = raw['id'] as String?;
      if (mbid == null) continue;
      final ca = await http
          .get(
            Uri.parse('https://coverartarchive.org/release/$mbid/front-500'),
            headers: {'User-Agent': _artAgent},
          )
          .timeout(const Duration(seconds: 8));
      if (ca.statusCode == 200 || ca.statusCode == 307) {
        candidates.add(
          _ArtCandidate(
            ca.statusCode == 307
                ? (ca.headers['location'] ?? '')
                : 'https://coverartarchive.org/release/$mbid/front-500',
            .58,
          ),
        );
      }
      if (candidates.length >= 3) break;
    }
    return candidates.where((c) => c.url.isNotEmpty).toList();
  } catch (_) {
    return [];
  }
}

Future<bool> _isUsableArt(Uint8List bytes) async {
  if (bytes.isEmpty || bytes.length > _maxArtBytes) return false;
  try {
    final codec = await ui
        .instantiateImageCodec(bytes)
        .timeout(const Duration(seconds: 5));
    final frame = await codec.getNextFrame();
    final width = frame.image.width;
    final height = frame.image.height;
    final valid =
        width >= 64 && height >= 64 && width <= 4096 && height <= 4096;
    frame.image.dispose();
    codec.dispose();
    return valid;
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> _downloadArt(String url) async {
  try {
    final r = await http
        .get(Uri.parse(url), headers: {'User-Agent': _artAgent})
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200 || r.bodyBytes.length > _maxArtBytes) return null;
    final type = r.headers['content-type']?.toLowerCase() ?? '';
    if (type.isNotEmpty &&
        !type.startsWith('image/') &&
        !type.contains('octet-stream'))
      return null;
    final bytes = Uint8List.fromList(r.bodyBytes);
    return await _isUsableArt(bytes) ? bytes : null;
  } catch (_) {
    return null;
  }
}

// Query several independent catalogs, rank matches, and validate every image
// before caching it. A bad response from one provider cannot block the others.
Future<Uint8List?> _fetchArtBytes(String title, String artist) async {
  final results = await Future.wait<List<_ArtCandidate>>([
    _fetchItunesArts(title, artist),
    _fetchDeezerArts(title, artist),
    _fetchLastFmArts(title, artist),
    _fetchCoverArtArchive(title, artist),
  ]);
  final candidates = [for (final source in results) ...source]
    ..sort((a, b) => b.score.compareTo(a.score));
  final tried = <String>{};
  for (final candidate in candidates) {
    if (!tried.add(candidate.url)) continue;
    final bytes = await _downloadArt(candidate.url);
    if (bytes != null) return bytes;
  }
  return null;
}

// Fuzzy string similarity: ratio of common chars to max length (0..1)
double _similarity(String a, String b) {
  final s1 = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final s2 = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (s1.isEmpty && s2.isEmpty) return 1;
  if (s1.isEmpty || s2.isEmpty) return 0;
  // Count matching chars via frequency maps
  final freq = <String, int>{};
  for (final c in s1.split('')) freq[c] = (freq[c] ?? 0) + 1;
  var common = 0;
  for (final c in s2.split('')) {
    if ((freq[c] ?? 0) > 0) {
      common++;
      freq[c] = freq[c]! - 1;
    }
  }
  return common / (s1.length > s2.length ? s1.length : s2.length);
}

// Feature 2b: returns both plain and synced lyrics; fuzzy-scores results when artist unknown
// Fallback plain-lyrics source when LRCLIB has nothing.
Future<String?> _fetchLyricsOvh(String title, String artist) async {
  if (artist == 'Unknown artist') return null;
  try {
    final url =
        'https://api.lyrics.ovh/v1/'
        '${Uri.encodeComponent(_cleanTitle(artist))}/'
        '${Uri.encodeComponent(_cleanTitle(title))}';
    _lyricLog('[lyrics] ovh GET $url');
    final r = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    _lyricLog('[lyrics] ovh status ${r.statusCode}');
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final txt = (j['lyrics'] as String?)?.trim();
    return (txt == null || txt.isEmpty) ? null : txt;
  } catch (e) {
    _lyricLog('[lyrics] ovh err $e');
    return null;
  }
}

String _cleanTitle(String t) {
  var s = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
  s = s.replaceAll(
    RegExp(r'\s+(feat\.?|ft\.?)\s.*$', caseSensitive: false),
    ' ',
  );
  s = s.replaceAll(
    RegExp(
      r'\s*-?\s*(official( music)? (video|audio)|lyrics?( video)?|lyrical|full (video|song)|audio|video|hd|hq)\s*$',
      caseSensitive: false,
    ),
    ' ',
  );
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? t.trim() : s;
}

Future<Map<String, String?>> _fetchLrcLibLyrics(
  String title,
  String artist, {
  int durMs = 0,
}) async {
  final unknown = artist == 'Unknown artist';
  final t = _cleanTitle(title);
  String enc(String x) => Uri.encodeComponent(x);

  _lyricLog('[lyrics] -- title="$t" artist="$artist" durMs=$durMs');

  Map? best;
  var bestScore = -1.0;
  final seen = <String>{};

  Future<void> collect(String url, {String tag = ''}) async {
    try {
      _lyricLog('[lyrics] $tag GET $url');
      final r = await http
          .get(
            Uri.parse(url),
            headers: {'User-Agent': 'SoundWave/1.0 (soundwave-app)'},
          )
          .timeout(const Duration(seconds: 12));
      _lyricLog('[lyrics] $tag status ${r.statusCode} len=${r.body.length}');
      if (r.statusCode != 200) return;
      dynamic decoded;
      try {
        decoded = jsonDecode(r.body);
      } catch (e) {
        _lyricLog('[lyrics] $tag parse err $e');
        return;
      }
      final list = decoded is List ? decoded : [decoded];
      _lyricLog('[lyrics] $tag results ${list.length}');
      for (final raw in list) {
        if (raw is! Map) continue;
        final id = raw['id'];
        if (id != null && !seen.add('$id')) continue;
        final synced = ((raw['syncedLyrics'] as String?) ?? '').trim();
        final plain = ((raw['plainLyrics'] as String?) ?? '').trim();
        if (synced.isEmpty && plain.isEmpty) continue;
        final rawTitle = (raw['trackName'] as String?) ?? '';
        final rawArtist = (raw['artistName'] as String?) ?? '';
        final ts = _similarity(t, rawTitle);
        final as = unknown ? 1.0 : _similarity(artist, rawArtist);
        _lyricLog(
          '[lyrics] $tag cand "$rawTitle" / "$rawArtist" '
          'ts=${ts.toStringAsFixed(2)} as=${as.toStringAsFixed(2)}',
        );
        if (ts < 0.45) continue;
        var score = ts + 0.45 * as;
        final d = raw['duration'];
        if (durMs > 0 && d is num) {
          final diff = (d * 1000 - durMs).abs();
          if (diff < 3000)
            score += 0.3;
          else if (diff > 20000)
            score -= 0.2;
        }
        if (synced.isNotEmpty) score += 0.05;
        if (score > bestScore) {
          bestScore = score;
          best = raw;
        }
      }
    } catch (e) {
      _lyricLog('[lyrics] $tag err $e');
    }
  }

  if (!unknown) {
    final dur = durMs > 0 ? '&duration=${(durMs / 1000).round()}' : '';
    await collect(
      'https://lrclib.net/api/get?artist_name=${enc(artist)}&track_name=${enc(t)}$dur',
      tag: 'get',
    );
  }
  if (best == null && !unknown) {
    await collect(
      'https://lrclib.net/api/search?track_name=${enc(t)}&artist_name=${enc(artist)}',
      tag: 's-ta',
    );
    await collect(
      'https://lrclib.net/api/search?q=${enc('$t $artist')}',
      tag: 's-q-ta',
    );
  }
  if (best == null) {
    await collect(
      'https://lrclib.net/api/search?track_name=${enc(t)}',
      tag: 's-t',
    );
    await collect('https://lrclib.net/api/search?q=${enc(t)}', tag: 's-q-t');
  }
  if (best == null) {
    final ovh = await _fetchLyricsOvh(title, artist);
    if (ovh != null) {
      _lyricLog('[lyrics] ovh HIT len=${ovh.length}');
      return {'plain': ovh, 'synced': null};
    }
  }
  if (best == null) {
    _lyricLog('[lyrics] -- NOTHING FOUND');
    return {'plain': null, 'synced': null};
  }
  final bestMap = best!;
  _lyricLog('[lyrics] -- BEST "${bestMap['trackName']}" score=$bestScore');
  final synced = ((bestMap['syncedLyrics'] as String?) ?? '').trim();
  final plain = ((bestMap['plainLyrics'] as String?) ?? '').trim();
  return {
    'plain': plain.isEmpty ? null : plain,
    'synced': synced.isEmpty ? null : synced,
  };
}

// ---- Piped search + download (replaces Invidious)
// ---- YouTube search + stream via youtube_explode_dart (no third-party instances)
final _yt = YoutubeExplode();

class InvResult {
  final String videoId, title, author, thumbnail;
  final int lengthSeconds;
  InvResult({
    required this.videoId,
    required this.title,
    required this.author,
    required this.thumbnail,
    required this.lengthSeconds,
  });
}

class BatchDownloadTask {
  final String id, query;
  String status = 'Queued';
  double progress = 0;
  String? error;
  InvResult? result;

  BatchDownloadTask(this.id, this.query);

  bool get finished => status == 'Complete' || status == 'Skipped';
}

Future<List<InvResult>> invSearch(String q) async {
  final results = await _yt.search.search(q);
  return results
      .where((v) {
        final secs = v.duration?.inSeconds ?? 0;
        // Filter out non-music: tutorials, full courses, podcasts (>12 min),
        // and very short clips (<30s). Also skip obvious non-music keywords.
        if (secs > 0 && (secs < 30 || secs > 600)) return false;
        final low = v.title.toLowerCase();
        const skip = [
          'tutorial', 'how to', 'course', 'learn', 'lesson',
          'lecture', 'guide', 'full course', 'explained', 'review',
          'podcast', 'interview', 'episode', 'react', 'reacts',
          'reaction', 'commentary', 'gameplay', 'highlights', 'trailer',
          'teaser', 'behind the scenes', 'documentary', 'what is',
          'beginners', 'masterclass', 'bootcamp', 'vlog',
        ];
        if (skip.any((k) => low.contains(k))) return false;
        return true;
      })
      .map(
        (v) => InvResult(
          videoId: v.id.value,
          title: v.title,
          author: v.author,
          thumbnail: v.thumbnails.highResUrl,
          lengthSeconds: v.duration?.inSeconds ?? 0,
        ),
      )
      .toList();
}

// ── Audio stream pipeline ────────────────────────────────────────────────────
// Priority order:
//   1. Self-hosted yt-dlp backend  (most reliable — updated daily vs YT)
//   2. Invidious public instances  (fast when alive — server-side extraction)
//   3. Piped API instances         (separate infra from Invidious)
//   4. youtube_explode_dart        (pure-Dart fallback — m4a then opus/webm)
//
// Dead-host blacklist: any host that fails is skipped for the rest of the
// app session, so subsequent downloads don't burn time on known-dead servers.
// ─────────────────────────────────────────────────────────────────────────────

// Invidious: official list from api.invidious.io (https-only, api=true)
const _invHosts = [
  'https://inv.nadeko.net',
  'https://invidious.nerdvpn.de',
  'https://invidious.tiekoetter.com',
  'https://invidious.f5.si',
  'https://yt.chocolatemoo53.com',
  'https://invidious.privacyredirect.com',
  'https://invidious.lunar.icu',
  'https://invidious.io.lol',
];

// Piped: alternative YT frontend with independent infra — different failure modes
const _pipedHosts = [
  'https://pipedapi.kavin.rocks',
  'https://pipedapi.adminforge.de',
  'https://pipedapi.drgns.space',
];

// Session-scoped dead host blacklist — reset on app restart
final _deadHosts = <String>{};

String _lastStreamError = '';

class _AudioStream {
  final http.StreamedResponse response;
  final http.Client client;
  const _AudioStream(this.response, this.client);
}

// Try a single HTTP GET, return stream or null. Marks host dead on failure.
Future<_AudioStream?> _tryGet(String urlStr, {int timeoutSec = 6}) async {
  final uri = Uri.parse(urlStr);
  final host = '${uri.scheme}://${uri.host}';
  if (_deadHosts.contains(host)) return null;
  final client = http.Client();
  try {
    final resp = await client
        .send(http.Request('GET', uri))
        .timeout(Duration(seconds: timeoutSec));
    if (resp.statusCode == 200) return _AudioStream(resp, client);
    client.close();
    // 4xx = instance is alive but rejected us — don't blacklist
    if (resp.statusCode >= 500) _deadHosts.add(host);
    return null;
  } catch (_) {
    client.close();
    _deadHosts.add(host); // timeout / connection refused — host is dead
    return null;
  }
}

Future<_AudioStream?> _openAudioStream(String videoId) async {
  final failures = <String>[];

  // ── 1. Self-hosted yt-dlp backend ──────────────────────────────────────────
  if (kYtApiBase.isNotEmpty) {
    final client = http.Client();
    try {
      final url = Uri.parse('$kYtApiBase/audio?id=$videoId&key=$kYtApiKey');
      final resp = await client
          .send(http.Request('GET', url))
          .timeout(const Duration(seconds: 60)); // longer — DietPi can be slow
      if (resp.statusCode == 200) return _AudioStream(resp, client);
      failures.add('ytapi:${resp.statusCode}');
      client.close();
    } catch (e) {
      client.close();
      failures.add('ytapi:${e.runtimeType}');
    }
  }

  // ── 2. Invidious instances ──────────────────────────────────────────────────
  for (final host in _invHosts) {
    final stream = await _tryGet('$host/latest_version?id=$videoId&itag=140');
    if (stream != null) return stream;
    failures.add('$host:fail');
  }

  // ── 3. Piped API ────────────────────────────────────────────────────────────
  for (final host in _pipedHosts) {
    if (_deadHosts.contains(host)) continue;
    final client = http.Client();
    try {
      final infoUrl = Uri.parse('$host/streams/$videoId');
      final infoResp = await client
          .get(infoUrl)
          .timeout(const Duration(seconds: 8));
      if (infoResp.statusCode == 200) {
        final j = jsonDecode(infoResp.body) as Map<String, dynamic>;
        final streams = (j['audioStreams'] as List? ?? []);
        // Prefer m4a (itag 140) for ExoPlayer compatibility
        final m4a = streams.where((s) =>
            (s['mimeType'] as String? ?? '').contains('mp4a')).toList();
        final best = m4a.isNotEmpty ? m4a : streams;
        if (best.isNotEmpty) {
          best.sort((a, b) =>
              (b['bitrate'] as int? ?? 0).compareTo(a['bitrate'] as int? ?? 0));
          final audioUrl = best.first['url'] as String?;
          if (audioUrl != null) {
            final stream = await _tryGet(audioUrl, timeoutSec: 8);
            if (stream != null) { client.close(); return stream; }
          }
        }
      }
      client.close();
      if (infoResp.statusCode >= 500) _deadHosts.add(host);
      failures.add('$host:${infoResp.statusCode}');
    } catch (e) {
      client.close();
      _deadHosts.add(host);
      failures.add('$host:${e.runtimeType}');
    }
  }

  // ── 4. youtube_explode_dart ─────────────────────────────────────────────────
  try {
    final manifest = await _yt.videos.streamsClient
        .getManifest(videoId)
        .timeout(const Duration(seconds: 20));
    final audioOnly = manifest.audioOnly.toList();
    // Prefer m4a (ExoPlayer handles it without remux), fall back to opus/webm
    final m4a = audioOnly.where((s) => s.codec.mimeType.contains('mp4a')).toList();
    final opus = audioOnly.where((s) => s.codec.mimeType.contains('opus')).toList();
    final candidates = m4a.isNotEmpty ? m4a : opus;
    if (candidates.isEmpty) {
      failures.add('yt-explode:no-audio-stream');
    } else {
      candidates.sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      for (final s in candidates.take(3)) {
        final stream = await _tryGet(s.url.toString(), timeoutSec: 12);
        if (stream != null) return stream;
        failures.add('yt-explode:${s.codec.mimeType}:fail');
      }
    }
  } catch (e) {
    failures.add('yt-explode:${e.runtimeType}');
  }

  _lastStreamError = failures.join(', ');
  return null;
}

// Feature 2c: LRC parser
List<({int ms, String line})> parseLrc(String lrc) {
  final timeRe = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
  final result = <({int ms, String line})>[];
  for (final rawLine in lrc.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final matches = timeRe.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final text = line.substring(matches.last.end).trim();
    if (text.isEmpty) continue;
    for (final m in matches) {
      final mins = int.parse(m.group(1)!);
      final secs = int.parse(m.group(2)!);
      final frac = m.group(3);
      int ms = 0;
      if (frac != null) {
        if (frac.length == 1) {
          ms = int.parse(frac) * 100;
        } else if (frac.length == 2) {
          ms = int.parse(frac) * 10;
        } else {
          ms = int.parse(frac.substring(0, 3));
        }
      }
      result.add((ms: mins * 60000 + secs * 1000 + ms, line: text));
    }
  }
  result.sort((a, b) => a.ms.compareTo(b.ms));
  return result;
}

final store = Store();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.soundwave.audio',
    androidNotificationChannelName: 'SoundWave playback',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
    artDownscaleWidth: 300,
    artDownscaleHeight: 300,
  );
  // Handle playback errors gracefully — skip to next track instead of crashing.
  player.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
    if (player.hasNext) {
      player.seekToNext();
    } else {
      player.stop();
    }
  });

  await store.load();
  runApp(const SoundWaveApp());
}

class SoundWaveApp extends StatelessWidget {
  const SoundWaveApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SoundWave',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(primary: green),
      scaffoldBackgroundColor: const Color(0xFF121212),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFF000000),
        indicatorColor: Color(0xFF2A2A2A),
      ),
    ),
    home: const Home(),
  );
}

// ---------------------------------------------------------------- models
class Song {
  final String id, path;
  String title, artist;
  String? art, lyrics, syncedLyrics; // Feature 2a: added syncedLyrics
  int dur;
  bool own;
  bool tagsBad; // true = artist is still unknown after all enrichment attempts
  String? videoId; // YouTube video ID if downloaded from YouTube
  Song(
    this.id,
    this.title,
    this.artist,
    this.path, {
    this.art,
    this.lyrics,
    this.syncedLyrics,
    this.dur = 0,
    this.own = true,
    this.tagsBad = false,
    this.videoId,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'path': path,
    'art': art,
    'lyrics': lyrics,
    'syncedLyrics': syncedLyrics,
    'dur': dur,
    'own': own,
    'tagsBad': tagsBad,
    'videoId': videoId,
  };
  factory Song.fromJson(Map j) => Song(
    j['id'],
    j['title'],
    j['artist'],
    j['path'],
    art: j['art'],
    lyrics: j['lyrics'] ?? j['lyricsUrl'],
    syncedLyrics: j['syncedLyrics'],
    dur: j['dur'] ?? 0,
    own: j['own'] ?? true,
    tagsBad: j['tagsBad'] ?? false,
    videoId: j['videoId'],
  );
}

class Playlist {
  final String id;
  String name;
  List<String> ids;
  Playlist(this.id, this.name, this.ids);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'ids': ids};
  factory Playlist.fromJson(Map j) =>
      Playlist(j['id'], j['name'], List<String>.from(j['ids']));
}

// ---------------------------------------------------------------- store
class Store extends ChangeNotifier {
  List<Song> songs = [], queue = [];
  Set<String> liked = {};
  List<Playlist> lists = [];
  List<String> folders = [];
  List<String> recentIds = []; // Feature 1: recently played
  bool shuffle = false, ready = false;
  LoopMode loop = LoopMode.off;
  double speed = 1.0;
  DateTime? sleepAt;
  Timer? _sleep;
  String? busy, updateUrl, updateTag;
  double? updatePct;
  bool updating = false;
  final List<BatchDownloadTask> batchQueue = [];
  bool batchRunning = false;
  int batchCompleted = 0;
  int batchTotal = 0;
  String? batchMessage;
  Future<void>? _batchWorker;
  late SharedPreferences prefs;
  final cache = LocalCache();
  Timer? _saveTimer;
  Future<void> _saveInFlight = Future.value();

  Song? byId(String id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  void ping() => notifyListeners();
  void touch() {
    save();
    notifyListeners();
  }

  Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    await cache.init();
    final raw = prefs.getString('songs');
    if (raw != null) {
      songs = (jsonDecode(raw) as List)
          .map((e) => Song.fromJson(e as Map))
          .where((s) => File(s.path).existsSync())
          .toList();
      // Art and lyric files are validated lazily when a song is displayed or
      // enriched; startup should not perform one disk read per library item.
    }
    final pl = prefs.getString('lists');
    if (pl != null)
      lists = (jsonDecode(pl) as List)
          .map((e) => Playlist.fromJson(e as Map))
          .toList();
    liked = (prefs.getStringList('liked') ?? []).toSet();
    folders = prefs.getStringList('folders') ?? [];
    recentIds = prefs.getStringList('recents') ?? []; // Feature 1
    ready = true;
    notifyListeners();
    Permission.notification.request();
    checkUpdate();
  }

  void save() {
    // Coalesce bursts from playback/enrichment so JSON encoding and disk I/O do
    // not run once per position or metadata update.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      final songJson = jsonEncode(songs.map((s) => s.toJson()).toList());
      final listJson = jsonEncode(lists.map((l) => l.toJson()).toList());
      _saveInFlight = _saveInFlight.then((_) async {
        await prefs.setString('songs', songJson);
        await prefs.setString('lists', listJson);
        await prefs.setStringList('liked', liked.toList());
        await prefs.setStringList('folders', folders);
        await prefs.setStringList('recents', recentIds);
      });
    });
  }

  void like(String id) {
    liked.contains(id) ? liked.remove(id) : liked.add(id);
    touch();
  }

  Playlist newList(String name, {String? add}) {
    final l = Playlist(
      'p${DateTime.now().microsecondsSinceEpoch}',
      name,
      add != null ? [add] : [],
    );
    lists.add(l);
    touch();
    return l;
  }

  void addTo(Playlist l, String id) {
    if (!l.ids.contains(id)) l.ids.add(id);
    touch();
  }

  // ---- in-app updates (from your GitHub releases)
  Future<void> checkUpdate() async {
    if (kRepo.isEmpty) return;
    try {
      final r = await http
          .get(
            Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map;
      final tag = '${j['tag_name']}';
      final build = int.tryParse(tag.split('.').last) ?? 0;
      String? url;
      for (final a in (j['assets'] as List)) {
        if ('${a['name']}'.endsWith('.apk'))
          url = '${a['browser_download_url']}';
      }
      if (url != null && kTag.isNotEmpty && tag != kTag) {
        updateUrl = url;
        updateTag = tag;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<String> installUpdate() async {
    final url = updateUrl;
    if (url == null || updating) return '';
    updating = true;
    updatePct = 0;
    notifyListeners();
    try {
      final client = http.Client();
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      final total = resp.contentLength ?? 0;
      final file = File(
        p.join((await getTemporaryDirectory()).path, 'SoundWave-update.apk'),
      );
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          updatePct = got / total;
          notifyListeners();
        }
      }
      await sink.close();
      client.close();
      updating = false;
      updatePct = null;
      notifyListeners();
      await OpenFilex.open(
        file.path,
        type: 'application/vnd.android.package-archive',
      );
      return '';
    } catch (_) {
      updating = false;
      updatePct = null;
      notifyListeners();
      return 'Update failed. Check your connection and try again.';
    }
  }

  // ---- tags + album art
  Future<String?> _saveArt(String id, List<int> bytes) async {
    final imageBytes = Uint8List.fromList(bytes);
    if (!await _isUsableArt(imageBytes)) return null;
    return cache.saveArt(id, imageBytes);
  }

  Future<void> _applyTags(Song s) async {
    try {
      final m = md.readMetadata(File(s.path), getImage: true);
      if ((m.title ?? '').trim().isNotEmpty) s.title = m.title!.trim();
      if ((m.artist ?? '').trim().isNotEmpty) s.artist = m.artist!.trim();
      final d = m.duration;
      if (d != null) s.dur = d.inMilliseconds;
      if (m.pictures.isNotEmpty) {
        final path = await _saveArt(s.id, m.pictures.first.bytes);
        if (path != null) s.art = path;
      }
    } catch (_) {}
  }

  Future<void> _enrich(Song s) async {
    // MusicBrainz removed — too many false positives overwriting correct data.
    // Mark song as needing manual tag fix if artist still unknown
    s.tagsBad = s.artist == 'Unknown artist';
    // Clear previously fetched art for unknown-artist songs — it's likely wrong.
    if (s.tagsBad && s.art != null) {
      try { await File(s.art!).delete(); } catch (_) {}
      s.art = null;
    }
    if (s.art != null && !await LocalCache.validFile(s.art)) s.art = null;
    if (s.art == null && s.artist != 'Unknown artist') {
      final bytes = await _fetchArtBytes(s.title, s.artist);
      if (bytes != null) s.art = await _saveArt(s.id, bytes);
    }
    // Feature 2b: fetch both plain and synced lyrics
    final cached = await cache.readLyrics(s.id);
    if (cached != null) {
      s.lyrics = cached['plain'];
      s.syncedLyrics = cached['synced'];
      return;
    }
    final lyricsMap = await _fetchLrcLibLyrics(s.title, s.artist, durMs: s.dur);
    if (lyricsMap['plain'] != null) s.lyrics = lyricsMap['plain'];
    if (lyricsMap['synced'] != null) s.syncedLyrics = lyricsMap['synced'];
    await cache.saveLyrics(s.id, s.lyrics, s.syncedLyrics);
  }

  Future<String> refreshTags() async {
    for (var i = 0; i < songs.length; i++) {
      busy = 'Reading tags ${i + 1} of ${songs.length}…';
      notifyListeners();
      await Future.delayed(Duration.zero);
      await _applyTags(songs[i]);
    }
    busy = null;
    touch();
    return 'Album art refreshed';
  }

  Future<String> reenrichAll() async {
    for (var i = 0; i < songs.length; i++) {
      busy = 'Fetching lyrics & artist ${i + 1} of ${songs.length}…';
      notifyListeners();
      await Future.delayed(Duration.zero);
      // Clear both in-memory and disk lyrics so they get re-fetched.
      songs[i].lyrics = null;
      songs[i].syncedLyrics = null;
      await cache.removeLyrics(songs[i].id);
      await _enrich(songs[i]);
    }
    busy = null;
    touch();
    return 'Lyrics & artist info refreshed';
  }

  // ---- download from Invidious
  // Returns error string or '' on success
  Future<String> downloadFromInvidious(
    InvResult result,
    void Function(double) onProgress,
  ) async {
    // Deduplicate by videoId
    if (songs.any((s) => s.videoId == result.videoId)) {
      return 'Already in your library';
    }
    final dir = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'music'),
    );
    await dir.create(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}';
    final tempPath = p.join(dir.path, '.$id.part');
    String? path;
    try {
      // Re-open the stream after a transient network failure. A partial file
      // is never added to the library and is removed before the next attempt.
      for (var attempt = 1; attempt <= 3; attempt++) {
        final audio = await _openAudioStream(result.videoId);
        if (audio == null) {
          if (attempt == 3)
            return 'Could not get audio stream ($_lastStreamError)';
          await Future.delayed(Duration(seconds: attempt * 2));
          continue;
        }
        final resp = audio.response;
        final client = audio.client;
        // Determine container from backend hint, then content-type, then default m4a
        String ext;
        if (resp.headers['x-audio-ext'] != null) {
          ext = '.${resp.headers['x-audio-ext']}';
        } else {
          final ct = resp.headers['content-type'] ?? '';
          if (ct.contains('webm') || ct.contains('opus')) {
            ext = '.webm';
          } else if (ct.contains('ogg')) {
            ext = '.ogg';
          } else {
            ext = '.m4a';
          }
        }
        path = p.join(dir.path, '$id$ext');
        final total = resp.contentLength ?? 0;
        var got = 0;
        IOSink? sink;
        try {
          sink = File(tempPath).openWrite();
          await resp.stream
              .timeout(const Duration(seconds: 10))
              .forEach((chunk) {
                sink!.add(chunk);
                got += chunk.length;
                if (total > 0) onProgress(got / total);
              })
              .timeout(const Duration(seconds: 90));
          await sink.flush();
          await sink.close();
          sink = null;
          // Rename only after the complete stream has been flushed.
          await File(tempPath).rename(path);
          client.close();
          break;
        } catch (_) {
          client.close();
          try {
            await sink?.close();
          } catch (_) {}
          try {
            await File(tempPath).delete();
          } catch (_) {}
          path = null;
          if (attempt == 3)
            return 'Download interrupted. Check your connection and try again.';
          await Future.delayed(Duration(seconds: attempt * 2));
        }
      }
      final completedPath = path;
      if (completedPath == null || !await LocalCache.validFile(completedPath)) {
        if (completedPath != null) {
          try {
            await File(completedPath).delete();
          } catch (_) {}
        }
        return 'Download did not complete';
      }
      // Parse title/artist from result
      var title = result.title;
      var artist = result.author;
      // Clean up "- Topic" from auto-generated channels
      artist = artist
          .replaceAll(RegExp(r'\s*-\s*Topic$', caseSensitive: false), '')
          .trim();
      // Try "Artist - Title" split — only if left part looks like a short artist name
      // (≤ 4 words). Avoids misparse of Spanish/multi-word song titles like
      // "El Castillo De Dracula - Juanjo Papa Vampiro".
      final parts = title.split(' - ');
      if (parts.length > 1) {
        final candidate = parts.first.trim();
        final wordCount = candidate.split(RegExp(r'\s+')).length;
        if (wordCount <= 4) {
          artist = candidate;
          title = parts.sublist(1).join(' - ').trim();
        }
      }
      // Also use channel name as artist if it looks cleaner than "Artist - Title" parse
      // and we didn't get a good split (artist still from channel).
      // Strip download site noise and YouTube video title junk
      title = title
          .replaceAll(
            RegExp(
              r'\s*\(?(mp3\.pm|SpotiDownloader\.com|ytmp3\.cc|y2mate|tubidy|mp3juice|320kbps|fakaza|skull|beemp3s?|downloadming|djjohal|songspk|pagalworld|mrjatt|mp3paw|audiomack\.com|soundcloud\.com|Official\s*(Video|Audio|Lyric\s*Video|Music\s*Video)?)\)?\s*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      title = _cleanTitle(title);
      final s = Song(
        id,
        title,
        artist,
        completedPath,
        own: true,
        videoId: result.videoId,
      );
      // Make the download playable immediately; enrichment can happen when
      // the track is first played and must not delay queue insertion.
      await _applyTags(s);
      songs.insert(0, s);
      // Batch downloads must finish enrichment before the next item starts so
      // each imported track has artwork and cached lyrics when the queue ends.
      await _enrich(s);
      touch();
      return '';
    } catch (e) {
      try {
        await File(tempPath).delete();
      } catch (_) {}
      if (path != null) {
        try {
          await File(path!).delete();
        } catch (_) {}
      }
      return 'Download failed: $e';
    }
  }

  // ---- playlist and batch download queue
  bool _isPlaylistInput(String input) =>
      input.contains('youtube.com/playlist') ||
      (input.contains('youtube.com/watch') && input.contains('list=')) ||
      (input.contains('youtu.be/') && input.contains('list='));

  bool _isSpotifyPlaylist(String input) =>
      input.contains('open.spotify.com/playlist/') ||
      input.contains('spotify.com/playlist/') ||
      input.contains('spotify:playlist:');

  Future<List<Map<String, String>>> _fetchSpotifyPlaylist(String url) async {
    try {
      // Extract playlist ID from various Spotify URL formats
      final idMatch = RegExp(
        r'(?:open\.spotify\.com/playlist/|spotify\.com/playlist/|spotify:playlist:)([a-zA-Z0-9]+)',
      ).firstMatch(url);
      if (idMatch == null) return [];

      final playlistId = idMatch.group(1)!;
      final pageUrl = 'https://open.spotify.com/playlist/$playlistId';

      // Fetch the public playlist page
      final response = await http
          .get(Uri.parse(pageUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return [];

      // Parse JSON-LD structured data embedded in the page
      final jsonLdMatch = RegExp(
        r'<script type="application/ld\+json">(.+?)</script>',
        dotAll: true,
      ).firstMatch(response.body);

      if (jsonLdMatch != null) {
        try {
          final data = jsonDecode(jsonLdMatch.group(1)!) as Map;
          if (data['@type'] == 'MusicPlaylist') {
            final tracks = (data['track'] as List?) ?? [];
            return [
              for (final track in tracks.take(200))
                if (track is Map)
                  {
                    'title': '${track['name'] ?? ''}',
                    'artist':
                        '${(track['byArtist'] as Map?)?['name'] ?? 'Unknown'}',
                  },
            ];
          }
        } catch (_) {}
      }

      // Fallback: extract from embedded Spotify state JSON
      final stateMatch = RegExp(
        r'<script id="__NEXT_DATA__" type="application/json">(.+?)</script>',
      ).firstMatch(response.body);

      if (stateMatch != null) {
        try {
          final state = jsonDecode(stateMatch.group(1)!) as Map;
          final entities =
              state['props']?['pageProps']?['state']?['data']?['entity']
                  as Map?;
          final trackList = entities?['trackList'] as List?;
          if (trackList != null) {
            return [
              for (final item in trackList.take(200))
                if (item is Map && item['isAvailable'] == true)
                  {
                    'title': '${item['name'] ?? ''}',
                    'artist': '${item['artists']?.first?['name'] ?? 'Unknown'}',
                  },
            ];
          }
        } catch (_) {}
      }

      return [];
    } catch (_) {
      return [];
    }
  }

  String _batchQuery(String line) {
    final value = line.trim();
    final match = RegExp(r'^(.*?)\s+[-–—|]\s+(.*?)$').firstMatch(value);
    if (match == null) return value;
    final left = match.group(1)!.trim();
    final right = match.group(2)!.trim();
    // Accept the common "Artist - Title" format while avoiding a second
    // split for ordinary titles that contain a dash.
    return left.split(RegExp(r'\s+')).length <= 6 ? '$left $right' : value;
  }

  Future<List<BatchDownloadTask>> _parseBatchInput(String input) async {
    final value = input.trim();
    if (value.isEmpty) return [];

    // YouTube playlist
    if (_isPlaylistInput(value)) {
      final tasks = <BatchDownloadTask>[];
      var index = 0;
      await for (final video in _yt.playlists.getVideos(value).take(200)) {
        final result = InvResult(
          videoId: video.id.value,
          title: video.title,
          author: video.author,
          thumbnail: video.thumbnails.highResUrl,
          lengthSeconds: video.duration?.inSeconds ?? 0,
        );
        final task = BatchDownloadTask('playlist-$index', video.title)
          ..result = result;
        tasks.add(task);
        index++;
      }
      return tasks;
    }

    // Spotify playlist
    if (_isSpotifyPlaylist(value)) {
      final tracks = await _fetchSpotifyPlaylist(value);
      if (tracks.isEmpty) return [];
      return [
        for (var i = 0; i < tracks.length; i++)
          BatchDownloadTask(
            'spotify-$i',
            '${tracks[i]['artist']} - ${tracks[i]['title']}',
          ),
      ];
    }

    // Newline-separated song list
    final lines = value
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(200)
        .toList();
    return [
      for (var i = 0; i < lines.length; i++)
        BatchDownloadTask(
          'query-${DateTime.now().microsecondsSinceEpoch}-$i',
          _batchQuery(lines[i]),
        ),
    ];
  }

  Future<String> startBatchDownload(String input) async {
    if (input.trim().isEmpty) return 'Paste a playlist URL or song list first';
    List<BatchDownloadTask> tasks;
    try {
      tasks = await _parseBatchInput(input);
    } catch (e) {
      return 'Could not read playlist: $e';
    }
    if (tasks.isEmpty) {
      return _isPlaylistInput(input) || _isSpotifyPlaylist(input)
          ? 'Playlist has no downloadable tracks'
          : 'No songs found in the list';
    }
    if (!batchRunning && batchQueue.every((task) => task.finished)) {
      batchQueue.clear();
      batchCompleted = 0;
      batchTotal = 0;
    }
    batchQueue.addAll(tasks);
    batchTotal += tasks.length;
    batchMessage = 'Queued ${tasks.length} item${tasks.length == 1 ? '' : 's'}';
    notifyListeners();

    if (_batchWorker == null) {
      final worker = _runBatchQueue();
      _batchWorker = worker;
      worker.whenComplete(() {
        if (identical(_batchWorker, worker)) _batchWorker = null;
      });
    }
    return batchMessage!;
  }

  Future<void> _runBatchQueue() async {
    batchRunning = true;
    notifyListeners();
    try {
      while (true) {
        BatchDownloadTask? task;
        for (final candidate in batchQueue) {
          if (candidate.status == 'Queued') {
            task = candidate;
            break;
          }
        }
        if (task == null) break;
        task.status = 'Finding match';
        task.progress = 0;
        notifyListeners();
        try {
          if (task.result == null) {
            final matches = await invSearch(task.query);
            if (matches.isEmpty) {
              task.status = 'Failed';
              task.error = 'No YouTube match';
              batchCompleted++;
              notifyListeners();
              continue;
            }
            task.result = matches.first;
          }
          final result = task.result!;
          task.status = 'Downloading';
          notifyListeners();
          final error = await downloadFromInvidious(result, (progress) {
            task!.progress = progress.clamp(0, 1).toDouble();
            notifyListeners();
          });
          if (error.isEmpty) {
            task.status = 'Complete';
          } else if (error == 'Already in your library') {
            task.status = 'Skipped';
            task.error = error;
          } else {
            task.status = 'Failed';
            task.error = error;
          }
        } catch (e) {
          task.status = 'Failed';
          task.error = '$e';
        }
        batchCompleted++;
        notifyListeners();
      }
    } finally {
      batchRunning = false;
      batchMessage = 'Batch finished: $batchCompleted of $batchTotal processed';
      notifyListeners();
    }
  }

  void clearBatchQueue() {
    if (batchRunning) return;
    batchQueue.clear();
    batchCompleted = 0;
    batchTotal = 0;
    batchMessage = null;
    notifyListeners();
  }

  // ---- reset song back to file tags (clears any bad enrichment data)
  Future<void> resetToFileTags(Song s) async {
    // Baseline from filename
    s.title = _cleanTitle(
      p.basenameWithoutExtension(s.path).replaceAll('_', ' ').trim(),
    );
    s.artist = 'Unknown artist';
    final parts = s.title.split(' - ');
    if (parts.length > 1) {
      s.artist = parts.first.trim();
      s.title = parts.sublist(1).join(' - ').trim();
    }
    // Override with actual embedded tags if present
    await _applyTags(s);
    // Clear lyrics in memory and on disk so they re-fetch with correct metadata.
    s.lyrics = null;
    s.syncedLyrics = null;
    await cache.removeLyrics(s.id);
    s.art = null;
    save();
    notifyListeners();
    // Re-enrich in background
    _enrich(s).then((_) {
      save();
      notifyListeners();
    });
  }

  // ---- manual edit song info
  Future<void> editSongInfo(Song s, String newTitle, String newArtist) async {
    s.title = newTitle.trim().isEmpty ? s.title : newTitle.trim();
    s.artist = newArtist.trim().isEmpty ? s.artist : newArtist.trim();
    // Clear art and lyrics so they all re-fetch with the corrected metadata.
    if (s.art != null) {
      try {
        await File(s.art!).delete();
      } catch (_) {}
      s.art = null;
    }
    s.lyrics = null;
    s.syncedLyrics = null;
    await cache.removeLyrics(s.id);
    save();
    notifyListeners();
    // Re-fetch in background
    _enrich(s).then((_) {
      save();
      notifyListeners();
    });
  }

  // ---- importing
  Future<int> _import(List<MapEntry<String, String>> items, bool own) async {
    final dir = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'music'),
    );
    await dir.create(recursive: true);
    var n = 0;
    for (var i = 0; i < items.length; i++) {
      busy = 'Adding ${i + 1} of ${items.length}…';
      notifyListeners();
      await Future.delayed(Duration.zero);
      final src = items[i].key;
      if (!own && songs.any((s) => s.path == src)) continue;
      final id = '${DateTime.now().microsecondsSinceEpoch}$i';
      var path = src;
      if (own) {
        path = p.join(dir.path, '$id${p.extension(src)}');
        await File(src).copy(path);
      }
      var title = p
          .basenameWithoutExtension(items[i].value)
          .replaceAll('_', ' ')
          .trim();
      // Strip common download-site suffixes and YouTube junk from filenames
      title = title
          .replaceAll(
            RegExp(
              r'\s*\(?(mp3\.pm|SpotiDownloader\.com|ytmp3\.cc|y2mate|tubidy|mp3juice|320kbps|fakaza|skull|beemp3s?|downloadming|djjohal|songspk|pagalworld|mrjatt|mp3paw|audiomack\.com|soundcloud\.com)\)?\s*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      title = _cleanTitle(title);
      var artist = 'Unknown artist';
      final parts = title.split(' - ');
      if (parts.length > 1) {
        final candidate = parts.first.trim();
        if (candidate.split(RegExp(r'\s+')).length <= 4) {
          artist = candidate;
          title = parts.sublist(1).join(' - ').trim();
        }
      }
      final s = Song(id, title, artist, path, own: own);
      // Index metadata first and make the item visible immediately. Album art
      // and lyrics are fetched lazily on playback instead of serially blocking
      // a folder scan on one network request per song.
      await _applyTags(s);
      songs.insert(0, s);
      n++;
    }
    busy = null;
    touch();
    return n;
  }

  Future<String> addPicked() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: true,
    );
    if (res == null) return '';
    final items = <MapEntry<String, String>>[
      for (final f in res.files)
        if (f.path != null) MapEntry(f.path!, f.name),
    ];
    final n = await _import(items, true);
    return 'Added $n song${n == 1 ? '' : 's'}';
  }

  Future<String> scanFolder() async {
    final ok =
        (await Permission.audio.request()).isGranted ||
        (await Permission.storage.request()).isGranted;
    if (!ok) {
      openAppSettings();
      return 'Allow "Music and audio" access for SoundWave, then try again';
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return '';
    if (!folders.contains(dir)) folders.add(dir);
    return _rescan([dir]);
  }

  Future<String> rescan() => folders.isEmpty
      ? Future.value('No folders yet. Use "Scan a folder" first.')
      : _rescan(folders);

  Future<String> _rescan(List<String> dirs) async {
    busy = 'Looking for music…';
    notifyListeners();
    final found = <MapEntry<String, String>>[];
    for (final d in dirs) {
      try {
        await for (final e in Directory(
          d,
        ).list(recursive: true, followLinks: false).handleError((_) {})) {
          if (e is File && _exts.contains(p.extension(e.path).toLowerCase())) {
            found.add(MapEntry(e.path, p.basename(e.path)));
          }
        }
      } catch (_) {}
    }
    found.removeWhere((e) => songs.any((s) => s.path == e.key));
    if (found.isEmpty) {
      busy = null;
      touch();
      return 'No new songs found';
    }
    final n = await _import(found, false);
    return 'Added $n song${n == 1 ? '' : 's'}';
  }

  Future<void> remove(Song s) async {
    final i = player.currentIndex;
    if (i != null && i < queue.length && queue[i].id == s.id)
      await player.stop();
    try {
      if (s.own) await File(s.path).delete();
      if (s.art != null) await File(s.art!).delete();
      await cache.remove(s.id);
    } catch (_) {}
    songs.removeWhere((x) => x.id == s.id);
    liked.remove(s.id);
    recentIds.remove(s.id); // Feature 1: clean up recents
    for (final l in lists) {
      l.ids.remove(s.id);
    }
    touch();
  }

  // ---- playback
  Future<void> play(List<Song> list, int i) async {
    queue = list;
    // Retry enrichment when art is missing as well as when metadata or lyrics
    // are incomplete. This repairs transient catalog/network failures on the
    // next play instead of leaving a track permanently art-less.
    final s = list[i];
    final artMissing = s.art == null || !await LocalCache.validFile(s.art);
    if (s.artist == 'Unknown artist' ||
        artMissing ||
        (s.lyrics == null && s.syncedLyrics == null)) {
      _enrich(s).then((_) async {
        save();
        notifyListeners();
        // Refresh notification art after enrich — rebuild queue in place
        await _refreshCurrentMediaItem();
      });
    }
    // Feature 1: track recently played
    final playedId = list[i].id;
    recentIds.remove(playedId);
    recentIds.insert(0, playedId);
    if (recentIds.length > 10) recentIds = recentIds.sublist(0, 10);
    notifyListeners();
    try {
      await player.setAudioSource(
        ConcatenatingAudioSource(
          children: [
            for (final s in list)
              AudioSource.file(
                s.path,
                tag: MediaItem(
                  id: s.id,
                  title: s.title,
                  artist: s.artist,
                  artUri: s.art != null ? Uri.file(s.art!) : null,
                  duration: s.dur > 0 ? Duration(milliseconds: s.dur) : null,
                ),
              ),
          ],
        ),
        initialIndex: i,
      );
      player.setLoopMode(loop);
      player.setShuffleModeEnabled(shuffle);
      player.setSpeed(speed);
      player.play();
    } catch (_) {
      // Playback setup failed (bad file, ExoPlayer error) — don't crash the app
    }
    // Persist duration once known (YouTube downloads have no embedded duration tag)
    player.durationStream
        .firstWhere((d) => d != null && d.inMilliseconds > 0)
        .then((d) {
          final idx = player.currentIndex;
          if (idx != null && idx < queue.length && queue[idx].dur == 0) {
            queue[idx].dur = d!.inMilliseconds;
            save();
            notifyListeners();
          }
        })
        .catchError((_) {});
  }

  // Rebuild the player's audio source in-place so the notification picks up
  // updated art/title after enrichment, without audible interruption.
  Future<void> _refreshCurrentMediaItem() async {
    try {
    final idx = player.currentIndex;
    if (idx == null || idx >= queue.length) return;
    final pos = player.position;
    final wasPlaying = player.playing;
    await player.setAudioSource(
      ConcatenatingAudioSource(
        children: [
          for (final s in queue)
            AudioSource.file(
              s.path,
              tag: MediaItem(
                id: s.id,
                title: s.title,
                artist: s.artist,
                artUri: s.art != null ? Uri.file(s.art!) : null,
                duration: s.dur > 0 ? Duration(milliseconds: s.dur) : null,
              ),
            ),
        ],
      ),
      initialIndex: idx,
      initialPosition: pos,
    );
    if (wasPlaying) player.play();
    } catch (_) {} // don't crash if player state changed mid-enrich
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    player.setShuffleModeEnabled(shuffle);
    notifyListeners();
  }

  void cycleLoop() {
    loop = loop == LoopMode.off
        ? LoopMode.all
        : (loop == LoopMode.all ? LoopMode.one : LoopMode.off);
    player.setLoopMode(loop);
    notifyListeners();
  }

  void setSpeed(double v) {
    speed = v;
    player.setSpeed(v);
    notifyListeners();
  }

  void setSleep(int? mins) {
    _sleep?.cancel();
    sleepAt = null;
    if (mins != null) {
      sleepAt = DateTime.now().add(Duration(minutes: mins));
      _sleep = Timer(Duration(minutes: mins), () {
        player.pause();
        sleepAt = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }
}

// ---------------------------------------------------------------- helpers
Color _col(String s) {
  var h = 0;
  for (final r in s.runes) {
    h = (h * 31 + r) % 360;
  }
  return HSLColor.fromAHSL(1, h.toDouble(), .55, .35).toColor();
}

String fmtD(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<String?> askName(BuildContext c, String title, [String init = '']) {
  final ctl = TextEditingController(text: init);
  return showDialog<String>(
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, ctl.text.trim()),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<void> editSongInfo(BuildContext c, Song s) async {
  final titleCtl = TextEditingController(text: s.title);
  final artistCtl = TextEditingController(
    text: s.artist == 'Unknown artist' ? '' : s.artist,
  );
  final confirmed = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: const Text('Edit song info'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: titleCtl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: artistCtl,
            decoration: const InputDecoration(labelText: 'Artist'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Save & refresh'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final newTitle = titleCtl.text.trim();
  final newArtist = artistCtl.text.trim();
  await store.editSongInfo(
    s,
    newTitle,
    newArtist.isEmpty ? 'Unknown artist' : newArtist,
  );
  if (c.mounted) snack(c, 'Saved — fetching lyrics…');
}

void addToPlaylist(BuildContext c, Song s) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New playlist'),
            onTap: () async {
              Navigator.pop(d);
              final n = await askName(c, 'New playlist');
              if (n != null && n.isNotEmpty) {
                store.newList(n, add: s.id);
                if (c.mounted) snack(c, 'Added to $n');
              }
            },
          ),
          for (final l in store.lists)
            ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(l.name),
              onTap: () {
                store.addTo(l, s.id);
                Navigator.pop(d);
                snack(c, 'Added to ${l.name}');
              },
            ),
        ],
      ),
    ),
  );
}

void pickSpeed(BuildContext c) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
            ListTile(
              title: Text('${v}x'),
              trailing: store.speed == v
                  ? const Icon(Icons.check, color: green)
                  : null,
              onTap: () {
                store.setSpeed(v);
                Navigator.pop(d);
              },
            ),
        ],
      ),
    ),
  );
}

void pickSleep(BuildContext c) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final m in <int?>[null, 5, 15, 30, 45, 60])
            ListTile(
              title: Text(m == null ? 'Off' : '$m minutes'),
              onTap: () {
                store.setSleep(m);
                Navigator.pop(d);
              },
            ),
        ],
      ),
    ),
  );
}

class Art extends StatelessWidget {
  final Song s;
  final double size, radius;
  const Art(this.s, this.size, {super.key, this.radius = 6});
  @override
  Widget build(BuildContext context) {
    final ph = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF282828),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        Icons.music_note,
        color: const Color(0xFF535353),
        size: size * .5,
      ),
    );
    final a = s.art;
    if (a == null) return ph;
    // Image.file reports missing/corrupt cache files through errorBuilder.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(a),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => ph,
      ),
    );
  }
}

// ---------------------------------------------------------------- home
class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String q = '';
  String? openPl;

  Future<void> _run(Future<String> f) async {
    final m = await f;
    if (m.isNotEmpty && mounted) snack(context, m);
  }

  Widget _tile(List<Song> list, int i, String? cur, Playlist? pl) {
    final s = list[i];
    final on = s.id == cur, lk = store.liked.contains(s.id);
    return ListTile(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          Art(s, 48),
          if (s.tagsBad)
            Positioned(
              right: -4,
              bottom: -4,
              child: GestureDetector(
                onTap: () => snack(
                  context,
                  '⚠ Unknown artist — tap ⋮ › Edit info to fix the title & artist',
                ),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Color(0xFF121212),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: Colors.orange,
                  ),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        s.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: on ? green : Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.dur > 0)
            Text(
              fmtD(Duration(milliseconds: s.dur)),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          IconButton(
            icon: Icon(
              lk ? Icons.favorite : Icons.favorite_border,
              color: lk ? green : Colors.white54,
            ),
            onPressed: () => store.like(s.id),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'pl') {
                addToPlaylist(context, s);
              } else if (v == 'edit') {
                await editSongInfo(context, s);
              } else if (v == 'reset') {
                await store.resetToFileTags(s);
                if (context.mounted)
                  snack(context, 'Reset — re-fetching info…');
              } else if (pl != null) {
                pl.ids.remove(s.id);
                store.touch();
              } else {
                store.remove(s);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'pl', child: Text('Add to playlist')),
              const PopupMenuItem(value: 'edit', child: Text('Edit info')),
              const PopupMenuItem(
                value: 'reset',
                child: Text('Reset to file tags'),
              ),
              PopupMenuItem(
                value: 'rm',
                child: Text(
                  pl != null
                      ? 'Remove from this playlist'
                      : 'Remove from library',
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () => on
          ? (player.playing ? player.pause() : player.play())
          : store.play(list, i),
    );
  }

  Widget _songPage({
    required String title,
    required List<Song> list,
    String? cur,
    bool search = false,
    Playlist? pl,
    Widget? back,
    Widget? menu,
    String empty = '',
    Widget? body,
  }) {
    // Sticky header (title + search + play row) above a scrollable body
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── sticky section ──────────────────────────────────────────────
        Material(
          color: const Color(0xFF121212),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                child: Row(
                  children: [
                    if (back != null) back else const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (menu != null) menu,
                  ],
                ),
              ),
              if (search)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: TextField(
                    onChanged: (v) => setState(() => q = v),
                    decoration: InputDecoration(
                      hintText: 'Search your songs',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              Row(
                children: [
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: green,
                      foregroundColor: Colors.black,
                    ),
                    iconSize: 30,
                    icon: const Icon(Icons.play_arrow),
                    onPressed: list.isEmpty ? null : () => store.play(list, 0),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.shuffle,
                      color: store.shuffle ? green : Colors.white70,
                    ),
                    onPressed: store.toggleShuffle,
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Text(
                      '${list.length} songs',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              ),
              const Divider(height: 1, color: Colors.white12),
            ],
          ),
        ),
        // ── scrollable body ─────────────────────────────────────────────
        Expanded(
          child:
              body ??
              (list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          empty,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (c, i) => _tile(list, i, cur, pl),
                    )),
        ),
      ],
    );
  }

  Widget _libMenu() => PopupMenuButton<String>(
    icon: const Icon(Icons.add_circle_outline, size: 28),
    onSelected: (v) {
      if (v == 'add') {
        _run(store.addPicked());
      } else if (v == 'scan') {
        _run(store.scanFolder());
      } else if (v == 'rescan') {
        _run(store.rescan());
      } else if (v == 'tags') {
        _run(store.refreshTags());
      } else if (v == 'enrich') {
        _run(store.reenrichAll());
      } else if (v == 'batch') {
        _openBatchImport();
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'add', child: Text('Add songs')),
      PopupMenuItem(value: 'batch', child: Text('Import playlist or batch')),
      PopupMenuItem(value: 'scan', child: Text('Scan a folder')),
      PopupMenuItem(value: 'rescan', child: Text('Rescan saved folders')),
      PopupMenuItem(value: 'tags', child: Text('Refresh album art & tags')),
      PopupMenuItem(value: 'enrich', child: Text('Refresh lyrics & artist')),
    ],
  );

  void _openBatchImport() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      builder: (_) => const _BatchImportSheet(),
    );
  }

  void _openSearch() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _SearchSheet(),
    );
  }

  Widget _batchProgress() {
    if (store.batchQueue.isEmpty) return const SizedBox.shrink();
    final done = store.batchCompleted;
    final total = store.batchTotal;
    final active = store.batchQueue.where(
      (task) => task.status == 'Finding match' || task.status == 'Downloading',
    );
    final current = active.isNotEmpty ? active.first : store.batchQueue.last;
    final overall = total == 0 ? 0.0 : done / total;
    return Card(
      color: const Color(0xFF222222),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.queue_music, color: green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    store.batchRunning ? 'Batch downloads' : 'Batch complete',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  '$done/$total',
                  style: const TextStyle(color: Colors.white54),
                ),
                if (!store.batchRunning)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: store.clearBatchQueue,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: store.batchRunning ? overall : 1),
            const SizedBox(height: 6),
            Text(
              store.batchRunning
                  ? '${current.status}: ${current.query}'
                  : (store.batchMessage ?? 'Finished'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            if (store.batchRunning && current.status == 'Downloading')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: LinearProgressIndicator(value: current.progress),
              ),
          ],
        ),
      ),
    );
  }

  Widget _home(String? cur) {
    final songs = store.songs;
    final h = DateTime.now().hour;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          h < 12
              ? 'Good morning'
              : h < 18
              ? 'Good afternoon'
              : 'Good evening',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 12),
        // Search / Download bar
        GestureDetector(
          onTap: _openSearch,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A2A),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(
              children: const [
                Icon(Icons.search, color: Colors.white54),
                SizedBox(width: 10),
                Text(
                  'Find & download music…',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _batchProgress(),
        if (songs.isNotEmpty)
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 3.1,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            children: [
              for (var i = 0; i < min(6, songs.length); i++)
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => store.play(songs, i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Row(
                      children: [
                        Art(songs[i], 56, radius: 0),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            songs[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: songs[i].id == cur ? green : Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: green,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(0, 50),
                ),
                onPressed: () => _run(store.addPicked()),
                icon: const Icon(Icons.add),
                label: const Text(
                  'Add songs',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
                onPressed: () => _run(store.scanFolder()),
                icon: const Icon(Icons.folder_open),
                label: const Text('Scan folder'),
              ),
            ),
          ],
        ),
        if (songs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text(
              'Your library is empty. Add songs, or scan a folder like Music or Download to import everything in it.',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        if (songs.length > 6) ...[
          const SizedBox(height: 24),
          const Text(
            'Recently added',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: min(12, songs.length),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (c, i) => GestureDetector(
                onTap: () => store.play(songs, i),
                child: SizedBox(
                  width: 130,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Art(songs[i], 130, radius: 8),
                      const SizedBox(height: 6),
                      Text(
                        songs[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        songs[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _playlists() {
    final ls = store.lists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Playlists',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: green,
                  foregroundColor: Colors.black,
                ),
                onPressed: () async {
                  final n = await askName(context, 'New playlist');
                  if (n != null && n.isNotEmpty) store.newList(n);
                },
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ls.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Create a playlist, then use the ⋮ menu on any song to add it.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: ls.length,
                  itemBuilder: (context, index) {
                    final l = ls[index];
                    return ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: _col(l.name),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.queue_music,
                          color: Colors.white70,
                        ),
                      ),
                      title: Text(
                        l.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('${l.ids.length} songs'),
                      onTap: () => setState(() => openPl = l.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _plDetail(String? cur) {
    final idx = store.lists.indexWhere((x) => x.id == openPl);
    if (idx < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => openPl = null);
      });
      return const SizedBox.shrink();
    }
    final pl = store.lists[idx];
    final songs = pl.ids.map(store.byId).whereType<Song>().toList();
    return _songPage(
      title: pl.name,
      list: songs,
      cur: cur,
      pl: pl,
      back: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => setState(() => openPl = null),
      ),
      menu: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'ren') {
            final n = await askName(context, 'Rename playlist', pl.name);
            if (n != null && n.isNotEmpty) {
              pl.name = n;
              store.touch();
            }
          } else {
            store.lists.remove(pl);
            store.touch();
            setState(() => openPl = null);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'ren', child: Text('Rename')),
          PopupMenuItem(value: 'del', child: Text('Delete playlist')),
        ],
      ),
      empty: 'This playlist is empty. Use ⋮ on a song, then "Add to playlist".',
    );
  }

  // Feature 1: Library tab body with recently played section
  Widget _libraryBody(String? cur) {
    final allSongs = store.songs;
    final k = q.toLowerCase();
    final filtered = q.isEmpty
        ? allSongs
        : allSongs
              .where((s) => '${s.title} ${s.artist}'.toLowerCase().contains(k))
              .toList();
    if (filtered.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tap + to add songs or scan a folder',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    // A single lazy list avoids building every tile at once and keeps memory
    // stable for libraries with thousands of tracks.
    return ListView.builder(
      itemCount: filtered.length,
      cacheExtent: 600,
      itemBuilder: (c, i) => _tile(filtered, i, cur, null),
    );
  }

  Widget _page(String? cur) {
    switch (tab) {
      case 0:
        return _home(cur);
      case 1:
        final k = q.toLowerCase();
        final displayList = q.isEmpty
            ? store.songs
            : store.songs
                  .where(
                    (s) => '${s.title} ${s.artist}'.toLowerCase().contains(k),
                  )
                  .toList();
        return _songPage(
          title: 'Your Library',
          list: displayList,
          cur: cur,
          search: true,
          menu: _libMenu(),
          empty: 'Tap + to add songs or scan a folder',
          body: _libraryBody(cur), // Feature 1: custom body
        );
      case 2:
        return openPl == null ? _playlists() : _plDetail(cur);
      default:
        return _songPage(
          title: 'Liked Songs',
          list: store.songs.where((s) => store.liked.contains(s.id)).toList(),
          cur: cur,
          empty: 'Tap a ♡ on any song',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.ready)
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        return PopScope(
          canPop: tab == 0 && openPl == null,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            setState(() {
              if (openPl != null) {
                openPl = null;
              } else {
                tab = 0;
              }
            });
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  if (store.busy != null)
                    Container(
                      width: double.infinity,
                      color: green,
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        store.busy!,
                        style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (store.updateUrl != null)
                    Material(
                      color: const Color(0xFF2A2A2A),
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.system_update, color: green),
                        title: Text(
                          store.updating
                              ? 'Downloading update…'
                              : 'Update available (${store.updateTag})',
                        ),
                        subtitle: store.updating
                            ? LinearProgressIndicator(value: store.updatePct)
                            : null,
                        trailing: store.updating
                            ? null
                            : FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: green,
                                  foregroundColor: Colors.black,
                                ),
                                onPressed: () => _run(store.installUpdate()),
                                child: const Text('Update'),
                              ),
                      ),
                    ),
                  Expanded(
                    child: StreamBuilder<int?>(
                      stream: player.currentIndexStream,
                      builder: (c, sn) {
                        final i = sn.data;
                        final cur = (i != null && i < store.queue.length)
                            ? store.queue[i].id
                            : null;
                        return _page(cur);
                      },
                    ),
                  ),
                  const MiniPlayer(),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (i) => setState(() {
                tab = i;
                openPl = null;
                q = '';
              }),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.library_music_outlined),
                  selectedIcon: Icon(Icons.library_music),
                  label: 'Library',
                ),
                NavigationDestination(
                  icon: Icon(Icons.queue_music_outlined),
                  selectedIcon: Icon(Icons.queue_music),
                  label: 'Playlists',
                ),
                NavigationDestination(
                  icon: Icon(Icons.favorite_border),
                  selectedIcon: Icon(Icons.favorite),
                  label: 'Liked',
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- batch import sheet
class _BatchImportSheet extends StatefulWidget {
  const _BatchImportSheet();
  @override
  State<_BatchImportSheet> createState() => _BatchImportSheetState();
}

class _BatchImportSheetState extends State<_BatchImportSheet> {
  final _ctl = TextEditingController();
  bool _loading = false;
  String _error = '';

  Future<void> _queue() async {
    final input = _ctl.text.trim();
    if (input.isEmpty) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    final message = await store.startBatchDownload(input);
    if (!mounted) return;
    setState(() => _loading = false);
    if (store.batchQueue.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      Navigator.pop(context);
    } else {
      setState(() => _error = message);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottom + 20),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Import playlist or batch',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            const Text(
              'Paste a public YouTube or Spotify playlist URL, or one song per line. '
              'Use “Artist - Title” for the best metadata match.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctl,
              autofocus: true,
              minLines: 4,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                hintText: 'https://www.youtube.com/playlist?list=…\nhttps://open.spotify.com/playlist/…\n\nArtist - Song title\nAnother artist - Another song',
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(_error, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _queue,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.playlist_add),
                label: Text(_loading ? 'Reading playlist…' : 'Queue downloads'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- search + download sheet
class _SearchSheet extends StatefulWidget {
  const _SearchSheet();
  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final _ctl = TextEditingController();
  List<InvResult> _results = [];
  bool _searching = false;
  String _searchErr = '';
  // videoId -> progress (null = not downloading, -1 = done, 0..1 = progress)
  final Map<String, double?> _dl = {};

  Future<void> _search() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searchErr = '';
      _results = [];
    });
    try {
      final res = await invSearch(q);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _results = res;
        if (res.isEmpty) _searchErr = 'No results found';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchErr = 'Error: $e';
      });
    }
  }

  Future<void> _download(InvResult r) async {
    if (_dl[r.videoId] != null) return; // already downloading/done
    setState(() => _dl[r.videoId] = 0);
    final err = await store.downloadFromInvidious(r, (pct) {
      // Progress callbacks can be much more frequent than frame time.
      if (mounted &&
          (_dl[r.videoId] == null ||
              (pct - (_dl[r.videoId] ?? 0)).abs() >= .01)) {
        setState(() => _dl[r.videoId] = pct);
      }
    });
    if (!mounted) return;
    if (err.isNotEmpty) {
      setState(() => _dl.remove(r.videoId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      setState(() => _dl[r.videoId] = -1); // done
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (_, sc) => Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctl,
                    autofocus: true,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: 'Search for music…',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _searching ? null : _search,
                  child: const Text('Search'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(color: green),
            ),
          if (_searchErr.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _searchErr,
                style: const TextStyle(color: Colors.white54),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: sc,
              itemCount: _results.length,
              itemBuilder: (c, i) {
                final r = _results[i];
                final prog = _dl[r.videoId];
                final done = prog == -1;
                final downloading = prog != null && prog >= 0;
                final dur = r.lengthSeconds > 0
                    ? fmtD(Duration(seconds: r.lengthSeconds))
                    : '';
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: r.thumbnail.isNotEmpty
                        ? Image.network(
                            r.thumbnail,
                            width: 56,
                            height: 42,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 56,
                              height: 42,
                              color: const Color(0xFF2A2A2A),
                            ),
                          )
                        : Container(
                            width: 56,
                            height: 42,
                            color: const Color(0xFF2A2A2A),
                          ),
                  ),
                  title: Text(
                    r.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    '${r.author}${dur.isNotEmpty ? ' · $dur' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  trailing: done
                      ? const Icon(Icons.check_circle, color: green)
                      : downloading
                      ? SizedBox(
                          width: 48,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  value: prog == 0 ? null : prog,
                                  strokeWidth: 3,
                                  color: green,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                prog != null && prog > 0
                                    ? '${(prog * 100).toInt()}%'
                                    : 'Loading…',
                                style: const TextStyle(
                                  fontSize: 8,
                                  color: Colors.white54,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        )
                      : IconButton(
                          icon: const Icon(
                            Icons.download_outlined,
                            color: green,
                          ),
                          onPressed: () => _download(r),
                        ),
                  onTap: downloading || done ? null : () => _download(r),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- player UI
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (c, snap) {
          final i = snap.data;
          if (i == null || i >= store.queue.length)
            return const SizedBox.shrink();
          final s = store.queue[i];
          final lk = store.liked.contains(s.id);
          return Container(
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const NowPlaying()),
                        ),
                        child: Row(
                          children: [
                            Art(s, 44),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    s.artist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        lk ? Icons.favorite : Icons.favorite_border,
                        color: lk ? green : Colors.white70,
                      ),
                      onPressed: () => store.like(s.id),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous),
                      onPressed: () => player.seekToPrevious(),
                    ),
                    StreamBuilder<PlayerState>(
                      stream: player.playerStateStream,
                      builder: (c, st) {
                        final playing = st.data?.playing ?? false;
                        return IconButton.filled(
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                          ),
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () =>
                              playing ? player.pause() : player.play(),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      onPressed: () => player.seekToNext(),
                    ),
                  ],
                ),
                const SeekBar(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class NowPlaying extends StatefulWidget {
  const NowPlaying({super.key});
  @override
  State<NowPlaying> createState() => _NowPlayingState();
}

class _NowPlayingState extends State<NowPlaying> {
  String? _lastArt;

  Future<void> _extractPalette(Song s) async {
    if (s.art == null) return;
    if (_paletteCache.containsKey(s.id)) return;
    if (_lastArt == s.art) return;
    _lastArt = s.art;
    try {
      final pg = await PaletteGenerator.fromImageProvider(
        FileImage(File(s.art!)),
        maximumColorCount: 8,
      );
      final color =
          pg.darkVibrantColor?.color ??
          pg.vibrantColor?.color ??
          pg.dominantColor?.color;
      if (color != null && mounted) {
        setState(() => _paletteCache[s.id] = color);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (c, snap) {
          final i = snap.data;
          if (i == null || i >= store.queue.length) {
            return Scaffold(
              appBar: AppBar(),
              body: const Center(child: Text('Nothing playing')),
            );
          }
          final s = store.queue[i];
          _extractPalette(s);
          final lk = store.liked.contains(s.id);
          final sleep = store.sleepAt;
          final bgColor = _paletteCache[s.id] ?? _col(s.title);
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [bgColor, const Color(0xFF121212)],
                stops: const [0, .7],
              ),
            ),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                centerTitle: true,
                title: const Text(
                  'Now playing',
                  style: TextStyle(fontSize: 14),
                ),
                leading: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              body: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (c, b) => Center(
                          child: Art(
                            s,
                            min(b.maxWidth, b.maxHeight),
                            radius: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                s.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          iconSize: 30,
                          icon: Icon(
                            lk ? Icons.favorite : Icons.favorite_border,
                            color: lk ? green : Colors.white,
                          ),
                          onPressed: () => store.like(s.id),
                        ),
                      ],
                    ),
                    const SeekBar(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.shuffle,
                            color: store.shuffle ? green : Colors.white70,
                          ),
                          onPressed: store.toggleShuffle,
                        ),
                        IconButton(
                          iconSize: 40,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => player.seekToPrevious(),
                        ),
                        StreamBuilder<PlayerState>(
                          stream: player.playerStateStream,
                          builder: (c, st) {
                            final playing = st.data?.playing ?? false;
                            return IconButton.filled(
                              iconSize: 40,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                              ),
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                              ),
                              onPressed: () =>
                                  playing ? player.pause() : player.play(),
                            );
                          },
                        ),
                        IconButton(
                          iconSize: 40,
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => player.seekToNext(),
                        ),
                        IconButton(
                          icon: Icon(
                            store.loop == LoopMode.one
                                ? Icons.repeat_one
                                : Icons.repeat,
                            color: store.loop == LoopMode.off
                                ? Colors.white70
                                : green,
                          ),
                          onPressed: store.cycleLoop,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          avatar: const Icon(Icons.speed, size: 18),
                          label: Text('${store.speed}x'),
                          onPressed: () => pickSpeed(context),
                        ),
                        ActionChip(
                          avatar: const Icon(Icons.bedtime_outlined, size: 18),
                          label: Text(
                            sleep == null
                                ? 'Sleep timer'
                                : '~${sleep.difference(DateTime.now()).inMinutes + 1}m',
                          ),
                          onPressed: () => pickSleep(context),
                        ),
                        // Feature 3: always show lyrics chip; fetch on demand if not loaded
                        _LyricsChip(s: s),
                        // Feature 9: artist bio via Last.fm
                        _BioChip(s: s),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Feature 3: Lyrics chip — always visible; fetches on demand if lyrics not loaded yet
class _LyricsChip extends StatefulWidget {
  final Song s;
  const _LyricsChip({required this.s});
  @override
  State<_LyricsChip> createState() => _LyricsChipState();
}

class _LyricsChipState extends State<_LyricsChip> {
  bool _fetching = false;

  Future<void> _fetchAndOpen() async {
    final s = widget.s;
    // If already loaded, open straight away
    if (s.lyrics != null || s.syncedLyrics != null) {
      _open(s);
      return;
    }
    // Fetch now
    setState(() => _fetching = true);
    final map = await _fetchLrcLibLyrics(s.title, s.artist, durMs: s.dur);
    if (map['plain'] != null) s.lyrics = map['plain'];
    if (map['synced'] != null) s.syncedLyrics = map['synced'];
    store.save();
    store.ping();
    if (!mounted) return;
    setState(() => _fetching = false);
    if (s.lyrics == null && s.syncedLyrics == null) {
      if (mounted) _showLyricLog(context, s);
      return;
    }
    _open(s);
  }

  void _open(Song s) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => LyricsSheet(s: s),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: _fetching
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: green),
            )
          : const Icon(Icons.lyrics_outlined, size: 18),
      label: const Text('Lyrics'),
      onPressed: _fetching ? null : _fetchAndOpen,
    );
  }
}

// Feature 9: Artist bio via Last.fm
Future<Map<String, dynamic>?> _fetchArtistBio(String artist) async {
  if (artist == 'Unknown artist' || artist.trim().isEmpty) return null;
  try {
    final a = Uri.encodeComponent(artist);
    final uri = Uri.parse(
      'https://ws.audioscrobbler.com/2.0/?method=artist.getInfo&artist=$a&api_key=43693facbb24d1ac893a5d813b137c15&format=json&autocorrect=1',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final art = j['artist'] as Map<String, dynamic>?;
    if (art == null) return null;
    var bio = ((art['bio'] as Map?)?['summary'] as String? ?? '').trim();
    // Strip Last.fm "Read more on Last.fm" link
    bio = bio.replaceAll(RegExp(r'<a[^>]*>.*?</a>', dotAll: true), '').trim();
    bio = bio.replaceAll(RegExp(r'\s+'), ' ').trim();
    final tags = ((art['tags'] as Map?)?['tag'] as List? ?? [])
        .map((t) => (t as Map)['name'] as String? ?? '')
        .where((t) => t.isNotEmpty)
        .take(5)
        .toList();
    final listeners = art['stats']?['listeners'] as String?;
    final playcount = art['stats']?['playcount'] as String?;
    return {
      'bio': bio.isEmpty ? null : bio,
      'tags': tags,
      'listeners': listeners,
      'playcount': playcount,
    };
  } catch (_) {
    return null;
  }
}

class _BioChip extends StatefulWidget {
  final Song s;
  const _BioChip({required this.s});
  @override
  State<_BioChip> createState() => _BioChipState();
}

class _BioChipState extends State<_BioChip> {
  bool _fetching = false;

  Future<void> _fetchAndOpen() async {
    final s = widget.s;
    if (s.artist == 'Unknown artist') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fix artist name first to load bio')),
      );
      return;
    }
    setState(() => _fetching = true);
    final data = await _fetchArtistBio(s.artist);
    if (!mounted) return;
    setState(() => _fetching = false);
    if (data == null || (data['bio'] == null && (data['tags'] as List).isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No bio found for ${s.artist}')),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ArtistBioSheet(artist: s.artist, data: data),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: _fetching
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: green),
            )
          : const Icon(Icons.person_outline, size: 18),
      label: const Text('Artist'),
      onPressed: _fetching ? null : _fetchAndOpen,
    );
  }
}

class _ArtistBioSheet extends StatelessWidget {
  final String artist;
  final Map<String, dynamic> data;
  const _ArtistBioSheet({required this.artist, required this.data});

  String _fmt(String? n) {
    if (n == null) return '';
    final v = int.tryParse(n);
    if (v == null) return n;
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final bio = data['bio'] as String?;
    final tags = (data['tags'] as List).cast<String>();
    final listeners = _fmt(data['listeners'] as String?);
    final playcount = _fmt(data['playcount'] as String?);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (_, sc) => ListView(
        controller: sc,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            artist,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          if (listeners.isNotEmpty || playcount.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (listeners.isNotEmpty) '$listeners listeners',
                if (playcount.isNotEmpty) '$playcount plays',
              ].join('  ·  '),
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: tags
                  .map((t) => Chip(
                        label: Text(t, style: const TextStyle(fontSize: 12)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ))
                  .toList(),
            ),
          ],
          if (bio != null) ...[
            const SizedBox(height: 16),
            Text(bio, style: const TextStyle(fontSize: 14, height: 1.6, color: Colors.white70)),
          ],
        ],
      ),
    );
  }
}

// Feature 3: Synced lyrics sheet
class LyricsSheet extends StatefulWidget {
  final Song s;
  const LyricsSheet({super.key, required this.s});
  @override
  State<LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends State<LyricsSheet> {
  late final ScrollController _sc;
  late final List<({int ms, String line})> _lines;
  late final bool _isSynced;
  static const double _lineHeight = 52.0;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController();
    _isSynced = widget.s.syncedLyrics != null;
    _lines = _isSynced ? parseLrc(widget.s.syncedLyrics!) : [];
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _scrollToLine(int idx) {
    if (!_sc.hasClients) return;
    final offset = idx * _lineHeight;
    final viewportHeight = _sc.position.viewportDimension;
    final target = offset - viewportHeight / 2 + _lineHeight / 2;
    _sc.animateTo(
      target.clamp(0.0, _sc.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      minChildSize: 0.3,
      builder: (_, sheetSc) => Column(
        children: [
          // Header
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          // Close button row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Text(
            widget.s.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          Text(
            widget.s.artist,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const Divider(height: 24, color: Colors.white12),
          // Lyrics body
          Expanded(
            child: _isSynced
                ? StreamBuilder<Duration>(
                    stream: player.positionStream,
                    builder: (ctx, snap) {
                      final posMs =
                          (snap.data?.inMilliseconds ?? 0) +
                          300; // 300ms lookahead to compensate for display lag
                      // Find current line: last line whose ms <= posMs
                      var curIdx = -1;
                      for (var i = 0; i < _lines.length; i++) {
                        if (_lines[i].ms <= posMs) curIdx = i;
                      }
                      // Auto-scroll after frame
                      if (curIdx >= 0) {
                        WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _scrollToLine(curIdx),
                        );
                      }
                      return ListView.builder(
                        controller: _sc,
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                        itemCount: _lines.length,
                        itemBuilder: (c, i) {
                          final isCur = i == curIdx;
                          return ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: _lineHeight,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Text(
                                _lines[i].line,
                                style: TextStyle(
                                  fontSize: isCur ? 17 : 15,
                                  fontWeight: isCur
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isCur ? Colors.white : Colors.white54,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  )
                : SingleChildScrollView(
                    controller: _sc,
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    child: Text(
                      widget.s.lyrics ?? '',
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.8,
                        color: Colors.white70,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class SeekBar extends StatelessWidget {
  const SeekBar({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (c, ds) {
        final dur = ds.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (c, ps) {
            final pos = ps.data ?? Duration.zero;
            final mx = dur.inMilliseconds > 0
                ? dur.inMilliseconds.toDouble()
                : 1.0;
            final v = pos.inMilliseconds.toDouble().clamp(0.0, mx).toDouble();
            return Row(
              children: [
                Text(
                  fmtD(pos),
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                Expanded(
                  child: Slider(
                    value: v,
                    max: mx,
                    activeColor: green,
                    inactiveColor: Colors.white24,
                    onChanged: dur.inMilliseconds > 0
                        ? (x) => player.seek(Duration(milliseconds: x.round()))
                        : null,
                  ),
                ),
                Text(
                  fmtD(dur),
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(width: 8),
              ],
            );
          },
        );
      },
    );
  }
}
// END_OF_SOUNDWAVE

// ---- in-app debug log viewer
void _showLyricLog(BuildContext c, Song s) {
  showDialog(
    context: c,
    builder: (d) => AlertDialog(
      title: Text('No lyrics for "${s.title}"'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: SingleChildScrollView(
          child: SelectableText(
            lyricLog.isEmpty
                ? '(no log yet)'
                : lyricLog.reversed.take(60).join('\n'),
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            lyricLog.clear();
            Navigator.pop(d);
          },
          child: const Text('Clear'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
