// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
part of 'workspace.dart';

extension _WorkspaceAuth on _LinsenWorkspaceState {
  Future<void> qrLogin(String selected) async {
    try {
      await linsen.prepareLogin(selected);
      final api = linsen.service;
      final result = await api.data(
        'POST',
        '/v1/auth/qr',
        authenticated: false,
        body: {'platform': selected, 'credential_mode': 'client'},
      );
      if (!mounted) return;
      final transaction = result['transaction_id'] as String;
      final source = result['image_data_url'] as String?;
      final image = source != null && source.contains(',')
          ? base64Decode(source.split(',').last)
          : null;
      String status = '使用该平台官方应用扫码并确认登录';
      bool active = true;
      void Function(void Function())? refresh;
      Future<void> poll() async {
        while (active) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (!active) break;
          try {
            final value = await api.data(
              'GET',
              '/v1/auth/qr/${Uri.encodeComponent(transaction)}',
              authenticated: false,
            );
            if (!active) break;
            if (value['state'] == 'confirmed') {
              await linsen.completeLogin(selected);
              status = '已登录';
              active = false;
            } else if (value['state'] == 'expired' ||
                value['state'] == 'failed') {
              status = value['message'] as String? ?? '二维码已失效，请重新生成';
              active = false;
            } else {
              status =
                  value['message'] as String? ??
                  (value['state'] == 'scanned' ? '已扫码，请在官方应用确认' : '等待扫码');
            }
            refresh?.call(() {});
          } catch (e) {
            if (active) {
              status = '$e';
              active = false;
              refresh?.call(() {});
            }
          }
        }
      }

      unawaited(poll());
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) {
            refresh = update;
            return AlertDialog(
              title: Text('${platformNames[selected]}扫码登录'),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (image != null)
                      Image.memory(image, width: 240, height: 240),
                    if (image == null) SelectableText(result['url'] as String),
                    const SizedBox(height: 12),
                    Text(status),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          },
        ),
      );
      active = false;
      refresh = null;
    } catch (e) {
      showError(e);
    }
  }

  Future<void> passwordLogin(String selected) async {
    final principal = TextEditingController(),
        password = TextEditingController();
    String kind = 'phone';
    bool busy = false;
    String? status;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('${platformNames[selected]}密码登录'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  items: const [
                    DropdownMenuItem(value: 'phone', child: Text('手机号')),
                    DropdownMenuItem(value: 'email', child: Text('邮箱')),
                    DropdownMenuItem(value: 'username', child: Text('用户名')),
                  ],
                  onChanged: (value) => update(() {
                    kind = value!;
                  }),
                ),
                TextField(
                  controller: principal,
                  decoration: const InputDecoration(labelText: '账号'),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
                if (status != null) Text(status!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      update(() {
                        busy = true;
                        status = null;
                      });
                      try {
                        await linsen.prepareLogin(selected);
                        final result = await linsen.service.data(
                          'POST',
                          '/v1/auth/password',
                          authenticated: false,
                          body: {
                            'platform': selected,
                            'credential_mode': 'client',
                            'principal_type': kind,
                            'principal': principal.text.trim(),
                            'password': password.text,
                            'password_format': 'plain',
                            if (kind == 'phone') 'country_code': '86',
                          },
                        );
                        if (result['caller_credential'] != null) {
                          await linsen.completeLogin(selected);
                          if (context.mounted) Navigator.pop(context);
                        } else {
                          status = '平台要求进一步验证，可使用扫码或导入 Cookie 登录';
                        }
                      } catch (e) {
                        status = '$e';
                      } finally {
                        if (context.mounted) {
                          update(() {
                            busy = false;
                          });
                        }
                      }
                    },
              child: const Text('登录'),
            ),
          ],
        ),
      ),
    );
    principal.dispose();
    password.dispose();
  }
}
