import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
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

const green = Color(0xFF1DB954);
const _exts = {'.mp3', '.m4a', '.aac', '.wav', '.ogg', '.opus', '.flac'};
const kRepo = String.fromEnvironment('REPO');
const kBuild = int.fromEnvironment('BUILD', defaultValue: 0);
final player = AudioPlayer();

// ---- metadata enrichment helpers
Future<Map<String, String?>?> _lookupMusicBrainz(String title, String artist) async {
  try {
    final q = Uri.encodeComponent(
        artist == 'Unknown artist' ? title : '$title $artist');
    final r = await http.get(
      Uri.parse('https://musicbrainz.org/ws/2/recording/?query=$q&limit=5&fmt=json'),
      headers: {'User-Agent': 'SoundWave/1.0 (soundwave-app)'},
    ).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final recs = j['recordings'] as List?;
    if (recs == null || recs.isEmpty) return null;
    Map? rec;
    var bestSim = 0.0;
    for (final r0 in recs) {
      if (r0 is! Map) continue;
      final sim = _similarity(title, (r0['title'] as String?) ?? '');
      if (sim > bestSim) { bestSim = sim; rec = r0; }
    }
    if (rec == null || bestSim < 0.75) return null; // not the same song -> don't rename it
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

Future<String?> _fetchItunesArt(String title, String artist) async {
  try {
    final q = Uri.encodeComponent(artist == 'Unknown artist' ? title : '$title $artist');
    final r = await http.get(
      Uri.parse('https://itunes.apple.com/search?term=$q&media=music&limit=5'),
    ).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final j = jsonDecode(r.body) as Map;
    final results = j['results'] as List?;
    if (results == null || results.isEmpty) return null;
    Map? best;
    var bestScore = 0.0;
    for (final it in results) {
      if (it is! Map) continue;
      var sc = _similarity(title, (it['trackName'] as String?) ?? '');
      if (artist != 'Unknown artist') {
        sc += 0.3 * _similarity(artist, (it['artistName'] as String?) ?? '');
      }
      if (sc > bestScore) { bestScore = sc; best = it; }
    }
    if (best == null || _similarity(title, (best['trackName'] as String?) ?? '') < 0.7) return null;
    final art = best['artworkUrl100'] as String?;
    if (art == null) return null;
    return art.replaceAll('100x100bb', '600x600bb');
  } catch (_) {
    return null;
  }
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

// Bigram Dice similarity (0..1). Keeps non-latin letters (Hindi, Punjabi etc).
double _similarity(String a, String b) {
  final s1 = _norm(a), s2 = _norm(b);
  if (s1.isEmpty && s2.isEmpty) return 1;
  if (s1.isEmpty || s2.isEmpty) return 0;
  if (s1 == s2) return 1;
  final shorter = s1.length <= s2.length ? s1 : s2;
  final longer = s1.length <= s2.length ? s2 : s1;
  if (shorter.length >= 4 && longer.contains(shorter)) return 0.85;
  if (s1.length < 2 || s2.length < 2) return 0;
  final m = <String, int>{};
  for (var i = 0; i < s1.length - 1; i++) {
    final g = s1.substring(i, i + 2);
    m[g] = (m[g] ?? 0) + 1;
  }
  var inter = 0;
  for (var i = 0; i < s2.length - 1; i++) {
    final g = s2.substring(i, i + 2);
    if ((m[g] ?? 0) > 0) { inter++; m[g] = m[g]! - 1; }
  }
  return 2 * inter / ((s1.length - 1) + (s2.length - 1));
}

// Strip "(Official Video)", "[HD]", "feat. X", "- Lyrics" etc. that break lyric search
String _cleanTitle(String t) {
  var s = t.replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), ' ');
  s = s.replaceAll(RegExp(r'\s+(feat\.?|ft\.?)\s.*$', caseSensitive: false), ' ');
  s = s.replaceAll(
      RegExp(r'\s*-?\s*(official( music)? (video|audio)|lyrics?( video)?|lyrical|full (video|song)|audio|video|hd|hq)\s*$',
          caseSensitive: false),
      ' ');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? t.trim() : s;
}

// Returns plain + synced lyrics from the single best-matching LRCLIB result
Future<Map<String, String?>> _fetchLrcLibLyrics(String title, String artist, {int durMs = 0}) async {
  final unknown = artist == 'Unknown artist';
  final t = _cleanTitle(title);
  String enc(String x) => Uri.encodeComponent(x);
  final urls = <String>[
    if (!unknown) 'https://lrclib.net/api/search?track_name=${enc(t)}&artist_name=${enc(artist)}',
    if (!unknown) 'https://lrclib.net/api/search?q=${enc('$t $artist')}',
    'https://lrclib.net/api/search?track_name=${enc(t)}',
    'https://lrclib.net/api/search?q=${enc(t)}',
  ];
  // FIX (bug 11): use a String-keyed set so null ids don't collide.
  final seen = <String>{};
  Map? best;
  var bestScore = -1.0;
  for (final url in urls) {
    try {
      final r = await http
          .get(Uri.parse(url), headers: {'User-Agent': 'SoundWave/1.0 (soundwave-app)'})
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) continue;
      final list = jsonDecode(r.body);
      if (list is! List) continue;
      for (final raw in list) {
        if (raw is! Map) continue;
        final id = raw['id'];
        if (id != null && !seen.add('$id')) continue;
        final synced = ((raw['syncedLyrics'] as String?) ?? '').trim();
        final plain = ((raw['plainLyrics'] as String?) ?? '').trim();
        if (synced.isEmpty && plain.isEmpty) continue;
        final ts = _similarity(t, (raw['trackName'] as String?) ?? '');
        if (ts < 0.6) continue; // different song
        var score = ts;
        if (!unknown) score += 0.5 * _similarity(artist, (raw['artistName'] as String?) ?? '');
        final d = raw['duration'];
        if (durMs > 0 && d is num) {
          final diff = (d * 1000 - durMs).abs();
          if (diff < 3000) {
            score += 0.3;
          } else if (diff > 15000) {
            score -= 0.3;
          }
        }
        if (synced.isNotEmpty) score += 0.05;
        if (score > bestScore) { bestScore = score; best = raw; }
      }
      if (best != null && bestScore >= 1.2) break; // good enough, stop querying
    } catch (_) {}
  }
  if (best == null) return {'plain': null, 'synced': null};
  final synced = ((best['syncedLyrics'] as String?) ?? '').trim();
  final plain = ((best['plainLyrics'] as String?) ?? '').trim();
  return {'plain': plain.isEmpty ? null : plain, 'synced': synced.isEmpty ? null : synced};
}

// FIX (bug 6): LRC parser now handles [mm:ss], [mm:ss.xx], [mm:ss.xxx], [mm:ss:xx]
// and multiple timestamps per line. Fractions are interpreted by digit count.
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
  );
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
              backgroundColor: Color(0xFF000000), indicatorColor: Color(0xFF2A2A2A)),
        ),
        home: const Home(),
      );
}

// ---------------------------------------------------------------- models
class Song {
  final String id, path;
  String title, artist;
  String? art, lyrics, syncedLyrics, fp;
  int dur;
  bool own;
  Song(this.id, this.title, this.artist, this.path,
      {this.art, this.lyrics, this.syncedLyrics, this.fp, this.dur = 0, this.own = true});
  Map<String, dynamic> toJson() => {
        'id': id, 'title': title, 'artist': artist, 'path': path,
        'art': art, 'lyrics': lyrics, 'syncedLyrics': syncedLyrics,
        'fp': fp, 'dur': dur, 'own': own,
      };
  factory Song.fromJson(Map j) => Song(
        j['id'], j['title'], j['artist'], j['path'],
        art: j['art'],
        lyrics: j['lyrics'] ?? j['lyricsUrl'],
        syncedLyrics: j['syncedLyrics'],
        fp: j['fp'],
        dur: j['dur'] ?? 0,
        own: j['own'] ?? true,
      );
}

class Playlist {
  final String id;
  String name;
  List<String> ids;
  Playlist(this.id, this.name, this.ids);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'ids': ids};
  factory Playlist.fromJson(Map j) => Playlist(j['id'], j['name'], List<String>.from(j['ids']));
}

// ---------------------------------------------------------------- store
class Store extends ChangeNotifier {
  List<Song> songs = [], queue = [];
  Set<String> liked = {};
  List<Playlist> lists = [];
  List<String> folders = [];
  List<String> recentIds = [];
  bool shuffle = false, ready = false;
  LoopMode loop = LoopMode.off;
  double speed = 1.0;
  DateTime? sleepAt;
  Timer? _sleep;
  String? busy, updateUrl, updateTag;
  double? updatePct;
  bool updating = false;
  late SharedPreferences prefs;

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
    final raw = prefs.getString('songs');
    if (raw != null) {
      songs = (jsonDecode(raw) as List)
          .map((e) => Song.fromJson(e as Map))
          .where((s) => File(s.path).existsSync())
          .toList();
    }
    final pl = prefs.getString('lists');
    if (pl != null) lists = (jsonDecode(pl) as List).map((e) => Playlist.fromJson(e as Map)).toList();
    liked = (prefs.getStringList('liked') ?? []).toSet();
    folders = prefs.getStringList('folders') ?? [];
    recentIds = prefs.getStringList('recents') ?? [];
    ready = true;
    notifyListeners();
    // FIX (bug 14): await + swallow errors so a denied permission doesn't crash load().
    try {
      await Permission.notification.request();
    } catch (_) {}
    checkUpdate();
  }

  void save() {
    prefs.setString('songs', jsonEncode(songs.map((s) => s.toJson()).toList()));
    prefs.setString('lists', jsonEncode(lists.map((l) => l.toJson()).toList()));
    prefs.setStringList('liked', liked.toList());
    prefs.setStringList('folders', folders);
    prefs.setStringList('recents', recentIds);
  }

  void like(String id) {
    liked.contains(id) ? liked.remove(id) : liked.add(id);
    touch();
  }

  Playlist newList(String name, {String? add}) {
    final l = Playlist('p${DateTime.now().microsecondsSinceEpoch}', name, add != null ? [add] : []);
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
          .get(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
              headers: {'Accept': 'application/vnd.github+json'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body) as Map;
      final tag = '${j['tag_name']}';
      // FIX (bug 5): grab the trailing integer from the tag; robust to v-prefix and suffixes.
      final m = RegExp(r'(\d+)\s*$').firstMatch(tag);
      final build = m != null ? int.parse(m.group(1)!) : 0;
      String? url;
      // FIX (bug 4): null-safe assets list.
      final assets = j['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is Map && '${a['name']}'.endsWith('.apk')) {
            url = '${a['browser_download_url']}';
          }
        }
      }
      if (url != null && kBuild > 0 && build > kBuild) {
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
    final client = http.Client();
    File? file;
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      // FIX (bug 8): don't write HTML error pages over the APK.
      if (resp.statusCode != 200) {
        return 'Update failed (HTTP ${resp.statusCode})';
      }
      final total = resp.contentLength ?? 0;
      file = File(p.join((await getTemporaryDirectory()).path, 'SoundWave-update.apk'));
      final sink = file.openWrite();
      var got = 0;
      var lastPct = -1;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          // FIX (bug 9): only notify on visible percentage change.
          final pct = (got * 100 / total).round();
          if (pct != lastPct) {
            lastPct = pct;
            updatePct = got / total;
            notifyListeners();
          }
        }
      }
      await sink.close();
      updatePct = 1.0;
      notifyListeners();
      await OpenFilex.open(file.path, type: 'application/vnd.android.package-archive');
      return '';
    } catch (_) {
      return 'Update failed. Check your connection and try again.';
    } finally {
      // FIX (bug 8): always close the client and reset state, even on error.
      client.close();
      updating = false;
      updatePct = null;
      notifyListeners();
    }
  }

  // ---- tags + album art
  Future<String> _saveArt(String id, List<int> bytes) async {
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'art'));
    await dir.create(recursive: true);
    final f = File(p.join(dir.path, '$id.img'));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  Future<void> _applyTags(Song s) async {
    try {
      final m = md.readMetadata(File(s.path), getImage: true);
      if ((m.title ?? '').trim().isNotEmpty) s.title = m.title!.trim();
      if ((m.artist ?? '').trim().isNotEmpty) s.artist = m.artist!.trim();
      final d = m.duration;
      if (d != null) s.dur = d.inMilliseconds;
      if (m.pictures.isNotEmpty) s.art = await _saveArt(s.id, m.pictures.first.bytes);
    } catch (_) {}
  }

  // FIX (bug 2): force flag; never destroy existing lyrics if the new fetch fails.
  Future<void> _enrich(Song s, {bool force = false}) async {
    if (s.artist == 'Unknown artist') {
      final mb = await _lookupMusicBrainz(s.title, s.artist);
      if (mb != null) {
        if ((mb['artist'] ?? '').isNotEmpty) s.artist = mb['artist']!;
        if ((mb['title'] ?? '').isNotEmpty && _similarity(s.title, mb['title']!) >= 0.85) {
          s.title = mb['title']!;
        }
      }
    }
    if (s.art == null) {
      final artUrl = await _fetchItunesArt(s.title, s.artist);
      if (artUrl != null) {
        try {
          final r = await http.get(Uri.parse(artUrl)).timeout(const Duration(seconds: 10));
          if (r.statusCode == 200) s.art = await _saveArt(s.id, r.bodyBytes);
        } catch (_) {}
      }
    }
    final hasRealPlain = s.lyrics != null && !s.lyrics!.startsWith('http');
    final hasSynced = s.syncedLyrics != null;
    if (force || (!hasRealPlain && !hasSynced)) {
      final map = await _fetchLrcLibLyrics(s.title, s.artist, durMs: s.dur);
      if (map['plain'] != null) {
        s.lyrics = map['plain'];
      } else if (!hasRealPlain && s.lyrics != null && s.lyrics!.startsWith('http')) {
        // Only drop a stale Genius URL if we got nothing new.
        s.lyrics = null;
      }
      if (map['synced'] != null) s.syncedLyrics = map['synced'];
    }
  }

  // FIX (bug 3): snapshot the list, per-item try/catch, re-entry guard, try/finally.
  Future<String> refreshTags() async {
    if (busy != null) return '';
    final snapshot = List<Song>.of(songs);
    try {
      for (var i = 0; i < snapshot.length; i++) {
        busy = 'Reading tags ${i + 1} of ${snapshot.length}…';
        notifyListeners();
        await Future.delayed(Duration.zero);
        try {
          await _applyTags(snapshot[i]);
        } catch (_) {}
      }
      return 'Album art refreshed';
    } finally {
      busy = null;
      touch();
    }
  }

  Future<String> reenrichAll() async {
    if (busy != null) return '';
    final snapshot = List<Song>.of(songs);
    try {
      for (var i = 0; i < snapshot.length; i++) {
        busy = 'Fetching lyrics & artist ${i + 1} of ${snapshot.length}…';
        notifyListeners();
        await Future.delayed(Duration.zero);
        try {
          await _enrich(snapshot[i], force: true);
        } catch (_) {}
      }
      return 'Lyrics & artist info refreshed';
    } finally {
      busy = null;
      touch();
    }
  }

  // ---- manual edit song info
  Future<void> editSongInfo(Song s, String newTitle, String newArtist) async {
    s.title = newTitle.trim().isEmpty ? s.title : newTitle.trim();
    s.artist = newArtist.trim().isEmpty ? s.artist : newArtist.trim();
    // Clear lyrics so they re-fetch with correct metadata. We deliberately
    // do NOT clear plain lyrics here — if enrichment fails the user still
    // has something. Synced is cleared because timings may be wrong now.
    s.syncedLyrics = null;
    save();
    notifyListeners();
    _enrich(s, force: true).then((_) {
      save();
      notifyListeners();
    }).catchError((_) {});
  }

  // ---- importing
  int lastDup = 0;

  Future<String?> _fingerprint(String path) async {
    try {
      final f = File(path);
      final len = await f.length();
      final raf = await f.open();
      try {
        const n = 32768;
        var h = 0x811c9dc5;
        for (final pos in <int>{
          0,
          len > n * 2 ? (len ~/ 2) - (n ~/ 2) : 0,
          len > n ? len - n : 0,
        }) {
          await raf.setPosition(pos);
          final bytes = await raf.read(n);
          for (final b in bytes) {
            h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
          }
        }
        return '$len-${h.toRadixString(16)}';
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  // FIX (bug 17): re-entry guard via `busy`.
  Future<int> _import(List<MapEntry<String, String>> items, bool own) async {
    if (busy != null) return 0;
    final dir = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'music'));
    await dir.create(recursive: true);
    var n = 0;
    lastDup = 0;
    busy = 'Checking for duplicates…';
    notifyListeners();
    await Future.delayed(Duration.zero);
    try {
      // FIX (bug 18): build a fast path-set once instead of O(n) `any` per candidate.
      final known = <String>{};
      final pathSet = <String>{for (final s in songs) s.path};
      for (final s in songs) {
        s.fp ??= await _fingerprint(s.path);
        if (s.fp != null) known.add(s.fp!);
      }
      for (var i = 0; i < items.length; i++) {
        busy = 'Adding ${i + 1} of ${items.length}…';
        notifyListeners();
        await Future.delayed(Duration.zero);
        final src = items[i].key;
        if (!own && pathSet.contains(src)) continue;
        final fp = await _fingerprint(src);
        if (fp != null && known.contains(fp)) {
          lastDup++;
          continue;
        }
        final id = '${DateTime.now().microsecondsSinceEpoch}$i';
        var path = src;
        if (own) {
          path = p.join(dir.path, '$id${p.extension(src)}');
          await File(src).copy(path);
        }
        var title = p.basenameWithoutExtension(items[i].value).replaceAll('_', ' ').trim();
        title = title.replaceAll(
            RegExp(
                r'\s*\(?(mp3\.pm|SpotiDownloader\.com|ytmp3\.cc|y2mate|tubidy|mp3juice|320kbps|fakaza|skull|beemp3s?|downloadming|djjohal|songspk|pagalworld|mrjatt|mp3paw|audiomack\.com|soundcloud\.com)\)?\s*',
                caseSensitive: false),
            '').trim();
        var artist = 'Unknown artist';
        final parts = title.split(' - ');
        if (parts.length > 1) {
          artist = parts.first.trim();
          title = parts.sublist(1).join(' - ').trim();
        }
        final s = Song(id, title, artist, path, own: own, fp: fp);
        if (fp != null) known.add(fp);
        pathSet.add(path);
        try {
          await _applyTags(s);
          await _enrich(s);
        } catch (_) {}
        songs.insert(0, s);
        n++;
      }
      return n;
    } finally {
      busy = null;
      touch();
    }
  }

  String _importMsg(int n) {
    if (n == 0 && lastDup > 0) return 'Already in your library';
    final base = 'Added $n song${n == 1 ? '' : 's'}';
    return lastDup > 0 ? '$base ($lastDup duplicate${lastDup == 1 ? '' : 's'} skipped)' : base;
  }

  Future<String> addPicked() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
    if (res == null) return '';
    final items = [for (final f in res.files) if (f.path != null) MapEntry(f.path!, f.name)];
    final n = await _import(items, true);
    return _importMsg(n);
  }

  Future<String> scanFolder() async {
    final ok = (await Permission.audio.request()).isGranted ||
        (await Permission.storage.request()).isGranted;
    if (!ok) {
      // FIX (bug 14): await so the settings page actually opens.
      try {
        await openAppSettings();
      } catch (_) {}
      return 'Allow "Music and audio" access for SoundWave, then try again';
    }
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return '';
    if (!folders.contains(dir)) folders.add(dir);
    return _rescan([dir]);
  }

  Future<String> rescan() =>
      folders.isEmpty ? Future.value('No folders yet. Use "Scan a folder" first.') : _rescan(folders);

  Future<String> _rescan(List<String> dirs) async {
    if (busy != null) return '';
    busy = 'Looking for music…';
    notifyListeners();
    try {
      final found = <MapEntry<String, String>>[];
      for (final d in dirs) {
        try {
          await for (final e
              in Directory(d).list(recursive: true, followLinks: false).handleError((_) {})) {
            if (e is File && _exts.contains(p.extension(e.path).toLowerCase())) {
              found.add(MapEntry(e.path, p.basename(e.path)));
            }
          }
        } catch (_) {}
      }
      final existing = {for (final s in songs) s.path};
      found.removeWhere((e) => existing.contains(e.key));
      if (found.isEmpty) return 'No new songs found';
      final n = await _import(found, false);
      return _importMsg(n);
    } finally {
      busy = null;
      touch();
    }
  }

  Future<void> remove(Song s) async {
    final i = player.currentIndex;
    final wasCurrent = i != null && i < queue.length && queue[i].id == s.id;
    if (wasCurrent) await player.stop();
    try {
      if (s.own) await File(s.path).delete();
      if (s.art != null) await File(s.art!).delete();
    } catch (_) {}
    songs.removeWhere((x) => x.id == s.id);
    liked.remove(s.id);
    recentIds.remove(s.id);
    for (final l in lists) {
      l.ids.remove(s.id);
    }
    // FIX (bug 7): drop the song from the active queue so MiniPlayer/NowPlaying
    // never index into a phantom entry. If nothing is playing, just clear it.
    queue.removeWhere((x) => x.id == s.id);
    touch();
  }

  // ---- playback
  int _playToken = 0;
  Future<void> play(List<Song> list, int i) async {
    if (list.isEmpty || i < 0 || i >= list.length) return;
    list = List<Song>.of(list);
    queue = list;
    final token = ++_playToken;
    final s = list[i];
    if (s.artist == 'Unknown artist' || (s.lyrics == null && s.syncedLyrics == null)) {
      _enrich(s).then((_) {
        save();
        notifyListeners();
      }).catchError((_) {});
    }
    final playedId = list[i].id;
    recentIds.remove(playedId);
    recentIds.insert(0, playedId);
    if (recentIds.length > 10) recentIds = recentIds.sublist(0, 10);
    notifyListeners();
    try {
      await player.setAudioSource(
        ConcatenatingAudioSource(children: [
          for (final s in list)
            AudioSource.file(s.path,
                tag: MediaItem(
                  id: s.id,
                  title: s.title,
                  artist: s.artist,
                  artUri: s.art != null ? Uri.file(s.art!) : null,
                  duration: s.dur > 0 ? Duration(milliseconds: s.dur) : null,
                ))
        ]),
        initialIndex: i,
      );
    } on PlayerInterruptedException {
      return;
    } catch (_) {
      // FIX (bug 10): corrupt file / missing path — don't crash the tap handler.
      if (token == _playToken) {
        queue = [];
        notifyListeners();
      }
      return;
    }
    if (token != _playToken) return;
    player.setLoopMode(loop);
    player.setShuffleModeEnabled(shuffle);
    player.setSpeed(speed);
    player.play();
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

String fmtD(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

Future<String?> askName(BuildContext c, String title, [String init = '']) {
  final ctl = TextEditingController(text: init);
  return showDialog<String>(