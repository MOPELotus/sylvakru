// Modified 2026 MOPELotus: persist the listening outbox before bounded runtime shutdown.
import 'package:sylvakru/linsen/controller.dart';
import 'package:sylvakru/linsen/runtime.dart';
import 'dart:io';

import 'package:sylvakru/base/services/single_instance.dart';
import 'package:window_manager/window_manager.dart';

bool _exited = false;

void exitApp() async {
  if (_exited) {
    return;
  }

  _exited = true;
  try {
    await linsen.outbox.finish();
    await linsen.persist();
  } catch (_) {}
  linsen.api?.close();
  await TuneWeaveRuntime.stop();
  await SingleInstance.end();
  // only this allows quick exit on Windows
  if (Platform.isWindows) {
    await windowManager.setPreventClose(false);
    _exited = true;
    windowManager.close();
    return;
  }

  exit(0);
}
