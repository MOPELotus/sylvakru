// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'tuneweave_api.dart';

/// Resume belongs to this live transfer only; publication is never blindly retried.
class CloudUpload extends ChangeNotifier {
  final TuneWeaveApi api;
  final File file;
  final int generation;
  Map<String, dynamic>? transfer;
  Map<String, dynamic>? receipt;
  HttpClient? _storage;
  bool cancelled = false, running = false, published = false, uncertain = false;
  String? error;
  int get offset => (transfer?['offset'] as num?)?.toInt() ?? 0;
  int get size => (transfer?['file_size'] as num?)?.toInt() ?? 0;
  String get path =>
      '/v1/account/cloud/uploads/transfers/${transfer!['transfer_id']}';
  CloudUpload(this.api, this.file) : generation = api.generation;
  void _check() {
    if (cancelled || generation != api.generation) {
      throw const TuneWeaveException('cancelled', '上传已取消，或账号与服务已切换');
    }
  }

  Future<void> run() async {
    if (running || cancelled || published || uncertain) return;
    running = true;
    error = null;
    notifyListeners();
    try {
      _check();
      if (transfer == null) {
        final digest = await md5.bind(file.openRead()).first;
        _check();
        transfer = Map<String, dynamic>.from(
          await api.data(
                'POST',
                '/v1/account/cloud/uploads/transfers',
                query: {'platform': 'netease'},
                body: {
                  'file': {
                    'md5': '$digest',
                    'file_size': await file.length(),
                    'filename': p.basename(file.path),
                  },
                  'strategy': 'auto',
                },
              )
              as Map,
        );
      } else {
        transfer = Map<String, dynamic>.from(
          await api.data('GET', path, query: {'platform': 'netease'}) as Map,
        );
      }
      while (transfer!['state'] == 'transferring') {
        _check();
        final step = Map<String, dynamic>.from(transfer!['step'] as Map);
        final delay = (step['retry_delay_ms'] as num?)?.toInt() ?? 0;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        _check();
        // If an advance reply was lost, reuse the receipt only for the same step.
        if (receipt?['step_id'] != step['step_id']) {
          receipt = await _execute(step);
        }
        _check();
        transfer = Map<String, dynamic>.from(
          await api.data(
                'POST',
                '$path/advance',
                query: {'platform': 'netease'},
                body: receipt,
              )
              as Map,
        );
        receipt = null;
        notifyListeners();
      }
      _check();
      if (transfer!['state'] != 'ready_to_publish') {
        throw const TuneWeaveException('invalid_response', '云盘传输未就绪');
      }
      // A lost publish reply must be reviewed against the cloud list by the user.
      uncertain = true;
      await api.data(
        'POST',
        '$path/complete',
        query: {'platform': 'netease'},
        body: <String, dynamic>{},
      );
      uncertain = false;
      published = true;
    } catch (exception) {
      error = '$exception';
    } finally {
      running = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _execute(Map<String, dynamic> step) async {
    final uri = Uri.parse(step['url'] as String);
    if (!const {'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const TuneWeaveException('invalid_response', '无效存储地址');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _storage = client;
    try {
      final request = await client.openUrl(step['method'] as String, uri);
      request.followRedirects = false;
      for (final header in (step['headers'] as Map? ?? {}).entries) {
        request.headers.set('${header.key}', '${header.value}');
      }
      if (step['kind'] == 'upload') {
        final start = (step['offset'] as num).toInt(),
            length = (step['length'] as num).toInt();
        if (start < 0 || length < 0 || start + length > await file.length()) {
          throw const TuneWeaveException('invalid_response', '无效上传范围');
        }
        request.contentLength = length;
        await request
            .addStream(file.openRead(start, start + length))
            .timeout(const Duration(minutes: 2));
      }
      final response = await request.close().timeout(
        const Duration(minutes: 2),
      );
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        if (bytes.length + chunk.length > 64 * 1024) {
          throw const TuneWeaveException('invalid_response', '存储回执过大');
        }
        bytes.addAll(chunk);
      }
      final headers = <String, String>{};
      response.headers.forEach((key, values) {
        headers[key] = values.join(',');
      });
      return {
        'step_id': step['step_id'],
        'status': response.statusCode,
        'headers': headers,
        'body': utf8.decode(bytes, allowMalformed: true),
      };
    } catch (_) {
      // Let TuneWeave choose probing/recovery; never replay storage writes ourselves.
      return {
        'step_id': step['step_id'],
        'status': null,
        'headers': <String, String>{},
        'body': '',
      };
    } finally {
      client.close(force: true);
      if (_storage == client) _storage = null;
    }
  }

  Future<void> cancel() async {
    cancelled = true;
    _storage?.close(force: true);
    notifyListeners();
    if (transfer != null &&
        !published &&
        !uncertain &&
        generation == api.generation) {
      try {
        await api.data('DELETE', path, query: {'platform': 'netease'});
      } catch (_) {
        /* Local cancellation still prevents publication. */
      }
    }
  }
}
