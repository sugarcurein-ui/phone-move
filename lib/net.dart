import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

class CancelledError implements Exception {}

class Pc {
  final String host;
  final int port;
  final String code;
  const Pc(this.host, this.port, this.code);
  String get base => 'http://$host:$port';
}

String fmtSize(num n) {
  const k = 1024.0;
  if (n >= k * k * k) return '${(n / (k * k * k)).toStringAsFixed(2)} GB';
  if (n >= k * k) return '${(n / (k * k)).toStringAsFixed(1)} MB';
  if (n >= k) return '${(n / k).toStringAsFixed(0)} KB';
  return '${n.toInt()} B';
}

/// Find computers running the receiver on the same WiFi / hotspot.
Future<List<Map<String, dynamic>>> discover() async {
  final found = <String, Map<String, dynamic>>{};
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    final s = sock;
    s.listen((event) {
      if (event == RawSocketEvent.read) {
        final d = s.receive();
        if (d == null) return;
        final text = utf8.decode(d.data, allowMalformed: true);
        if (text.startsWith('PHONEMOVE!')) {
          try {
            final m = jsonDecode(text.substring(10)) as Map<String, dynamic>;
            m['ip'] = d.address.address;
            found[d.address.address] = m;
          } catch (_) {}
        }
      }
    });

    // directed broadcast addresses of all our networks + global broadcast
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final ifs = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final ni in ifs) {
        for (final a in ni.addresses) {
          final p = a.address.split('.');
          if (p.length == 4) {
            targets.add(InternetAddress('${p[0]}.${p[1]}.${p[2]}.255'));
          }
        }
      }
    } catch (_) {}

    final msg = utf8.encode('PHONEMOVE?');
    for (var i = 0; i < 4; i++) {
      for (final t in targets) {
        try {
          s.send(msg, t, 8766);
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    await Future.delayed(const Duration(milliseconds: 800));
  } catch (_) {
    // ignore, return what we have
  } finally {
    sock?.close();
  }
  return found.values.toList();
}

class Api {
  final Pc pc;
  Api(this.pc);

  HttpClient _client() {
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 8);
    c.idleTimeout = const Duration(seconds: 5);
    return c;
  }

  /// Returns the computer name if reachable.
  Future<String?> hello() async {
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse('${pc.base}/api/hello'));
      final resp = await req.close().timeout(const Duration(seconds: 6));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final m = jsonDecode(body) as Map<String, dynamic>;
      if (m['app'] != 'phonemove') return null;
      return (m['name'] ?? 'PC').toString();
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  /// Asks the computer which files are new / partial / already done.
  Future<List<Map<String, dynamic>>> check(
      List<Map<String, dynamic>> files) async {
    final c = _client();
    try {
      final req = await c.postUrl(Uri.parse('${pc.base}/api/check'));
      req.headers.set('X-Code', pc.code);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'root': '', 'files': files})));
      final resp = await req.close().timeout(const Duration(seconds: 90));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 401) throw ApiError('పాస్‌కోడ్ తప్పు');
      if (resp.statusCode != 200) {
        throw ApiError('కంప్యూటర్ నుండి లోపం (${resp.statusCode})');
      }
      final m = jsonDecode(body) as Map<String, dynamic>;
      return (m['results'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError('కంప్యూటర్‌తో కనెక్ట్ కాలేదు');
    } finally {
      c.close(force: true);
    }
  }

  /// Streams file bytes from [offset]. [onBytes] is called with chunk sizes.
  /// [isCancelled] is polled for every chunk.
  Future<void> upload({
    required String filePath,
    required String saveAs,
    required int size,
    required int offset,
    required int mtimeSec,
    required void Function(int) onBytes,
    required bool Function() isCancelled,
  }) async {
    final c = _client();
    try {
      final uri = Uri.parse('${pc.base}/api/upload').replace(queryParameters: {
        'saveAs': saveAs,
        'size': '$size',
        'offset': '$offset',
        'mtime': '$mtimeSec',
      });
      final req = await c.openUrl('PUT', uri);
      req.headers.set('X-Code', pc.code);
      req.headers.contentType = ContentType.binary;
      req.contentLength = size - offset;
      req.bufferOutput = false;
      final stream = File(filePath).openRead(offset).map((chunk) {
        if (isCancelled()) throw CancelledError();
        onBytes(chunk.length);
        return chunk;
      });
      await req.addStream(stream);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 401) throw ApiError('పాస్‌కోడ్ తప్పు');
      if (resp.statusCode != 200) {
        throw ApiError('విఫలం (${resp.statusCode}) $body');
      }
    } finally {
      c.close(force: true);
    }
  }

  /// Files in the computer's outbox (for computer -> phone).
  Future<List<Map<String, dynamic>>> list() async {
    final c = _client();
    try {
      final req = await c.getUrl(Uri.parse('${pc.base}/api/list'));
      req.headers.set('X-Code', pc.code);
      final resp = await req.close().timeout(const Duration(seconds: 60));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 401) throw ApiError('పాస్‌కోడ్ తప్పు');
      if (resp.statusCode != 200) {
        throw ApiError('కంప్యూటర్ నుండి లోపం (${resp.statusCode})');
      }
      final m = jsonDecode(body) as Map<String, dynamic>;
      return (m['files'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } on ApiError {
      rethrow;
    } catch (e) {
      throw ApiError('కంప్యూటర్‌తో కనెక్ట్ కాలేదు');
    } finally {
      c.close(force: true);
    }
  }

  /// Downloads [rel] from the computer into [partPath], resuming from the
  /// bytes already in that file. Returns when the file is complete
  /// (length == size). [onBytes] gets every chunk size; if the server restarts
  /// from zero, [onReset] is called.
  Future<void> download({
    required String rel,
    required String partPath,
    required int size,
    required void Function(int) onBytes,
    required void Function() onReset,
    required bool Function() isCancelled,
  }) async {
    final c = _client();
    IOSink? sink;
    try {
      final part = File(partPath);
      var offset = part.existsSync() ? part.lengthSync() : 0;
      if (offset > size) {
        part.deleteSync();
        offset = 0;
        onReset();
      }
      if (offset == size && size > 0) return;
      final uri = Uri.parse('${pc.base}/api/download')
          .replace(queryParameters: {'path': rel});
      final req = await c.getUrl(uri);
      req.headers.set('X-Code', pc.code);
      if (offset > 0) req.headers.set('Range', 'bytes=$offset-');
      final resp = await req.close();
      if (resp.statusCode == 401) throw ApiError('పాస్‌కోడ్ తప్పు');
      if (resp.statusCode == 416) {
        // our partial file does not fit; start again
        await resp.drain<void>();
        if (part.existsSync()) part.deleteSync();
        onReset();
        throw ApiError('మళ్లీ మొదటి నుండి తీసుకుంటాను');
      }
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        await resp.drain<void>();
        throw ApiError('విఫలం (${resp.statusCode})');
      }
      var mode = FileMode.append;
      if (resp.statusCode == 200 && offset > 0) {
        // server ignored Range: restart from zero
        mode = FileMode.write;
        onReset();
      }
      part.parent.createSync(recursive: true);
      sink = part.openWrite(mode: mode);
      await for (final chunk in resp) {
        if (isCancelled()) throw CancelledError();
        sink.add(chunk);
        onBytes(chunk.length);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final got = part.lengthSync();
      if (got != size) {
        throw ApiError('ఫైల్ అసంపూర్ణం ($got / $size)');
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      c.close(force: true);
    }
  }
}
