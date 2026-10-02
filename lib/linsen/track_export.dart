// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:io';
import 'package:path/path.dart' as p;
import 'tuneweave_api.dart';

/// Uses the provider's download authorization, including cross-platform routing.
class TrackExporter {
  final _destinations = <String>{};

  Future<File?> export({
    required TuneWeaveApi api,
    required int generation,
    required String reference,
    required bool cloud,
    required String preferredPlatform,
    required Directory directory,
    required String title,
    required Future<bool> Function() confirmOverwrite,
  }) async {
    void checkSession() {
      if (generation != api.generation) {
        throw const TuneWeaveException('cancelled', '账号或服务已切换，下载已取消');
      }
    }

    checkSession();
    final encoded = Uri.encodeComponent(reference);
    final raw = await api.data(
      'GET',
      cloud
          ? '/v1/account/cloud/tracks/$encoded/download'
          : '/v1/tracks/$encoded/download',
      query: cloud
          ? {}
          : {
              'quality': 'auto',
              'fallback': true,
              'unblock': true,
              if (preferredPlatform != 'auto')
                'playback_platform': preferredPlatform,
            },
    );
    checkSession();
    final data = Map<String, dynamic>.from(raw as Map);
    final url = data['url'];
    if (data['available'] != true || url is! String) {
      throw const TuneWeaveException('unavailable', '当前音源未授权完整下载');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const TuneWeaveException('upstream_error', '无效下载地址');
    }
    final format = data['format'];
    final extension =
        format is String && RegExp(r'^[a-z0-9]{1,8}$').hasMatch(format)
        ? format
        : 'audio';
    var name = title
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
        .replaceFirst(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) name = 'song';
    if (RegExp(
      r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name)) {
      name = '_$name';
    }
    final destination = File(p.join(directory.path, '$name.$extension'));
    final normalized = p.normalize(p.absolute(destination.path));
    final lock = Platform.isWindows ? normalized.toLowerCase() : normalized;
    if (!_destinations.add(lock)) {
      throw const TuneWeaveException('conflict', '该文件正在下载，请等待完成');
    }
    Directory? working;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final previous = await destination.stat();
      if (previous.type != FileSystemEntityType.notFound &&
          previous.type != FileSystemEntityType.file) {
        throw const TuneWeaveException('conflict', '目标路径不是文件，请选择其他名称或目录');
      }
      if (previous.type != FileSystemEntityType.notFound &&
          !await confirmOverwrite()) {
        return null;
      }
      checkSession();
      working = await directory.createTemp('.linsen-download-');
      final partial = File(p.join(working.path, 'audio.part'));
      final request = await http.getUrl(uri);
      checkSession();
      request.followRedirects = false;
      for (final header in (data['headers'] as Map? ?? {}).entries) {
        request.headers.set('${header.key}', '${header.value}');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw TuneWeaveException(
          'upstream_error',
          '下载失败：${response.statusCode}',
        );
      }
      final sink = partial.openWrite();
      var bytes = 0;
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          checkSession();
          bytes += chunk.length;
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      checkSession();
      final expected = data['size'];
      if (bytes == 0 ||
          (response.compressionState !=
                  HttpClientResponseCompressionState.decompressed &&
              response.contentLength >= 0 &&
              bytes != response.contentLength) ||
          (expected is num && expected > 0 && bytes != expected)) {
        throw const TuneWeaveException('upstream_error', '下载内容不完整，请重试');
      }
      final current = await destination.stat();
      if (current.type != previous.type ||
          current.size != previous.size ||
          current.modified != previous.modified) {
        throw const TuneWeaveException('conflict', '目标文件已变化，请重新确认保存');
      }
      checkSession();
      // Windows rename cannot replace an open/existing destination. Preserve the
      // old file until the complete transfer can be moved into its place.
      File? backup;
      try {
        if (current.type != FileSystemEntityType.notFound) {
          backup = await destination.rename(p.join(working.path, 'previous'));
        }
        checkSession();
        await partial.rename(destination.path);
      } catch (_) {
        if (backup != null && !await destination.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
      return destination;
    } finally {
      http.close(force: true);
      _destinations.remove(lock);
      if (working != null && await working.exists()) {
        // If restoration failed, keep the previous user file for recovery.
        if (!await File(p.join(working.path, 'previous')).exists() ||
            await destination.exists()) {
          await working.delete(recursive: true);
        }
      }
    }
  }
}
