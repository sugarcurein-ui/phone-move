import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'net.dart';

class Item {
  final String path; // path on phone
  final String rel; // path to create on the computer
  final int size;
  final int mtime; // seconds
  String state = 'new'; // new | partial | done | failed | error
  String saveAs = '';
  int have = 0; // bytes already safe on the computer
  int sentNow = 0; // bytes sent in the current attempt
  String? err;
  Item(this.path, this.rel, this.size, this.mtime);

  int get progress => state == 'done' ? size : (have + sentNow).clamp(0, size).toInt();
}

enum Phase { preparing, checking, sending, finished, cancelled }

class TransferScreen extends StatefulWidget {
  final Pc pc;
  final List<String> paths;
  const TransferScreen({super.key, required this.pc, required this.paths});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  late final Api _api;
  final List<Item> _items = [];
  Phase _phase = Phase.preparing;
  String _note = '';
  bool _cancel = false;
  Timer? _ticker;
  int _skipped = 0; // already on the computer at start
  int _toSendCount = 0;
  int _toSendBytes = 0;
  int _doneBytes = 0;
  int _doneFiles = 0;
  double _speed = 0; // bytes/sec smoothed
  int _lastBytes = 0;
  DateTime _lastTick = DateTime.now();
  final Set<Item> _active = {};
  final Set<Item> _toSendSet = {};

  @override
  void initState() {
    super.initState();
    _api = Api(widget.pc);
    _ticker = Timer.periodic(const Duration(milliseconds: 700), (_) => _tick());
    _run(first: true);
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
    if (_phase == Phase.sending) {
      var bytes = 0;
      var files = 0;
      for (final it in _items) {
        if (_toSendSet.contains(it)) {
          bytes += it.progress;
          if (it.state == 'done') files++;
        }
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

  // ------------------------------------------------------------ prepare

  Future<void> _buildItems() async {
    final seen = <String>{};
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final day = '${now.year}-${two(now.month)}-${two(now.day)}';

    for (final p in widget.paths) {
      if (_cancel) return;
      final type = FileSystemEntity.typeSync(p, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        final root = p.split('/').last;
        final stream = Directory(p)
            .list(recursive: true, followLinks: false)
            .handleError((Object _) {});
        await for (final e in stream) {
          if (_cancel) return;
          if (e is! File) continue;
          if (e.path.length <= p.length + 1) continue;
          final rel = e.path.substring(p.length + 1);
          if (rel.split('/').any((s) => s.startsWith('.'))) continue;
          if (!seen.add(e.path)) continue;
          try {
            final st = await e.stat();
            _items.add(Item(e.path, '$root/$rel', st.size,
                st.modified.millisecondsSinceEpoch ~/ 1000));
          } catch (_) {}
          if (_items.length % 200 == 0) {
            _note = '${_items.length} ఫైళ్లు కనుగొన్నాను…';
            if (mounted) setState(() {});
          }
        }
      } else if (type == FileSystemEntityType.file) {
        if (!seen.add(p)) continue;
        try {
          final st = await File(p).stat();
          final name = p.split('/').last;
          _items.add(Item(p, 'Files_$day/$name', st.size,
              st.modified.millisecondsSinceEpoch ~/ 1000));
        } catch (_) {}
      }
    }
  }

  Future<void> _checkItems(List<Item> list) async {
    const batch = 300;
    for (var i = 0; i < list.length; i += batch) {
      if (_cancel) return;
      final end = (i + batch > list.length) ? list.length : i + batch;
      final part = list.sublist(i, end);
      final res = await _api.check(
          part.map((it) => <String, dynamic>{'path': it.rel, 'size': it.size}).toList());
      for (var k = 0; k < part.length && k < res.length; k++) {
        final it = part[k];
        final r = res[k];
        it.state = (r['state'] ?? 'error').toString();
        it.saveAs = (r['saveAs'] ?? '').toString();
        it.have = ((r['have'] ?? 0) as num).toInt();
        it.sentNow = 0;
        it.err = null;
      }
      _note = 'కంప్యూటర్‌లో ఉన్నవి తనిఖీ చేస్తున్నాను… $end / ${list.length}';
      if (mounted) setState(() {});
    }
  }

  // ------------------------------------------------------------ run

  Future<void> _run({bool first = false}) async {
    _cancel = false;
    try {
      if (first) {
        setState(() {
          _phase = Phase.preparing;
          _note = 'ఫైళ్ల జాబితా తయారవుతోంది…';
        });
        await _buildItems();
        if (_cancel) return;
        if (_items.isEmpty) {
          setState(() {
            _phase = Phase.finished;
            _note = 'పంపడానికి ఫైళ్లు ఏవీ లేవు';
          });
          return;
        }
      }
      setState(() {
        _phase = Phase.checking;
        _note = 'కంప్యూటర్‌తో సరిచూస్తున్నాను…';
      });
      final todo = first
          ? List<Item>.from(_items)
          : _items.where((it) => it.state == 'failed').toList();
      await _checkItems(todo);
      if (_cancel) return;

      if (first) {
        _skipped = _items.where((it) => it.state == 'done').length;
      }
      _toSendSet
        ..clear()
        ..addAll(_items.where((it) => it.state != 'done' && it.state != 'error'));
      _toSendCount = _toSendSet.length;
      _toSendBytes = _toSendSet.fold<int>(0, (a, it) => a + it.size);
      _lastBytes = 0;
      _speed = 0;
      _lastTick = DateTime.now();
      for (final it in _toSendSet) {
        it.err = null;
      }

      setState(() => _phase = Phase.sending);
      await WakelockPlus.enable();

      final queue = _toSendSet.toList();
      var next = 0;
      Future<void> worker() async {
        while (!_cancel) {
          if (next >= queue.length) return;
          final it = queue[next++];
          await _sendOne(it);
        }
      }

      await Future.wait([worker(), worker(), worker()]);
      _tick();
      if (!mounted) return;
      setState(() {
        _phase = _cancel ? Phase.cancelled : Phase.finished;
        _note = '';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.cancelled;
        _note = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.cancelled;
        _note = 'లోపం వచ్చింది: $e';
      });
    } finally {
      await WakelockPlus.disable();
    }
  }

  Future<void> _sendOne(Item it) async {
    _active.add(it);
    try {
      for (var attempt = 0; attempt < 4; attempt++) {
        if (_cancel) return;
        try {
          final len = await File(it.path).length();
          if (len != it.size) throw ApiError('ఫైల్ పంపే సమయంలో మారింది');
          it.sentNow = 0;
          await _api.upload(
            filePath: it.path,
            saveAs: it.saveAs,
            size: it.size,
            offset: it.have,
            mtimeSec: it.mtime,
            onBytes: (n) => it.sentNow += n,
            isCancelled: () => _cancel,
          );
          it.state = 'done';
          it.err = null;
          return;
        } on CancelledError {
          return;
        } catch (e) {
          it.err = e.toString();
          if (_cancel) return;
          await Future<void>.delayed(const Duration(seconds: 2));
          try {
            final r = await _api.check(
                [<String, dynamic>{'path': it.rel, 'size': it.size}]);
            final x = r.first;
            if (x['state'] == 'done') {
              it.state = 'done';
              it.err = null;
              return;
            }
            it.saveAs = (x['saveAs'] ?? it.saveAs).toString();
            it.have = ((x['have'] ?? 0) as num).toInt();
            it.sentNow = 0;
          } catch (_) {
            // computer not reachable right now; try again
          }
        }
      }
      it.state = 'failed';
    } finally {
      _active.remove(it);
    }
  }

  // ------------------------------------------------------------ delete (optional, asks first)

  Future<void> _offerDelete() async {
    final safe = _items.where((it) => it.state == 'done').toList();
    if (safe.isEmpty) return;
    final total = safe.fold<int>(0, (a, it) => a + it.size);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ఫోన్ నుండి తొలగించాలా?'),
        content: Text(
            '${safe.length} ఫైళ్లు (${fmtSize(total)}) కంప్యూటర్‌లో సురక్షితంగా ఉన్నాయి (సైజు సరిపోయింది). ఫోన్ నుండి వీటిని తొలగిస్తే తిరిగి రావు.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('వద్దు')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('సరే, తొలగించు')),
        ],
      ),
    );
    if (ok != true) return;
    var deleted = 0;
    for (final it in safe) {
      try {
        await File(it.path).delete();
        deleted++;
      } catch (_) {}
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$deleted ఫైళ్లు తొలగించాను')));
  }

  // ------------------------------------------------------------ UI

  String _eta() {
    final remain = _toSendBytes - _doneBytes;
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
            'ఆపినా పంపినంత వరకు కంప్యూటర్‌లో ఉంటుంది. తరువాత మళ్లీ పంపితే మిగిలినవే వెళ్తాయి.'),
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
    final failed = _items.where((it) => it.state == 'failed').toList();
    final busy = _phase == Phase.preparing ||
        _phase == Phase.checking ||
        _phase == Phase.sending;
    final double frac =
        _toSendBytes == 0 ? 0.0 : (_doneBytes / _toSendBytes).clamp(0.0, 1.0).toDouble();

    String title;
    switch (_phase) {
      case Phase.preparing:
        title = 'సిద్ధం చేస్తున్నాను…';
        break;
      case Phase.checking:
        title = 'సరిచూస్తున్నాను…';
        break;
      case Phase.sending:
        title = 'పంపుతున్నాను…';
        break;
      case Phase.finished:
        title = failed.isEmpty ? 'అన్నీ వెళ్లాయి ✔' : 'పూర్తయింది, కొన్ని విఫలం';
        break;
      case Phase.cancelled:
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
            if (_phase == Phase.sending ||
                _phase == Phase.finished ||
                _phase == Phase.cancelled) ...[
              LinearProgressIndicator(value: frac, minHeight: 14),
              const SizedBox(height: 10),
              Text(
                '${(frac * 100).toStringAsFixed(0)}%   •   ${fmtSize(_doneBytes)} / ${fmtSize(_toSendBytes)}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              if (_phase == Phase.sending)
                Text('వేగం: ${fmtSize(_speed)}/సె.   ${_eta()}',
                    style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                'ఫైళ్లు: $_doneFiles / $_toSendCount'
                '${_skipped > 0 ? '   •   ఇప్పటికే ఉన్నవి: $_skipped' : ''}'
                '${failed.isNotEmpty ? '   •   విఫలం: ${failed.length}' : ''}',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 14),
            ],
            if (_phase == Phase.sending)
              for (final it in _active.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(it.rel, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      LinearProgressIndicator(
                          value: it.size == 0 ? 1.0 : it.progress / it.size),
                      Text('${fmtSize(it.progress)} / ${fmtSize(it.size)}',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
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
                  child: Text('• ${it.rel}\n   ${it.err ?? ''}',
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
            if (_phase == Phase.finished && failed.isNotEmpty)
              FilledButton.icon(
                onPressed: () => _run(),
                icon: const Icon(Icons.refresh),
                label: const Text('మళ్లీ పంపు (విఫలమైనవి)'),
              ),
            if (_phase == Phase.cancelled)
              FilledButton.icon(
                onPressed: () {
                  _items.clear();
                  _run(first: true);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('మళ్లీ పంపు (మిగిలినవే వెళ్తాయి)'),
              ),
            if (_phase == Phase.finished &&
                failed.isEmpty &&
                _items.any((it) => it.state == 'done')) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _offerDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('ఫోన్ నుండి తొలగించు (అడిగాకే)'),
              ),
            ],
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
