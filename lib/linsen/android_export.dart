// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'tuneweave_api.dart';

class AndroidDocumentExporter {
  static const _channel = MethodChannel('com.mopelotus.linsen/export');
  final Future<Object?> Function(String, Map<String, Object?>) invoke;
  AndroidDocumentExporter({
    Future<Object?> Function(String, Map<String, Object?>)? transport,
  }) : invoke =
           transport ??
           ((method, arguments) =>
               _channel.invokeMethod<Object?>(method, arguments));

  Future<bool> save(
    File recording, {
    required bool Function() validSession,
  }) async {
    if (!validSession()) throw const TuneWeaveException('cancelled', '下载已取消');
    final extension = p.extension(recording.path).toLowerCase();
    final uri = await invoke('pickSave', {
      'fileName': p.basename(recording.path),
      'mimeType': switch (extension) {
        '.mp3' => 'audio/mpeg',
        '.flac' => 'audio/flac',
        '.ogg' => 'audio/ogg',
        '.wav' => 'audio/wav',
        '.m4a' => 'audio/mp4',
        _ => 'application/octet-stream',
      },
    });
    if (uri == null) return false;
    if (uri is! String || Uri.tryParse(uri)?.scheme != 'content') {
      throw const TuneWeaveException('invalid_response', '无效保存位置');
    }
    if (!validSession()) {
      await invoke('discardUri', {'uri': uri});
      throw const TuneWeaveException('cancelled', '账号或服务已切换，下载已取消');
    }
    await invoke('copyToUri', {'sourcePath': recording.path, 'uri': uri});
    return true;
  }
}
