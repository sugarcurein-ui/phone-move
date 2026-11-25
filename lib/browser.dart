import 'dart:io';

import 'package:flutter/material.dart';

import 'net.dart';

const String kRoot = '/storage/emulated/0';

class _Entry {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;
  _Entry(this.path, this.name, this.isDir, this.size, this.modified);
}

/// A simple file manager. Tick folders (whole folder is sent) or single files.
/// Pops with the list of selected paths.
class BrowserScreen extends StatefulWidget {
  /// When true: shows only folders and pops with the one chosen folder path.
  final bool pickFolder;
  const BrowserScreen({super.key, this.pickFolder = false});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  String _current = kRoot;
  List<_Entry> _entries = [];
  final Set<String> _selected = <String>{};
  bool _newestFirst = true;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(kRoot);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final list = <_Entry>[];
    String? err;
    try {
      for (final e in Directory(path).listSync(followLinks: false)) {
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        FileStat st;
        try {
          st = e.statSync();
        } catch (_) {
          continue;
        }
        final isDir = e is Directory;
        if (widget.pickFolder && !isDir) continue;
        list.add(_Entry(e.path, name, isDir, isDir ? 0 : st.size, st.modified));
      }
    } catch (e) {
      err = 'ఈ ఫోల్డర్ తెరవలేకపోయాను';
    }
    _entries = list;
    _current = path;
    _error = err;
    _sort();
    if (mounted) setState(() => _loading = false);
  }

  void _sort() {
    _entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      if (_newestFirst) return b.modified.compareTo(a.modified);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  bool get _atRoot => _current == kRoot;

  void _goUp() {
    if (_atRoot) {
      Navigator.pop(context);
      return;
    }
    final i = _current.lastIndexOf('/');
    final parent = i <= 0 ? kRoot : _current.substring(0, i);
    _load(parent.length < kRoot.length ? kRoot : parent);
  }

  Future<void> _newFolder() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('కొత్త ఫోల్డర్ పేరు'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('వద్దు')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('సరే')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name.contains('/') || name == '..') {
      return;
    }
    try {
      Directory('$_current/$name').createSync(recursive: true);
    } catch (_) {}
    await _load(_current);
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  void _toggleAllHere() {
    final allSelected =
        _entries.isNotEmpty && _entries.every((e) => _selected.contains(e.path));
    setState(() {
      for (final e in _entries) {
        if (allSelected) {
          _selected.remove(e.path);
        } else {
          _selected.add(e.path);
        }
      }
    });
  }

  String _shortPath() {
    if (_current == kRoot) return 'ఫోన్ (అంతా)';
    return _current.substring(kRoot.length + 1);
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}-${two(d.month)}-${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  List<Widget> _chips() {
    final defs = <String, String>{
      'కెమెరా': '$kRoot/DCIM/Camera',
      'స్క్రీన్‌షాట్లు': '$kRoot/DCIM/Screenshots',
      'డౌన్‌లోడ్': '$kRoot/Download',
      'ఫోటోలు': '$kRoot/Pictures',
      'వీడియోలు': '$kRoot/Movies',
      'WhatsApp': '$kRoot/Android/media/com.whatsapp/WhatsApp/Media',
    };
    final out = <Widget>[];
    defs.forEach((label, p) {
      if (Directory(p).existsSync()) {
        out.add(Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(label: Text(label), onPressed: () => _load(p)),
        ));
      }
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final folders = _selected.where((p) => FileSystemEntity.isDirectorySync(p)).length;
    final files = _selected.length - folders;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          leading: IconButton(
              icon: const Icon(Icons.arrow_back), onPressed: _goUp),
          title: Text(_shortPath(), style: const TextStyle(fontSize: 17)),
          actions: [
            IconButton(
              tooltip: 'కొత్తవి ముందు / పేరు వరుస',
              icon: Icon(_newestFirst ? Icons.schedule : Icons.sort_by_alpha),
              onPressed: () {
                setState(() {
                  _newestFirst = !_newestFirst;
                  _sort();
                });
              },
            ),
            if (!widget.pickFolder)
              IconButton(
                tooltip: 'ఈ ఫోల్డర్‌లో అన్నీ',
                icon: const Icon(Icons.select_all),
                onPressed: _toggleAllHere,
              ),
            if (widget.pickFolder)
              IconButton(
                tooltip: 'కొత్త ఫోల్డర్',
                icon: const Icon(Icons.create_new_folder),
                onPressed: _newFolder,
              ),
          ],
        ),
        body: Column(
          children: [
            if (_atRoot || _chips().isNotEmpty)
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                          avatar: const Icon(Icons.phone_android, size: 18),
                          label: const Text('ఫోన్'),
                          onPressed: () => _load(kRoot)),
                    ),
                    ..._chips(),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!))
                      : _entries.isEmpty
                          ? const Center(child: Text('ఈ ఫోల్డర్ ఖాళీగా ఉంది'))
                          : ListView.builder(
                              itemCount: _entries.length,
                              itemBuilder: (ctx, i) {
                                final e = _entries[i];
                                final sel = _selected.contains(e.path);
                                return ListTile(
                                  leading: widget.pickFolder
                                      ? null
                                      : Checkbox(
                                          value: sel,
                                          onChanged: (_) => _toggle(e.path),
                                        ),
                                  title: Text(e.name,
                                      maxLines: 2, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(e.isDir
                                      ? 'ఫోల్డర్ • ${_fmtDate(e.modified)}'
                                      : '${fmtSize(e.size)} • ${_fmtDate(e.modified)}'),
                                  trailing: e.isDir
                                      ? const Icon(Icons.folder, color: Colors.amber, size: 30)
                                      : const Icon(Icons.insert_drive_file_outlined),
                                  selected: sel,
                                  onTap: () => e.isDir ? _load(e.path) : _toggle(e.path),
                                );
                              },
                            ),
            ),
            if (widget.pickFolder)
              Container(
                color: cs.surfaceContainerHighest,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('ఎంచుకునే ఫోల్డర్:\n${_shortPath()}',
                            style: const TextStyle(fontSize: 15)),
                      ),
                      FilledButton.icon(
                        onPressed: () => Navigator.pop(context, _current),
                        icon: const Icon(Icons.check),
                        label: const Text('ఈ ఫోల్డర్', style: TextStyle(fontSize: 18)),
                      ),
                    ],
                  ),
                ),
              )
            else
            Container(
              color: cs.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selected.isEmpty
                            ? 'ఏదీ ఎంచుకోలేదు\n(ఫోల్డర్ టిక్ చేస్తే మొత్తం వెళ్తుంది)'
                            : '$folders ఫోల్డర్లు, $files ఫైళ్లు ఎంచుకున్నారు',
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.pop(context, _selected.toList()),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('తరువాత', style: TextStyle(fontSize: 18)),
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
