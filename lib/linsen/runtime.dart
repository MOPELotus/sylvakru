// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

String nativeLibraryPath() {
  if (Platform.isAndroid) return 'liblinsen_tuneweave.so';
  final name = Platform.isWindows
      ? 'linsen_tuneweave.dll'
      : 'liblinsen_tuneweave.so';
  final override = Platform.environment['LINSEN_RUNTIME_LIBRARY'];
  if (override != null) return override;
  return p.join(
    p.dirname(Platform.resolvedExecutable),
    Platform.isWindows ? '' : 'lib',
    name,
  );
}

Map<String, dynamic> _startNative(String directory) {
  final library = DynamicLibrary.open(nativeLibraryPath());
  final start = library
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)
      >('linsen_runtime_start');
  final release = library
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('linsen_runtime_free');
  final argument = directory.toNativeUtf8();
  try {
    final result = start(argument);
    try {
      return Map<String, dynamic>.from(
        jsonDecode(result.toDartString()) as Map,
      );
    } finally {
      release(result);
    }
  } finally {
    calloc.free(argument);
  }
}

class TuneWeaveRuntime {
  static bool running = false;
  static Future<Map<String, dynamic>> start(String directory) async {
    final result = await Isolate.run(() => _startNative(directory));
    if (result['error'] != null) throw StateError(result['error'] as String);
    running = true;
    return result;
  }

  static Future<void> stop() async {
    if (!running) return;
    await Isolate.run(() {
      DynamicLibrary.open(
        nativeLibraryPath(),
      ).lookupFunction<Void Function(), void Function()>(
        'linsen_runtime_stop',
      )();
    });
    running = false;
  }
}
