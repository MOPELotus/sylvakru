// Copyright 2026 MOPELotus. Linsen additions, Apache-2.0.
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'cloud_upload.dart';
import 'track_export.dart';
import 'android_export.dart';
import '../base/app.dart' show appSupportDir;
import 'package:material_ui/material_ui.dart';
import '../base/audio_handler.dart';
import '../base/data/library.dart';
import '../base/widgets/manage_music_folders.dart';
import '../base/services/interaction.dart';
import '../base/utils/media_query.dart';
import 'availability.dart';
import 'controller.dart';
part 'workspace_actions.dart';
part 'workspace_auth.dart';

class LinsenWorkspace extends StatefulWidget {
  const LinsenWorkspace({super.key});
  @override
  State<LinsenWorkspace> createState() => _LinsenWorkspaceState();
}

final _exporter = TrackExporter();

class _LinsenWorkspaceState extends State<LinsenWorkspace> {
  final query = TextEditingController();
  String platform = 'all', section = 'search';
  List<Map<String, dynamic>> rows = [];
  bool busy = false, more = false;
  String? error;
  int epoch = 0, offset = 0;
  String? collectionPath;
  String? playlistRef;
  final checked = <String>{};
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void showError(Object exception) {
    if (mounted) {
      showCenterMessage('$exception');
    }
  }

  Future<void> load({bool append = false, String? path}) async {
    if (path != null) collectionPath = path;
    if (section != 'tracks') {
      collectionPath = null;
      playlistRef = null;
    }
    path ??= collectionPath;
    final generation = ++epoch;
    if (!append) {
      offset = 0;
      checked.clear();
    }
    setState(() {
      busy = true;
      error = null;
      if (!append) rows = [];
    });
    try {
      if (platform == 'local' || section == 'local') {
        final songs = library.songList.where(
          (s) =>
              !linsen.isOnline(s) &&
              (query.text.isEmpty ||
                  '${s.title} ${s.artist}'.toLowerCase().contains(
                    query.text.toLowerCase(),
                  )),
        );
        if (generation != epoch || !mounted) return;
        setState(() {
          rows = songs
              .map(
                (s) => <String, dynamic>{
                  'local_id': s.id,
                  'name': s.title,
                  'artists': [
                    {'name': s.artist},
                  ],
                },
              )
              .toList();
          more = false;
        });
        return;
      }
      final platforms = section == 'cloud'
          ? ['netease']
          : platform == 'all'
          ? (section == 'search'
                ? platformNames.keys
                      .where((p) => p != 'all' && p != 'local')
                      .toList()
                : (linsen.api?.credentials.keys.toList().isNotEmpty == true
                      ? linsen.api!.credentials.keys.toList()
                      : ['netease']))
          : [platform];
      if (section == 'search' && query.text.trim().isEmpty) {
        setState(() {
          rows = [];
          more = false;
        });
        return;
      }
      final failures = <String>[];
      var cloudHasMore = false, cloudOffset = offset;
      final results = await Future.wait(
        platforms.map((p) async {
          try {
            if (section == 'cloud') {
              final found = <Map<String, dynamic>>[];
              do {
                if (generation != epoch || !mounted) return found;
                final response = await linsen.service.request(
                  'GET',
                  '/v1/account/cloud/tracks',
                  query: {
                    'platform': 'netease',
                    'limit': 100,
                    'offset': cloudOffset,
                  },
                );
                final items = response['data'] as List;
                cloudOffset += items.length;
                final pagination =
                    (response['meta'] as Map?)?['pagination'] as Map?;
                cloudHasMore =
                    items.isNotEmpty &&
                    (pagination?['has_more'] as bool? ?? items.length == 100);
                for (final raw in items) {
                  final item = Map<String, dynamic>.from(raw as Map);
                  final track = Map<String, dynamic>.from(item['track'] as Map);
                  final artists = (track['artists'] as List? ?? [])
                      .map((a) => a['name'])
                      .join(' ');
                  final text =
                      '${track['name']} $artists ${item['filename'] ?? ''}'
                          .toLowerCase();
                  if (text.contains(query.text.trim().toLowerCase())) {
                    found.add({...track, 'ref': item['ref'], 'cloud': true});
                  }
                }
              } while (found.isEmpty && cloudHasMore);
              return found;
            }
            final response = await linsen.service.request(
              'GET',
              path ??
                  switch (section) {
                    'favorites' => '/v1/account/favorites/tracks',
                    'playlists' => '/v1/account/playlists',
                    'albums' => '/v1/account/library/albums',
                    'artists' => '/v1/account/following/artists',
                    'history' => '/v1/account/history/tracks',
                    'cloud' => '/v1/account/cloud/tracks',
                    _ => '/v1/search',
                  },
              query: {
                if (path == null) 'platform': p,
                'limit': 30,
                'offset': offset,
                if (section == 'search') 'q': query.text.trim(),
                if (section == 'search') 'kind': 'track',
              },
            );
            final data = response['data'];
            final items = data is List
                ? data
                : (data as Map?)?['items'] as List? ?? [];
            return items.map((raw) {
              final item = Map<String, dynamic>.from(raw as Map);
              if (item['type'] == 'track') {
                return Map<String, dynamic>.from(item['data'] as Map);
              }
              if (item['track'] is Map) {
                return <String, dynamic>{
                  ...Map<String, dynamic>.from(item['track'] as Map),
                  if (section == 'cloud') 'ref': item['ref'],
                  if (section == 'cloud') 'cloud': true,
                };
              }
              return item;
            }).toList();
          } catch (e) {
            failures.add('${platformNames[p] ?? p}: $e');
            return <Map<String, dynamic>>[];
          }
        }),
      );
      if (generation != epoch || !mounted) return;
      final batch = results.expand((r) => r).toList();
      if (failures.length == platforms.length) {
        throw StateError(failures.join('\n'));
      }
      if (!append && platform == 'all' && section == 'search') {
        batch.addAll(
          library.songList
              .where(
                (song) =>
                    !linsen.isOnline(song) &&
                    '${song.title} ${song.artist}'.toLowerCase().contains(
                      query.text.toLowerCase(),
                    ),
              )
              .map(
                (song) => <String, dynamic>{
                  'local_id': song.id,
                  'name': song.title,
                  'artists': [
                    {'name': song.artist},
                  ],
                },
              ),
        );
      }
      setState(() {
        rows = append ? [...rows, ...batch] : batch;
        more = section == 'cloud'
            ? cloudHasMore
            : results.any((r) => r.length == 30);
        offset = section == 'cloud' ? cloudOffset : offset + 30;
      });
    } catch (e) {
      if (generation == epoch && mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (generation == epoch && mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> play(Map<String, dynamic> row, {bool enqueue = false}) async {
    try {
      final song = row['local_id'] != null
          ? library.id2Song[row['local_id']]!
          : await linsen.materialize(row, cloud: row['cloud'] == true);
      if (enqueue && playQueue.isNotEmpty) {
        audioHandler.enqueueOccurrence(song);
      } else {
        audioHandler.singlePlay(song);
      }
    } catch (e) {
      showError(e);
    }
  }

  Future<void> accounts() async {
    final endpoint = TextEditingController(text: linsen.remoteEndpoint ?? '');
    final credential = TextEditingController();
    String selected = platform == 'all' || platform == 'local'
        ? 'netease'
        : platform;
    bool working = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('账号与服务'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: endpoint,
                    decoration: const InputDecoration(
                      labelText: '远程 TuneWeave 地址（留空使用内嵌服务）',
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    items: platformNames.entries
                        .where((e) => e.key != 'all' && e.key != 'local')
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(
                              '${e.value}${linsen.api?.credentials.containsKey(e.key) == true ? ' · 已登录' : ''}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => update(() {
                      selected = v!;
                    }),
                  ),
                  TextField(
                    controller: credential,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '导入该平台 Cookie',
                      helperText: '凭据仅存于设备安全存储',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: working
                            ? null
                            : () async {
                                await qrLogin(selected);
                                if (context.mounted) update(() {});
                              },
                        child: const Text('扫码登录'),
                      ),
                      TextButton(
                        onPressed: working
                            ? null
                            : () async {
                                await passwordLogin(selected);
                                if (context.mounted) update(() {});
                              },
                        child: const Text('密码登录'),
                      ),
                      TextButton(
                        onPressed: working
                            ? null
                            : () async {
                                update(() {
                                  working = true;
                                });
                                try {
                                  await linsen.importCookie(
                                    selected,
                                    credential.text,
                                  );
                                  credential.clear();
                                  if (context.mounted) update(() {});
                                } catch (e) {
                                  showError(e);
                                } finally {
                                  if (context.mounted) {
                                    update(() {
                                      working = false;
                                    });
                                  }
                                }
                              },
                        child: const Text('导入登录'),
                      ),
                      TextButton(
                        onPressed: working
                            ? null
                            : () async {
                                await linsen.logout(selected);
                                if (context.mounted) update(() {});
                              },
                        child: const Text('退出该平台'),
                      ),
                    ],
                  ),
                  if (linsen.problem != null) Text(linsen.problem!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: working ? null : () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      update(() {
                        working = true;
                      });
                      try {
                        await linsen.connect(endpoint.text);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      } catch (e) {
                        showError(e);
                      } finally {
                        if (dialogContext.mounted) {
                          update(() {
                            working = false;
                          });
                        }
                      }
                    },
              child: const Text('连接服务'),
            ),
          ],
        ),
      ),
    );
    endpoint.dispose();
    credential.dispose();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
            child: Row(
              children: [
                if (Scaffold.maybeOf(context)?.hasDrawer == true)
                  IconButton(
                    tooltip: '音乐库与设置',
                    onPressed: () => Scaffold.of(context).openDrawer(),
                    icon: const Icon(Icons.menu),
                  ),
                const Text(
                  '聆序',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (section == 'local')
                  IconButton(
                    tooltip: '管理本地音乐文件夹',
                    onPressed: () async {
                      await showAnimationDialog(
                        context: context,
                        child: const ManageMusicFolders(),
                      );
                      if (mounted) await load();
                    },
                    icon: const Icon(Icons.folder_open),
                  ),
                if (section == 'cloud')
                  IconButton(
                    tooltip: '上传云盘',
                    onPressed: uploadCloud,
                    icon: const Icon(Icons.cloud_upload_outlined),
                  ),
                if (section == 'playlists')
                  IconButton(
                    tooltip: '新建平台歌单',
                    onPressed: createPlaylist,
                    icon: const Icon(Icons.playlist_add),
                  ),
                IconButton(
                  tooltip: '账号与服务',
                  onPressed: accounts,
                  icon: const Icon(Icons.manage_accounts_outlined),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: query,
                    onSubmitted: (_) => load(),
                    decoration: const InputDecoration(
                      hintText: '搜索歌曲、歌手',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: platform,
                  items: platformNames.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      platform = v!;
                      if (section == 'tracks' ||
                          section == 'cloud' ||
                          section == 'local') {
                        section = 'search';
                      }
                    });
                    load();
                  },
                ),
                IconButton(
                  onPressed: busy ? null : () => load(),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children:
                    const <String, String>{
                          'search': '搜索',
                          'favorites': '收藏歌曲',
                          'playlists': '平台歌单',
                          'albums': '收藏专辑',
                          'artists': '关注歌手',
                          'history': '最近收听',
                          'cloud': '网易云云盘',
                          'local': '本地',
                        }.entries
                        .map(
                          (e) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(e.value),
                              selected: section == e.key,
                              onSelected: (_) {
                                setState(() {
                                  section = e.key;
                                  if (section == 'cloud') platform = 'netease';
                                  if (section == 'local') platform = 'local';
                                });
                                load();
                              },
                            ),
                          ),
                        )
                        .toList(),
              ),
            ),
          ),
          ListenableBuilder(
            listenable: linsen,
            builder: (_, _) {
              final song = currentSongNotifier.value;
              final media = song == null ? null : linsen.playingMedia[song.id];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        media == null
                            ? '本地与在线可加入同一播放队列'
                            : '正在播放：${platformNames[media.platform] ?? media.platform} · ${media.quality}${media.isTrial ? ' · 试听' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownButton<String>(
                      value: linsen.playbackPlatform,
                      items: [
                        const DropdownMenuItem(
                          value: 'auto',
                          child: Text('自动选源'),
                        ),
                        ...platformNames.entries
                            .where((e) => e.key != 'all' && e.key != 'local')
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text('优先${e.value}'),
                              ),
                            ),
                      ],
                      onChanged: (v) => linsen.setPlaybackPlatform(v!),
                    ),
                  ],
                ),
              );
            },
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ListenableBuilder(
              listenable: linsen.availability,
              builder: (_, _) => ListView.builder(
                itemCount: rows.length + (more ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == rows.length) {
                    return TextButton(
                      onPressed: busy ? null : () => load(append: true),
                      child: const Text('加载更多'),
                    );
                  }
                  final row = rows[index];
                  final ref = row['ref'] as String?;
                  final isCollection = const {
                    'playlists',
                    'albums',
                    'artists',
                  }.contains(section);
                  AvailabilityState? state;
                  if (!isCollection && ref != null && row['cloud'] != true) {
                    state = linsen.availability.state(ref);
                    if (checked.add(ref)) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          unawaited(
                            linsen.availability
                                .check(ref)
                                .then<void>(
                                  (_) {},
                                  onError: (Object _, StackTrace _) {},
                                ),
                          );
                        }
                      });
                    }
                  }
                  final artist = (row['artists'] as List? ?? [])
                      .map((a) => a['name'])
                      .join(' / ');
                  return ListTile(
                    title: Text(
                      row['name'] as String? ?? '未命名',
                      style: TextStyle(
                        color: state?.grey == true
                            ? Theme.of(context).disabledColor
                            : null,
                      ),
                    ),
                    subtitle: Text(
                      '$artist${state?.status == Playability.trial ? ' · 试听' : ''}${state?.grey == true ? ' · 暂无可用音源' : ''}',
                    ),
                    onTap: () {
                      if (isCollection && ref != null) {
                        final kind = section == 'playlists'
                            ? 'playlists'
                            : section == 'albums'
                            ? 'albums'
                            : 'artists';
                        setState(() {
                          if (section == 'playlists') playlistRef = ref;
                          section = 'tracks';
                        });
                        load(
                          path: '/v1/$kind/${Uri.encodeComponent(ref)}/tracks',
                        );
                      } else {
                        play(row);
                      }
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isCollection)
                          IconButton(
                            tooltip: '加入队列',
                            onPressed: () => play(row, enqueue: true),
                            icon: const Icon(Icons.queue_music),
                          ),
                        if (ref != null)
                          PopupMenuButton<String>(
                            onSelected: (action) => rowAction(action, row),
                            itemBuilder: (_) => [
                              if (section == 'playlists')
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Text('重命名'),
                                ),
                              if (section == 'playlists')
                                const PopupMenuItem(
                                  value: 'deletePlaylist',
                                  child: Text('删除歌单'),
                                ),
                              if (!isCollection && row['cloud'] != true)
                                const PopupMenuItem(
                                  value: 'favorite',
                                  child: Text('收藏歌曲'),
                                ),
                              if (section == 'favorites')
                                const PopupMenuItem(
                                  value: 'unfavorite',
                                  child: Text('取消收藏'),
                                ),
                              if (!isCollection && row['cloud'] != true)
                                const PopupMenuItem(
                                  value: 'addToPlaylist',
                                  child: Text('添加到平台歌单'),
                                ),
                              if (playlistRef != null)
                                const PopupMenuItem(
                                  value: 'removeTrack',
                                  child: Text('从歌单移除'),
                                ),
                              if (!isCollection)
                                const PopupMenuItem(
                                  value: 'download',
                                  child: Text('下载'),
                                ),
                              if (row['cloud'] == true)
                                const PopupMenuItem(
                                  value: 'deleteCloud',
                                  child: Text('删除云盘歌曲'),
                                ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          if (isTooNarrow(context)) const SizedBox(height: 116),
        ],
      ),
    ),
  );
}
