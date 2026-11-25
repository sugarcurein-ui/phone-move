import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser.dart';
import 'net.dart';
import 'receive.dart';
import 'transfer.dart';

void main() => runApp(const PhoneMoveApp());

class PhoneMoveApp extends StatelessWidget {
  const PhoneMoveApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ఫోన్ మూవ్',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _hostCtl = TextEditingController();
  final TextEditingController _codeCtl = TextEditingController();
  int _port = 8765;
  String _status = '';
  bool _busy = false;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _hostCtl.dispose();
    _codeCtl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    _hostCtl.text = p.getString('host') ?? '';
    _port = p.getInt('port') ?? 8765;
    _codeCtl.text = p.getString('code') ?? '';
    if (!mounted) return;
    setState(() {});
    if (_hostCtl.text.isEmpty) {
      await _find();
    } else {
      await _test();
    }
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    final pc = _pc();
    await p.setString('host', pc.host);
    await p.setInt('port', pc.port);
    await p.setString('code', pc.code);
  }

  Pc _pc() {
    var host = _hostCtl.text.trim();
    var port = _port;
    if (host.contains(':')) {
      final parts = host.split(':');
      host = parts[0].trim();
      port = int.tryParse(parts[1].trim()) ?? port;
    }
    return Pc(host, port, _codeCtl.text.trim());
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _connected = false;
      _status = 'కంప్యూటర్ కోసం వెతుకుతున్నాను…';
    });
    final list = await discover();
    if (!mounted) return;
    if (list.isEmpty) {
      setState(() {
        _busy = false;
        _status = 'కంప్యూటర్ కనిపించలేదు.\n'
            '• కంప్యూటర్‌లో PhoneMove తెరిచి ఉందా?\n'
            '• ఫోన్, కంప్యూటర్ ఒకే WiFi లో ఉన్నాయా?\n'
            'లేదా కంప్యూటర్ స్క్రీన్‌పై ఉన్న చిరునామా కింద చేతితో రాయండి.';
      });
      return;
    }
    Map<String, dynamic> chosen = list.first;
    if (list.length > 1) {
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('ఏ కంప్యూటర్?'),
          children: [
            for (final m in list)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, m),
                child: Text('${m['name']}  (${m['ip']})',
                    style: const TextStyle(fontSize: 18)),
              ),
          ],
        ),
      );
      if (picked == null) {
        setState(() => _busy = false);
        return;
      }
      chosen = picked;
    }
    _hostCtl.text = chosen['ip'].toString();
    _port = (chosen['port'] as num?)?.toInt() ?? 8765;
    await _save();
    setState(() => _busy = false);
    await _test();
  }

  Future<void> _test() async {
    final pc = _pc();
    if (pc.host.isEmpty) {
      setState(() => _status = 'కంప్యూటర్ చిరునామా ఇవ్వండి');
      return;
    }
    setState(() {
      _busy = true;
      _connected = false;
      _status = 'కనెక్ట్ అవుతున్నాను…';
    });
    await _save();
    final api = Api(pc);
    final name = await api.hello();
    if (!mounted) return;
    if (name == null) {
      setState(() {
        _busy = false;
        _status = 'కంప్యూటర్‌కి కనెక్ట్ కాలేదు. కంప్యూటర్‌లో PhoneMove తెరిచి ఉందా? ఒకే WiFi లో ఉన్నారా?';
      });
      return;
    }
    if (pc.code.isEmpty) {
      setState(() {
        _busy = false;
        _status = 'కంప్యూటర్ "$name" దొరికింది. కంప్యూటర్ స్క్రీన్‌పై ఉన్న పాస్‌కోడ్ ఇవ్వండి.';
      });
      return;
    }
    try {
      await api.check([]);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _connected = true;
        _status = 'కనెక్ట్ అయింది ✔  ($name)';
      });
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '${e.message}. కంప్యూటర్‌లో ఉన్న 6 అంకెల పాస్‌కోడ్ మళ్లీ చూడండి.';
      });
    }
  }

  Future<bool> _ensureStorage() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    var s = await Permission.manageExternalStorage.request();
    if (s.isGranted) return true;
    s = await Permission.storage.request();
    if (s.isGranted || await Permission.manageExternalStorage.isGranted) {
      return true;
    }
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('అనుమతి కావాలి'),
        content: const Text(
            'ఫోన్‌లోని ఫైళ్లు చూడడానికి "అన్ని ఫైళ్లకు అనుమతి" ఇవ్వాలి. సెట్టింగ్స్ తెరిచి, ఫోన్ మూవ్ కి అనుమతి ఆన్ చేయండి.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('వద్దు')),
          FilledButton(
              onPressed: () {
                openAppSettings();
                Navigator.pop(ctx);
              },
              child: const Text('సెట్టింగ్స్ తెరువు')),
        ],
      ),
    );
    return false;
  }

  Future<void> _startSend() async {
    if (!_connected) {
      await _test();
      if (!_connected) return;
    }
    if (!await _ensureStorage()) return;
    if (!mounted) return;
    final picked = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const BrowserScreen()),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => TransferScreen(pc: _pc(), paths: picked)),
    );
  }

  Future<void> _startReceive() async {
    if (!_connected) {
      await _test();
      if (!_connected) return;
    }
    if (!await _ensureStorage()) return;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => ReceiveScreen(pc: _pc())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ఫోన్ మూవ్'),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_connected ? Icons.check_circle : Icons.computer,
                          color: _connected ? Colors.green : Colors.grey,
                          size: 30),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text('కంప్యూటర్',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                      ),
                      if (_busy)
                        const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 3)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_status, style: const TextStyle(fontSize: 16)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _hostCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'కంప్యూటర్ చిరునామా (ఉదా: 192.168.1.5)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _codeCtl,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'పాస్‌కోడ్ (కంప్యూటర్ స్క్రీన్‌పై ఉంటుంది)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _find,
                          icon: const Icon(Icons.search),
                          label: const Text('కంప్యూటర్ వెతుకు'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _test,
                          icon: const Icon(Icons.link),
                          label: const Text('కనెక్ట్ చేయి'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 76,
            child: FilledButton.icon(
              onPressed: _busy ? null : _startSend,
              icon: const Icon(Icons.upload_file, size: 32),
              label: const Text('ఫైళ్లు / ఫోల్డర్లు ఎంచుకుని పంపండి',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 76,
            child: FilledButton.tonalIcon(
              onPressed: _busy ? null : _startReceive,
              icon: const Icon(Icons.download, size: 32),
              label: const Text('కంప్యూటర్ నుండి ఫోన్‌కి తీసుకోండి',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'గమనిక: పంపేటప్పుడు యాప్ తెరిచి ఉంచండి. మధ్యలో ఆగిపోతే మళ్లీ పంపండి నొక్కితే మిగిలినవే వెళ్తాయి. ఇప్పటికే కంప్యూటర్‌లో ఉన్న ఫైళ్లు మళ్లీ వెళ్లవు, ఏదీ చెరిగిపోదు.',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
