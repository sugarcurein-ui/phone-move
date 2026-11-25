import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'browser.dart';
import 'net.dart';

const String kDefaultDest = '/storage/emulated/0/Download/PhoneMove';

class RemoteFile {
  final String path; // relative path on the computer, uses /
  final int size;
  final int mtime;
  RemoteFile(this.path, this.size, this.mtime);
}

/// Screen 1: shows what is in the computer's Outbox folder, pick files /
/// folders, choose the phone folder, start.
class ReceiveScreen extends StatefulWidget {
  final Pc pc;
  const ReceiveScreen({super.key, required this.pc});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  List<RemoteFile> _all = [];
  bool _loading = true;
  String? _error;
  String _prefix = ''; // current folder inside the outbox, '' or 'a/b/'
  final Set<String> _sel = <String>{}; // 'a/b/' = folder, 'a/b.txt' = file
  String _dest = kDefaultDest;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _dest = p.getString('dest') ?? kDefaultDest;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await Api(widget.pc).list();
      _all = raw
          .map((m) => RemoteFile(
              (m['path'] ?? '').toString(),
              ((m['size'] ?? 0) as num).toInt(),
              ((m['mtime'] ?? 0) as num).toInt()))
          .where((f) => f.path.isNotEmpty)
          .toList();
    } on ApiError catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'లోపం: $e';
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  /// Entries directly inside [_prefix]: folders first (with counts), files.
  List<_Row> _rows() {
    final dirs = <String, _Row>{};
    final files = <_Row>[];
    for (final f in _all) {
      if (!f.path.startsWith(_prefix)) continue;
      final rest = f.path.substring(_prefix.length);
      final i = rest.indexOf('/');
      if (i < 0) {
        files.add(_Row(rest, '${_prefix}$rest', false, f.size, f.mtime, 1));
      } else {
        final name = rest.substring(0, i);
        final key = '$_prefix$name/';
        final r = dirs.putIfAbsent(key, () => _Row(name, key, true, 0, 0, 0));
        r.size += f.size;
        r.count += 1;
        if (f.mtime > r.mtime) r.mtime = f.mtime;
      }
    }
    final d = dirs.values.toList()..sort((a, b) => b.mtime.compareTo(a.mtime));
    files.sort((a, b) => b.mtime.compareTo(a.mtime));
    return [...d, ...files];
  }

  List<RemoteFile> _selectedFiles() {
    final out = <RemoteFile>[];
    for (final f in _all) {
      for (final s in _sel) {
        if (s.endsWith('/') ? f.path.startsWith(s) : f.path == s) {
          out.add(f);
          break;
        }
      }
    }
    return out;
  }

  void _goUp() {
    if (_prefix.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final t = _prefix.substring(0, _prefix.length - 1);
    final i = t.lastIndexOf('/');
    setState(() => _prefix = i < 0 ? '' : t.substring(0, i + 1));
  }

  void _toggleAllHere() {
    final rows = _rows();
    final all = rows.isNotEmpty && rows.every((r) => _sel.contains(r.key));
    setState(() {
      for (final r in rows) {
        if (all) {
          _sel.remove(r.key);
        } else {
          _sel.add(r.key);
        }
      }
    });
  }

  Future<void> _pickDest() async {
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BrowserScreen(pickFolder: true)),
    );
    if (picked == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('dest', picked);
    if (!mounted) return;
    setState(() => _dest = picked);
  }

  String _fmtDate(int sec) {
    if (sec <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${two(d.month)}-${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rows = _loading || _error != null ? <_Row>[] : _rows();
    final chosen = _selectedFiles();
    final chosenBytes = chosen.fold<int>(0, (a, f) => a + f.size);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          leading:
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goUp),
          title: Text(_prefix.isEmpty ? 'కంప్యూటర్ నుండి తీసుకో' : _prefix,
              style: const TextStyle(fontSize: 17)),
          actions: [
            IconButton(
                tooltip: 'మళ్లీ చూడు',
                icon: const Icon(Icons.refresh),
                onPressed: _load),
            IconButton(
                tooltip: 'ఈ ఫోల్డర్‌లో అన్నీ',
                icon: const Icon(Icons.select_all),
                onPressed: _toggleAllHere),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Text(_error!,
                                style: const TextStyle(fontSize: 17)),
                          ),
                        )
                      : rows.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(20),
                                child: Text(
                                    'కంప్యూటర్‌లోని Outbox ఫోల్డర్ ఖాళీగా ఉంది.\nఫోన్‌కి పంపాలనుకున్న ఫైళ్లను ఆ ఫోల్డర్‌లో పెట్టండి.',
                                    style: TextStyle(fontSize: 17)),
                              ),
                            )
                          : ListView.builder(
                              itemCount: rows.length,
                              itemBuilder: (ctx, i) {
                                final r = rows[i];
                                final sel = _sel.contains(r.key) ||
                                    _sel.any((s) =>
                                        s.endsWith('/') &&
                                        r.key.startsWith(s) &&
                                        s != r.key);
                                return ListTile(
                                  leading: Checkbox(
                                    value: sel,
                                    onChanged: (_) {
                                      setState(() {
                                        if (!_sel.add(r.key)) _sel.remove(r.key);
                                      });
                                    },
                                  ),
                                  title: Text(r.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: Text(r.isDir
                                      ? 'ఫోల్డర్ • ${r.count} ఫైళ్లు • ${fmtSize(r.size)}'
                                      : '${fmtSize(r.size)} • ${_fmtDate(r.mtime)}'),
                                  trailing: r.isDir
                                      ? const Icon(Icons.folder,
                                          color: Colors.amber, size: 30)
                                      : const Icon(
                                          Icons.insert_drive_file_outlined),
                                  selected: sel,
                                  onTap: () {
                                    if (r.isDir) {
                                      setState(() => _prefix = r.key);
                                    } else {
                                      setState(() {
                                        if (!_sel.add(r.key)) _sel.remove(r.key);
                                      });
                                    }
                                  },
                                );
                              },
                            ),
            ),
            Container(
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: SafeArea(
                top: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'ఫోన్‌లో ఎక్కడ పెట్టాలి:\n${_dest.replaceFirst('/storage/emulated/0/', '')}',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        TextButton(
                            onPressed: _pickDest, child: const Text('మార్చు')),
                      ],
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            chosen.isEmpty
                                ? 'ఏదీ ఎంచుకోలేదు'
                                : '${chosen.length} ఫైళ్లు • ${fmtSize(chosenBytes)}',
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: chosen.isEmpty
                              ? null
                              : () => Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => DownloadScreen(
                                          pc: widget.pc,
                                          files: chosen,
                                          dest: _dest),
                                    ),
                                  ),
                          icon: const Icon(Icons.download),
                          label: const Text('తీసుకో',
                              style: TextStyle(fontSize: 18)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row {
  final String name;
  final String key;
  final bool isDir;
  int size;
  int mtime;
  int count;
  _Row(this.name, this.key, this.isDir, this.size, this.mtime, this.count);
}

// ------------------------------------------------------------------ download

class _DItem {
  final RemoteFile rf;
  String dest = ''; // final phone path
  String state = 'new'; // new | done | failed
  int have = 0; // bytes already on phone when we started
  int got = 0; // bytes received in this attempt
  String? err;
  _DItem(this.rf);
  int get progress =>
      state == 'done' ? rf.size : (have + got).clamp(0, rf.size).toInt();
}

enum _Phase { preparing, running, finished, cancelled }

class DownloadScreen extends StatefulWidget {
  final Pc pc;
  final List<RemoteFile> files;
  final String dest;
  const DownloadScreen(
      {super.key, required this.pc, required this.files, required this.dest});

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  late final Api _api;
  final List<_DItem> _items = [];
  final Set<_DItem> _active = {};
  final Set<_DItem> _todo = {};
  _Phase _phase = _Phase.preparing;
  String _note = '';
  bool _cancel = false;
  Timer? _ticker;
  int _skipped = 0;
  int _totalBytes = 0;
  int _doneBytes = 0;
  int _doneFiles = 0;
  double _speed = 0;
  int _lastBytes = 0;
  DateTime _lastTick = DateTime.now();

  @override
  void initState() {
    super.initState();
    _api = Api(widget.pc);
    _ticker = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
    _run();
  }

  @override
  void dispose() {
    _cancel = true;
    _ticker?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    if (_phase == _Phase.running) {
      var bytes = 0;
      var files = 0;
      for (final it in _todo) {
        bytes += it.progress;
        if (it.state == 'done') files++;
      }
      final now = DateTime.now();
      final dt = now.difference(_lastTick).inMilliseconds / 1000.0;
      if (dt > 0) {
        final inst = (bytes - _lastBytes) / dt;
        _speed = _speed == 0 ? inst : _speed * 0.7 + inst * 0.3;
        if (_speed < 0) _speed = 0;
      }
      _lastBytes = bytes;
      _lastTick = now;
      _doneBytes = bytes;
      _doneFiles = files;
    }
    setState(() {});
  }

  /// Safe local path: never outside the destination folder.
  String? _localPath(String rel) {
    final parts = rel.replaceAll('\\', '/').split('/');
    final clean = <String>[];
    for (final p in parts) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') return null;
      clean.add(p.replaceAll(RegExp(r'[\x00-\x1f]'), '_'));
    }
    if (clean.isEmpty) return null;
    return '${widget.dest}/${clean.join('/')}';
  }

  String _altName(String path, int n) {
    final slash = path.lastIndexOf('/');
    final dir = path.substring(0, slash + 1);
    final name = path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot > 0) {
      return '$dir${name.substring(0, dot)} ($n)${name.substring(dot)}';
    }
    return '$dir$name ($n)';
  }

  /// Decide for each file: already there (skip), partial (resume), new, or
  /// conflict with a different file (use "name (2).ext", never overwrite).
  void _plan() {
    for (final f in widget.files) {
      final it = _DItem(f);
      final lp = _localPath(f.path);
      if (lp == null) continue;
      var target = lp;
      var n = 2;
      while (true) {
        final fe = File(target);
        if (fe.existsSync()) {
          if (fe.lengthSync() == f.size) {
            it.state = 'done';
            break;
          }
          target = _altName(lp, n++);
          if (n > 500) break;
          continue;
        }
        break;
      }
      it.dest = target;
      if (it.state != 'done') {
        final part = File('$target.part');
        if (part.existsSync()) {
          final l = part.lengthSync();
          it.have = l <= f.size ? l : 0;
        }
      }
      _items.add(it);
    }
  }

  Future<void> _run({bool retry = false}) async {
    _cancel = false;
    try {
      if (!retry) {
        setState(() {
          _phase = _Phase.preparing;
          _note = 'సిద్ధం చేస్తున్నాను…';
        });
        try {
          Directory(widget.dest).createSync(recursive: true);
        } catch (_) {
          setState(() {
            _phase = _Phase.cancelled;
            _note = 'ఈ ఫోల్డర్‌లో రాయలేకపోయాను. వేరే ఫోల్డర్ ఎంచుకోండి.';
          });
          return;
        }
        _plan();
        _skipped = _items.where((i) => i.state == 'done').length;
      } else {
        for (final it in _items.where((i) => i.state == 'failed')) {
          it.state = 'new';
          it.err = null;
          final p = File('${it.dest}.part');
          it.have = p.existsSync() ? p.lengthSync() : 0;
          it.got = 0;
        }
      }
      _todo
        ..clear()
        ..addAll(_items.where((i) => i.state != 'done'));
      _totalBytes = _todo.fold<int>(0, (a, i) => a + i.rf.size);
      _lastBytes = 0;
      _speed = 0;
      _lastTick = DateTime.now();
      setState(() {
        _phase = _Phase.running;
        _note = '';
      });
      await WakelockPlus.enable();

      final queue = _todo.toList();
      var next = 0;
      Future<void> worker() async {
        while (!_cancel) {
          if (next >= queue.length) return;
          final it = queue[next++];
          await _one(it);
        }
      }

      await Future.wait([worker(), worker(), worker()]);
      _tick();
      if (!mounted) return;
      setState(() {
        _phase = _cancel ? _Phase.cancelled : _Phase.finished;
        _note = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.cancelled;
        _note = 'లోపం వచ్చింది: $e';
      });
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<void> _one(_DItem it) async {
    _active.add(it);
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (_cancel) return;
        try {
          final part = File('${it.dest}.part');
          it.have = part.existsSync() ? part.lengthSync() : 0;
          it.got = 0;
          if (it.rf.size == 0) {
            part.parent.createSync(recursive: true);
            part.writeAsBytesSync(const <int>[]);
          } else {
            await _api.download(
              rel: it.rf.path,
              partPath: part.path,
              size: it.rf.size,
              onBytes: (n) => it.got += n,
              onReset: () {
                it.have = 0;
                it.got = 0;
              },
              isCancelled: () => _cancel,
            );
          }
          // verified by size: now give it its real name
          final fin = File(it.dest);
          if (fin.existsSync()) {
            // someone created it meanwhile; keep both
            it.dest = _altName(it.dest, 2);
          }
          await part.rename(it.dest);
          try {
            await File(it.dest).setLastModified(
                DateTime.fromMillisecondsSinceEpoch(it.rf.mtime * 1000));
          } catch (_) {}
          it.state = 'done';
          it.err = null;
          return;
        } on CancelledError {
          return;
        } catch (e) {
          it.err = e.toString();
          if (_cancel) return;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      it.state = 'failed';
    } finally {
      _active.remove(it);
    }
  }

  String _eta() {
    final remain = _totalBytes - _doneBytes;
    if (_speed < 1024 || remain <= 0) return '';
    final secs = (remain / _speed).round();
    final m = secs ~/ 60;
    final s = secs % 60;
    return 'మిగిలిన సమయం సుమారు ${m > 0 ? '$m నిమి ' : ''}$s సెకన్లు';
  }

  Future<bool> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ఆపేయాలా?'),
        content: const Text(
            'ఆపినా తీసుకున్నంత వరకు ఫోన్‌లో ఉంటుంది. తరువాత మళ్లీ తీసుకుంటే మిగిలినవే వస్తాయి.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('కొనసాగించు')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ఆపు')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final failed = _items.where((i) => i.state == 'failed').toList();
    final busy = _phase == _Phase.preparing || _phase == _Phase.running;
    final double frac = _totalBytes == 0
        ? (_phase == _Phase.finished ? 1.0 : 0.0)
        : (_doneBytes / _totalBytes).clamp(0.0, 1.0).toDouble();

    String title;
    switch (_phase) {
      case _Phase.preparing:
        title = 'సిద్ధం చేస్తున్నాను…';
        break;
      case _Phase.running:
        title = 'తీసుకుంటున్నాను…';
        break;
      case _Phase.finished:
        title = failed.isEmpty ? 'అన్నీ వచ్చాయి ✔' : 'పూర్తయింది, కొన్ని విఫలం';
        break;
      case _Phase.cancelled:
        title = 'ఆగింది';
        break;
    }

    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmStop()) {
          _cancel = true;
          if (mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_note, style: const TextStyle(fontSize: 16)),
              ),
            if (_phase != _Phase.preparing) ...[
              LinearProgressIndicator(value: frac, minHeight: 14),
              const SizedBox(height: 10),
              Text(
                '${(frac * 100).toStringAsFixed(0)}%   •   ${fmtSize(_doneBytes)} / ${fmtSize(_totalBytes)}',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              if (_phase == _Phase.running)
                Text('వేగం: ${fmtSize(_speed)}/సె.   ${_eta()}',
                    style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                'ఫైళ్లు: $_doneFiles / ${_todo.length}'
                '${_skipped > 0 ? '   •   ఇప్పటికే ఫోన్‌లో ఉన్నవి: $_skipped' : ''}'
                '${failed.isNotEmpty ? '   •   విఫలం: ${failed.length}' : ''}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text('ఫోన్‌లో: ${widget.dest.replaceFirst('/storage/emulated/0/', '')}',
                  style: const TextStyle(fontSize: 14, color: Colors.black54)),
              const SizedBox(height: 14),
            ],
            if (_phase == _Phase.running)
              for (final it in _active.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(it.rf.path,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(
                          value: it.rf.size == 0
                              ? 1.0
                              : it.progress / it.rf.size),
                      Text('${fmtSize(it.progress)} / ${fmtSize(it.rf.size)}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                    ],
                  ),
                ),
            if (failed.isNotEmpty) ...[
              const Divider(),
              const Text('విఫలమైనవి:',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              for (final it in failed.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Text('• ${it.rf.path}\n   ${it.err ?? ''}',
                      style: const TextStyle(fontSize: 13)),
                ),
              if (failed.length > 10) Text('… ఇంకా ${failed.length - 10}'),
            ],
            const SizedBox(height: 16),
            if (busy)
              OutlinedButton.icon(
                onPressed: () async {
                  if (await _confirmStop()) setState(() => _cancel = true);
                },
                icon: const Icon(Icons.stop),
                label: const Text('ఆపు'),
              ),
            if (_phase == _Phase.finished && failed.isNotEmpty)
              FilledButton.icon(
                onPressed: () => _run(retry: true),
                icon: const Icon(Icons.refresh),
                label: const Text('మళ్లీ ప్రయత్నించు (విఫలమైనవి)'),
              ),
            if (_phase == _Phase.cancelled && _items.isNotEmpty)
              FilledButton.icon(
                onPressed: () => _run(retry: true),
                icon: const Icon(Icons.refresh),
                label: const Text('కొనసాగించు (మిగిలినవే వస్తాయి)'),
              ),
            if (!busy) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('వెనక్కి', style: TextStyle(fontSize: 17)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
