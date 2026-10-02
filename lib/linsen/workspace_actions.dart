// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
part of 'workspace.dart';

extension _WorkspaceActions on _LinsenWorkspaceState {
  Future<bool> confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ??
      false;
  Future<String?> askText(String title, {String value = ''}) async {
    final text = TextEditingController(text: value);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: text, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    text.dispose();
    return result;
  }

  Future<void> createPlaylist() async {
    final name = await askText('新建平台歌单');
    if (name == null || name.isEmpty) return;
    try {
      await linsen.service.data(
        'POST',
        '/v1/playlists',
        body: {
          'platform': platform == 'all' || platform == 'local'
              ? 'netease'
              : platform,
          'name': name,
        },
      );
      await load();
    } catch (e) {
      showError(e);
    }
  }

  Future<void> uploadCloud() async {
    final result = await FilePicker.pickFiles(type: FileType.audio);
    final path = result.isEmpty ? null : result.single.path;
    if (path == null || !mounted) return;
    final task = CloudUpload(linsen.service, File(path));
    unawaited(task.run());
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: task,
        builder: (_, _) => AlertDialog(
          title: const Text('上传网易云云盘'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(p.basename(path)),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: task.size == 0 ? null : task.offset / task.size,
              ),
              Text(
                task.published
                    ? '上传完成'
                    : task.uncertain
                    ? '发布结果不确定，请检查云盘列表'
                    : '${task.offset} / ${task.size} 字节',
              ),
              if (task.error != null) Text(task.error!),
            ],
          ),
          actions: [
            if (!task.running &&
                !task.published &&
                !task.uncertain &&
                !task.cancelled)
              TextButton(onPressed: task.run, child: const Text('继续当前传输')),
            TextButton(
              onPressed: () async {
                if (!task.published && !task.uncertain) await task.cancel();
                if (context.mounted) Navigator.pop(context);
              },
              child: Text(task.published || task.uncertain ? '关闭' : '取消上传'),
            ),
          ],
        ),
      ),
    );
    if (mounted) load();
  }

  Future<void> rowAction(String action, Map<String, dynamic> row) async {
    final reference = row['ref'] as String?;
    if (reference == null) return;
    final encoded = Uri.encodeComponent(reference);
    try {
      switch (action) {
        case 'favorite':
          await linsen.service.data(
            'PUT',
            '/v1/account/favorites/tracks/$encoded',
          );
        case 'unfavorite':
          if (await confirm('取消收藏这首歌？')) {
            await linsen.service.data(
              'DELETE',
              '/v1/account/favorites/tracks/$encoded',
            );
          }
        case 'deleteCloud':
          if (await confirm('从网易云云盘删除这首歌？此操作会同步到平台账号。')) {
            await linsen.service.data(
              'DELETE',
              '/v1/account/cloud/tracks',
              body: {
                'platform': 'netease',
                'refs': [reference],
              },
            );
            await load();
          }
        case 'rename':
          final name = await askText(
            '重命名歌单',
            value: row['name'] as String? ?? '',
          );
          if (name != null && name.isNotEmpty) {
            await linsen.service.data(
              'PATCH',
              '/v1/playlists/$encoded',
              body: {'name': name},
            );
            await load();
          }
        case 'deletePlaylist':
          if (await confirm('删除这个平台歌单？此操作会同步到平台账号。')) {
            await linsen.service.data('DELETE', '/v1/playlists/$encoded');
            await load();
          }
        case 'removeTrack':
          if (playlistRef != null && await confirm('从当前平台歌单移除这首歌？')) {
            await linsen.service.data(
              'DELETE',
              '/v1/playlists/${Uri.encodeComponent(playlistRef!)}/tracks',
              body: {
                'refs': [reference],
              },
            );
            await load();
          }
        case 'addToPlaylist':
          final data = await linsen.service.data(
            'GET',
            '/v1/account/playlists',
            query: {'platform': reference.split(':').first, 'limit': 100},
          );
          final items = data is List ? data : data['items'] as List;
          if (!mounted) return;
          final target = await showDialog<String>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('添加到平台歌单'),
              children: items
                  .map<Widget>(
                    (item) => SimpleDialogOption(
                      onPressed: () =>
                          Navigator.pop(context, item['ref'] as String),
                      child: Text(item['name'] as String),
                    ),
                  )
                  .toList(),
            ),
          );
          if (target != null) {
            await linsen.service.data(
              'POST',
              '/v1/playlists/${Uri.encodeComponent(target)}/tracks',
              body: {
                'refs': [reference],
              },
            );
          }
        case 'download':
          await download(row);
      }
    } catch (e) {
      showError(e);
    }
  }

  Future<void> download(Map<String, dynamic> row) async {
    final api = linsen.service;
    final generation = api.generation;
    final preferredPlatform = linsen.playbackPlatform;
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '保存到');
    if (dir == null) return;
    final result = await _exporter.export(
      api: api,
      generation: generation,
      reference: row['ref'] as String,
      cloud: row['cloud'] == true,
      preferredPlatform: preferredPlatform,
      directory: Directory(dir),
      title: row['name'] as String? ?? 'song',
      confirmOverwrite: () => confirm('目标文件已存在，要覆盖吗？'),
    );
    if (result == null) return;
    if (mounted) {
      showCenterMessage('下载完成');
    }
  }
}
