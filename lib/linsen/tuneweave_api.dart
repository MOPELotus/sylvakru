// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TuneWeaveException implements Exception {
  final String code;
  final String message;
  final Map<String, dynamic> details;
  const TuneWeaveException(this.code, this.message, [this.details = const {}]);
  bool get transient => const {
    'transport_error',
    'rate_limited',
    'upstream_error',
    'conflict',
    'authentication_required',
    'cancelled',
  }.contains(code);
  @override
  String toString() => message;
}

class TuneWeaveApi {
  Uri endpoint;
  String? runtimeToken;
  final Map<String, String> credentials = {};
  final Future<void> Function(String platform, String? value)? saveCredential;
  final Set<HttpClientRequest> _active = {};
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  int generation = 0;

  TuneWeaveApi(this.endpoint, {this.runtimeToken, this.saveCredential});

  void invalidate() {
    generation++;
    for (final request in _active.toList()) {
      request.abort(const TuneWeaveException('cancelled', '账户或服务已切换'));
    }
    _active.clear();
  }

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, dynamic> query = const {},
    Object? body,
    bool authenticated = true,
    Duration timeout = const Duration(seconds: 130),
  }) async {
    if (!path.startsWith('/v1/') && path != '/healthz') {
      throw const TuneWeaveException('invalid_request', '不支持的接口路径');
    }
    final epoch = generation;
    final sent = Map<String, String>.from(credentials);
    final uri = endpoint.replace(
      path: '${endpoint.path.replaceFirst(RegExp(r'/+$'), '')}$path',
      queryParameters: query.isEmpty
          ? null
          : query.map((k, v) => MapEntry(k, '$v')),
    );
    HttpClientRequest? outgoing;
    try {
      outgoing = await _http.openUrl(method, uri).timeout(timeout);
      if (generation != epoch) {
        outgoing.abort();
        throw const TuneWeaveException('cancelled', '请求已取消');
      }
      _active.add(outgoing);
      outgoing.followRedirects = false;
      outgoing.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (runtimeToken != null) {
        outgoing.headers.set('X-Linsen-Runtime-Token', runtimeToken!);
      }
      if (authenticated) {
        outgoing.headers.noFolding('X-TuneWeave-Credential');
        final selected = query['platform'];
        for (final entry in sent.entries) {
          if (selected == null || selected == 'all' || selected == entry.key) {
            outgoing.headers.add('X-TuneWeave-Credential', entry.value);
          }
        }
      }
      if (body != null) {
        outgoing.headers.contentType = ContentType.json;
        outgoing.add(utf8.encode(jsonEncode(body)));
      }
      final response = await outgoing.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > 16 * 1024 * 1024) {
          outgoing.abort();
          throw const TuneWeaveException('invalid_response', '响应超过大小限制');
        }
        bytes.addAll(chunk);
      }
      if (epoch != generation) {
        throw const TuneWeaveException('cancelled', '请求已取消');
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const TuneWeaveException('invalid_response', '服务返回了无效数据');
      }
      // Accept credential rotations on errors as well as successful responses.
      final updates = <String, String>{};
      void collect(dynamic value) {
        if (value is Map &&
            value['platform'] is String &&
            value['value'] is String) {
          updates[value['platform'] as String] = value['value'] as String;
        }
      }

      collect((decoded['meta'] as Map?)?['caller_credential']);
      collect((decoded['data'] as Map?)?['caller_credential']);
      collect(
        ((decoded['data'] as Map?)?['auth'] as Map?)?['caller_credential'],
      );
      for (final header
          in response.headers['x-tuneweave-updated-credential'] ?? <String>[]) {
        for (final part in header.split(',')) {
          final separator = part.indexOf('=');
          if (separator > 0) {
            updates[part.substring(0, separator).trim()] = part
                .substring(separator + 1)
                .trim();
          }
        }
      }
      for (final entry in updates.entries) {
        if (epoch != generation) break;
        if (!authenticated || credentials[entry.key] == sent[entry.key]) {
          credentials[entry.key] = entry.value;
          await saveCredential?.call(entry.key, entry.value);
        }
      }
      if (epoch != generation) {
        throw const TuneWeaveException('cancelled', '请求已取消');
      }
      if (decoded['ok'] != true) {
        final error = Map<String, dynamic>.from(decoded['error'] as Map? ?? {});
        final code = error['code'] as String? ?? 'upstream_error';
        if (code == 'authentication_required' || code == 'conflict') {
          final platform =
              error['platform'] as String? ?? query['platform'] as String?;
          if (platform != null && credentials[platform] == sent[platform]) {
            credentials.remove(platform);
            await saveCredential?.call(platform, null);
          }
        }
        throw TuneWeaveException(
          code,
          error['message'] as String? ?? '请求失败',
          Map<String, dynamic>.from(error['details'] as Map? ?? {}),
        );
      }
      return decoded;
    } on TuneWeaveException {
      rethrow;
    } catch (_) {
      if (epoch != generation) {
        throw const TuneWeaveException('cancelled', '请求已取消');
      }
      throw const TuneWeaveException('transport_error', '暂时无法连接音乐服务');
    } finally {
      if (outgoing != null) _active.remove(outgoing);
    }
  }

  Future<dynamic> data(
    String method,
    String path, {
    Map<String, dynamic> query = const {},
    Object? body,
    bool authenticated = true,
  }) async => (await request(
    method,
    path,
    query: query,
    body: body,
    authenticated: authenticated,
  ))['data'];

  void close() {
    invalidate();
    _http.close(force: true);
  }
}
