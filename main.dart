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
    if (rec == null || bestSim < 0.75) return null;
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
        if (ts < 0.6) continue;
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
      if (best != null && bestScore >= 1.2) break;
    } catch (_) {}
  }
  if (best == null) return {'plain': null, 'synced': null};
  final synced = ((best['syncedLyrics'] as String?) ?? '').trim();
  final plain = ((best['plainLyrics'] as String?) ?? '').trim();
  return {'plain': plain.isEmpty ? null : plain, 'synced': synced.isEmpty ? null : synced};
}

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
      final m = RegExp(r'(\d+)\s*$').firstMatch(tag);
      final build = m != null ? int.parse(m.group(1)!) : 0;
      String? url;
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
      client.close();
      updating = false;
      updatePct = null;
      notifyListeners();
    }
  }

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
        s.lyrics = null;
      }
      if (map['synced'] != null) s.syncedLyrics = map['synced'];
    }
  }

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

  Future<void> editSongInfo(Song s, String newTitle, String newArtist) async {
    s.title = newTitle.trim().isEmpty ? s.title : newTitle.trim();
    s.artist = newArtist.trim().isEmpty ? s.artist : newArtist.trim();
    s.syncedLyrics = null;
    save();
    notifyListeners();
    _enrich(s, force: true).then((_) {
      save();
      notifyListeners();
    }).catchError((_) {});
  }

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
        var title = p.basenameWithoutExtension(items[i].value).replaceAll('_', ' ').tr// ---------------------------------------------------------------- helpers
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
    context: c,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<void> editSongInfo(BuildContext c, Song s) async {
  final titleCtl = TextEditingController(text: s.title);
  final artistCtl = TextEditingController(text: s.artist == 'Unknown artist' ? '' : s.artist);
  final confirmed = await showDialog<bool>(
    context: c,
    builder: (d) => AlertDialog(
      title: const Text('Edit song info'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
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
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(d, true),
          child: const Text('Save & refresh'),
        ),
      ],
    ),
  );
  if (confirmed != true) {
    titleCtl.dispose();
    artistCtl.dispose();
    return;
  }
  final newTitle = titleCtl.text.trim();
  final newArtist = artistCtl.text.trim();
  titleCtl.dispose();
  artistCtl.dispose();
  await store.editSongInfo(s, newTitle, newArtist.isEmpty ? 'Unknown artist' : newArtist);
  if (c.mounted) snack(c, 'Saved — fetching lyrics…');
}

void addToPlaylist(BuildContext c, Song s) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
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
      ]),
    ),
  );
}

void pickSpeed(BuildContext c) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final v in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          ListTile(
            title: Text('${v}x'),
            trailing: store.speed == v ? const Icon(Icons.check, color: green) : null,
            onTap: () {
              store.setSpeed(v);
              Navigator.pop(d);
            },
          ),
      ]),
    ),
  );
}

void pickSleep(BuildContext c) {
  showModalBottomSheet(
    context: c,
    builder: (d) => SafeArea(
      child: ListView(shrinkWrap: true, children: [
        for (final m in <int?>[null, 5, 15, 30, 45, 60])
          ListTile(
            title: Text(m == null ? 'Off' : '$m minutes'),
            onTap: () {
              store.setSleep(m);
              Navigator.pop(d);
            },
          ),
      ]),
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
      decoration: BoxDecoration(color: _col(s.title), borderRadius: BorderRadius.circular(radius)),
      child: Icon(Icons.music_note, color: Colors.white70, size: size * .5),
    );
    final a = s.art;
    if (a == null || !File(a).existsSync()) return ph;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(File(a),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 2).round(),
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => ph),
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
    try {
      final m = await f;
      if (m.isNotEmpty && mounted) snack(context, m);
    } catch (e) {
      if (mounted) snack(context, 'Something went wrong: $e');
    }
  }

  Widget _tile(List<Song> list, int i, String? cur, Playlist? pl) {
    final s = list[i];
    final on = s.id == cur, lk = store.liked.contains(s.id);
    return ListTile(
      leading: Art(s, 48),
      title: Text(s.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: on ? green : Colors.white, fontWeight: FontWeight.w600)),
      subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (s.dur > 0)
          Text(fmtD(Duration(milliseconds: s.dur)),
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        IconButton(
            icon: Icon(lk ? Icons.favorite : Icons.favorite_border,
                color: lk ? green : Colors.white54),
            onPressed: () => store.like(s.id)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'pl') {
              addToPlaylist(context, s);
            } else if (v == 'edit') {
              await editSongInfo(context, s);
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
            PopupMenuItem(
                value: 'rm',
                child: Text(pl != null ? 'Remove from this playlist' : 'Remove from library')),
          ],
        ),
      ]),
      onTap: () => on ? (player.playing ? player.pause() : player.play()) : store.play(list, i),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Row(children: [
          if (back != null) back else const SizedBox(width: 8),
          Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          if (menu != null) menu,
        ]),
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
                    borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)),
          ),
        ),
      Row(children: [
        const SizedBox(width: 8),
        IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: green, foregroundColor: Colors.black),
            iconSize: 30,
            icon: const Icon(Icons.play_arrow),
            onPressed: list.isEmpty ? null : () => store.play(list, 0)),
        IconButton(
            icon: Icon(Icons.shuffle, color: store.shuffle ? green : Colors.white70),
            onPressed: store.toggleShuffle),
        const Spacer(),
        Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('${list.length} songs', style: const TextStyle(color: Colors.white54))),
      ]),
      Expanded(
        child: body ??
            (list.isEmpty
                ? Center(
                    child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(empty,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white54))))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) => _tile(list, i, cur, pl))),
      ),
    ]);
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
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'add', child: Text('Add songs')),
          PopupMenuItem(value: 'scan', child: Text('Scan a folder')),
          PopupMenuItem(value: 'rescan', child: Text('Rescan saved folders')),
          PopupMenuItem(value: 'tags', child: Text('Refresh album art & tags')),
          PopupMenuItem(value: 'enrich', child: Text('Refresh lyrics & artist')),
        ],
      );

  Widget _home(String? cur) {
    final songs = store.songs;
    final h = DateTime.now().hour;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening',
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
      const SizedBox(height: 16),
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
                      color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(6)),
                  clipBehavior: Clip.antiAlias,
                  child: Row(children: [
                    Art(songs[i], 56, radius: 0),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(songs[i].title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: songs[i].id == cur ? green : Colors.white))),
                    const SizedBox(width: 6),
                  ]),
                ),
              ),
          ],
        ),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: green,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(0, 50)),
              onPressed: () => _run(store.addPicked()),
              icon: const Icon(Icons.add),
              label: const Text('Add songs', style: TextStyle(fontWeight: FontWeight.w700))),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50)),
              onPressed: () => _run(store.scanFolder()),
              icon: const Icon(Icons.folder_open),
              label: const Text('Scan folder')),
        ),
      ]),
      if (songs.isEmpty)
        const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Text(
                'Your library is empty. Add songs, or scan a folder like Music or Download to import everything in it.',
                style: TextStyle(color: Colors.white70))),
      if (songs.length > 6) ...[
        const SizedBox(height: 24),
        const Text('Recently added', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
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
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Art(songs[i], 130, radius: 8),
                  const SizedBox(height: 6),
                  Text(songs[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(songs[i].artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _playlists() {
    final ls = store.lists;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          const Expanded(
              child: Text('Playlists',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800))),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: green, foregroundColor: Colors.black),
            onPressed: () async {
              final n = await askName(context, 'New playlist');
              if (n != null && n.isNotEmpty) store.newList(n);
            },
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
        ]),
      ),
      Expanded(
        child: ls.isEmpty
            ? const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                        'Create a playlist, then use the ⋮ menu on any song to add it.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54))))
            : ListView(children: [
                for (final l in ls)
                  ListTile(
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                          color: _col(l.name), borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.queue_music, color: Colors.white70),
                    ),
                    title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${l.ids.length} songs'),
                    onTap: () => setState(() => openPl = l.id),
                  ),
              ]),
      ),
    ]);
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
          icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => openPl = null)),
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

  Widget _libraryBody(String? cur) {
    final allSongs = store.songs;
    if (q.isNotEmpty) {
      final k = q.toLowerCase();
      final filtered =
          allSongs.where((s) => '${s.title} ${s.artist}'.toLowerCase().contains(k)).toList();
      if (filtered.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('No matches',
                style: TextStyle(color: Colors.white54)),
          ),
        );
      }
      return ListView.builder(
          itemCount: filtered.length, itemBuilder: (c, i) => _tile(filtered, i, cur, null));
    }
    final recentSongs =
        store.recentIds.map(store.byId).whereType<Song>().toList();
    return ListView(children: [
      if (recentSongs.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('Recently played',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white70)),
        ),
        for (var i = 0; i < recentSongs.length; i++) _tile(recentSongs, i, cur, null),
        const Divider(color: Colors.white12, height: 24),
      ],
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Text('All songs',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white70)),
      ),
      if (allSongs.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Tap + to add songs or scan a folder',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
        )
      else
        for (var i = 0; i < allSongs.length; i++) _tile(allSongs, i, cur, null),
    ]);
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
                .where((s) => '${s.title} ${s.artist}'.toLowerCase().contains(k))
                .toList();
        return _songPage(
          title: 'Your Library',
          list: displayList,
          cur: cur,
          search: true,
          menu: _libMenu(),
          empty: 'Tap + to add songs or scan a folder',
          body: _libraryBody(cur),
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
        if (!store.ready) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
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
              child: Column(children: [
                if (store.busy != null)
                  Container(
                    width: double.infinity,
                    color: green,
                    padding: const EdgeInsets.all(8),
                    child: Text(store.busy!,
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
                  ),
                if (store.updateUrl != null)
                  Material(
                    color: const Color(0xFF2A2A2A),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.system_update, color: green),
                      title: Text(store.updating
                          ? 'Downloading update…'
                          : 'Update available (${store.updateTag})'),
                      subtitle: store.updating
                          ? LinearProgressIndicator(value: store.updatePct)
                          : null,
                      trailing: store.updating
                          ? null
                          : FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: green, foregroundColor: Colors.black),
                              onPressed: () => _run(store.installUpdate()),
                              child: const Text('Update')),
                    ),
                  ),
                Expanded(
                  child: StreamBuilder<int?>(
                    stream: player.currentIndexStream,
                    builder: (c, sn) {
                      final i = sn.data;
                      final cur = (i != null && i >= 0 && i < store.queue.length)
                          ? store.queue[i].id
                          : null;
                      return _page(cur);
                    },
                  ),
                ),
                const MiniPlayer(),
              ]),
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
                    label: 'Home'),
                NavigationDestination(
                    icon: Icon(Icons.library_music_outlined),
                    selectedIcon: Icon(Icons.library_music),
                    label: 'Library'),
                NavigationDestination(
                    icon: Icon(Icons.queue_music_outlined),
                    selectedIcon: Icon(Icons.queue_music),
                    label: 'Playlists'),
                NavigationDestination(
                    icon: Icon(Icons.favorite_border),
                    selectedIcon: Icon(Icons.favorite),
                    label: 'Liked'),
              ],
            ),
          ),
        );
      },
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
          if (i == null || i < 0 || i >= store.queue.length) return const SizedBox.shrink();
          final s = store.queue[i];
          final lk = store.liked.contains(s.id);
          return Container(
            color: const Color(0xFF1E1E1E),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const NowPlaying())),
                    child: Row(children: [
                      Art(s, 44),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ]),
                      ),
                    ]),
                  ),
                ),
                IconButton(
                    icon: Icon(lk ? Icons.favorite : Icons.favorite_border,
                        color: lk ? green : Colors.white70),
                    onPressed: () => store.like(s.id)),
                IconButton(
                    icon: const Icon(Icons.skip_previous),
                    onPressed: () => player.seekToPrevious()),
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (c, st) {
                    final playing = st.data?.playing ?? false;
                    return IconButton.filled(
                      style: IconButton.styleFrom(
                          backgroundColor: Colors.white, foregroundColor: Colors.black),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () => playing ? player.pause() : player.play(),
                    );
                  },
                ),
                IconButton(
                    icon: const Icon(Icons.skip_next), onPressed: () => player.seekToNext()),
              ]),
              const SeekBar(),
            ]),
          );
        },
      ),
    );
  }
}

class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => StreamBuilder<int?>(
        stream: player.currentIndexStream,
        builder: (c, snap) {
          final i = snap.data;
          if (i == null || i < 0 || i >= store.queue.length) {
            return Scaffold(
                appBar: AppBar(), body: const Center(child: Text('Nothing playing')));
          }
          final s = store.queue[i];
          final lk = store.liked.contains(s.id);
          final sleep = store.sleepAt;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_col(s.title), const Color(0xFF121212)],
                stops: const [0, .7],
              ),
            ),
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                centerTitle: true,
                title: const Text('Now playing', style: TextStyle(fontSize: 14)),
                leading: IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                    onPressed: () => Navigator.of(context).pop()),
              ),
              body: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (c, b) =>
                          Center(child: Art(s, min(b.maxWidth, b.maxHeight), radius: 12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                        Text(s.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16, color: Colors.white70)),
                      ]),
                    ),
                    IconButton(
                        iconSize: 30,
                        icon: Icon(lk ? Icons.favorite : Icons.favorite_border,
                            color: lk ? green : Colors.white),
                        onPressed: () => store.like(s.id)),
                  ]),
                  const SeekBar(),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    IconButton(
                        icon: Icon(Icons.shuffle,
                            color: store.shuffle ? green : Colors.white70),
                        onPressed: store.toggleShuffle),
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () => player.seekToPrevious()),
                    StreamBuilder<PlayerState>(
                      stream: player.playerStateStream,
                      builder: (c, st) {
                        final playing = st.data?.playing ?? false;
                        return IconButton.filled(
                          iconSize: 40,
                          style: IconButton.styleFrom(
                              backgroundColor: Colors.white, foregroundColor: Colors.black),
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          onPressed: () => playing ? player.pause() : player.play(),
                        );
                      },
                    ),
                    IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () => player.seekToNext()),
                    IconButton(
                        icon: Icon(
                            store.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                            color: store.loop == LoopMode.off ? Colors.white70 : green),
                        onPressed: store.cycleLoop),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                    ActionChip(
                        avatar: const Icon(Icons.speed, size: 18),
                        label: Text('${store.speed}x'),
                        onPressed: () => pickSpeed(context)),
                    ActionChip(
                        avatar: const Icon(Icons.bedtime_outlined, size: 18),
                        label: Text(sleep == null
                            ? 'Sleep timer'
                            : '~${sleep.difference(DateTime.now()).inMinutes + 1}m'),
                        onPressed: () => pickSleep(context)),
                    _LyricsChip(key: ValueKey(s.id), s: s),
                  ]),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _LyricsChip extends StatefulWidget {
  final Song s;
  const _LyricsChip({super.key, required this.s});
  @override
  State<_LyricsChip> createState() => _LyricsChipState();
}

class _LyricsChipState extends State<_LyricsChip> {
  bool _fetching = false;

  Future<void> _fetchAndOpen() async {
    final s = widget.s;
    if ((s.lyrics != null && !s.lyrics!.startsWith('http')) || s.syncedLyrics != null) {
      _open(s);
      return;
    }
    setState(() => _fetching = true);
    final map = await _fetchLrcLibLyrics(s.title, s.artist, durMs: s.dur);
    if (map['plain'] != null) s.lyrics = map['plain'];
    if (map['synced'] != null) s.syncedLyrics = map['synced'];
    store.save();
    store.ping();
    if (!mounted) return;
    setState(() => _fetching = false);
    if (s.lyrics == null && s.syncedLyrics == null) {
      snack(context, 'No lyrics found for "${s.title}"');
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
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
              child: CircularProgressIndicator(strokeWidth: 2, color: green))
          : const Icon(Icons.lyrics_outlined, size: 18),
      label: const Text('Lyrics'),
      onPressed: _fetching ? null : _fetchAndOpen,
    );
  }
}

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
  static const double _lineHeight = 44.0;
  int _lastAutoIdx = -1;
  bool _userScrolling = false;
  Timer? _resumeTimer;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController();
    _sc.addListener(_onScroll);
    _isSynced = widget.s.syncedLyrics != null;
    _lines = _isSynced ? parseLrc(widget.s.syncedLyrics!) : [];
  }

  void _onScroll() {
    // Treat any scroll not initiated by us as a user gesture.
    if (_userScrolling) return;
    _userScrolling = true;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(seconds: 3), () {
      _userScrolling = false;
    });
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _sc.removeListener(_onScroll);
    _sc.dispose();
    super.dispose();
  }

  void _scrollToLine(int idx) {
    if (!_sc.hasClients || _userScrolling) return;
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
      builder: (_, sheetSc) => Column(children: [
        const SizedBox(height: 12),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
              color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white54),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ]),
        ),
        Text(widget.s.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        Text(widget.s.artist,
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
        const Divider(height: 24, color: Colors.white12),
        Expanded(
          child: _isSynced
              ? StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (ctx, snap) {
                    final posMs = snap.data?.inMilliseconds ?? 0;
                    var curIdx = -1;
                    for (var i = 0; i < _lines.length; i++) {
                      if (_lines[i].ms <= posMs) curIdx = i;
                    }
                    if (curIdx >= 0 && curIdx != _lastAutoIdx) {
                      _lastAutoIdx = curIdx;
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => _scrollToLine(curIdx));
                    }
                    return ListView.builder(
                      controller: _sc,
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                      itemCount: _lines.length,
                      itemBuilder: (c, i) {
                        final isCur = i == curIdx;
                        return SizedBox(
                          height: _lineHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _lines[i].line,
                              style: TextStyle(
                                fontSize: isCur ? 17 : 15,
                                fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                                color: isCur ? Colors.white : Colors.white54,
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
                    style: const TextStyle(fontSize: 15, height: 1.8, color: Colors.white70),
                  ),
                ),
        ),
      ]),
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
            final mx = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
            final v = pos.inMilliseconds.toDouble().clamp(0.0, mx).toDouble();
            return Row(children: [
              Text(fmtD(pos), style: const TextStyle(fontSize: 11, color: Colors.white70)),
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
              Text(fmtD(dur), style: const TextStyle(fontSize: 11, color: Colors.white70)),
              const SizedBox(width: 8),
            ]);
          },
        );
      },
    );
  }
}
// END_OF_SOUNDWAVE