/*
 * 「仅 R-18」个性化首页 —— 本文件由 fork 配方注入，不属于上游代码。
 *
 * 设计依据（基于真实账号实测数据）：
 *   - 个性化推荐流 R-18 占比仅 1.6%，过滤后几乎为空 → 不采用
 *   - 收藏作品中 R-18 占 51.9%（2663 收藏 ≈ 1382 个可用种子）
 *   - 以 R-18 收藏为种子做一跳 /v2/illust/related，R-18 命中率 76.7%
 *   - 二跳开始漂移（56.7%），三跳彻底跑偏 → 只做一跳
 *
 * 因此首页数据源 = 「你的收藏的邻居」，而非 pixiv 推荐流。
 */

import 'dart:convert';
import 'dart:math';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixez/er/prefer.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/picture/illust_store.dart';

class R18OnlyFeed {
  static const String _kEnabled = 'r18_only_enabled';
  static const String _kSeeds = 'r18_only_seeds_v1';
  static const String _kSeedPage = 'r18_only_seed_page_v1';
  static const String _kSeen = 'r18_only_seen_v1';
  static const String _kUsed = 'r18_only_used_v1';

  /// 每轮取几个种子（1 种子 ≈ 30 条相关，命中 76.7%）
  static const int _seedsPerRound = 4;

  /// 已经排好、等着被 fetchNext 消费的列表
  static final List<Map<String, dynamic>> _buffer = [];

  /// 记住首页那个 store，供开关切换后立即刷新
  static dynamic homeStore;

  static final Random _rand = Random();

  static bool get enabled => Prefer.getBool(_kEnabled) ?? false;

  static Future<void> setEnabled(bool value) async {
    await Prefer.setBool(_kEnabled, value);
    _buffer.clear();
    try {
      await homeStore?.fetch();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 注入钩子

  /// 在 LightingStore.fetch() 开头调用；返回 true 表示已接管，调用方应直接 return
  static Future<bool> interceptFetch(dynamic store) async {
    if (!_isHomeStore(store)) return false;
    homeStore = store;
    if (!enabled) return false;

    store.refreshing = true;
    store.errorMessage = null;
    try {
      _buffer.clear();
      final list = await _buildRound(seedCount: _seedsPerRound);
      store.iStores.clear();
      store.iStores.addAll(
        list.map((j) => IllustStore(j['id'] as int, Illusts.fromJson(j))),
      );
      store.refreshing = false;
      store.easyRefreshController?.finishRefresh(IndicatorResult.success);
      return true;
    } catch (e) {
      store.refreshing = false;
      store.errorMessage = _friendlyError(e);
      store.easyRefreshController?.finishRefresh(IndicatorResult.fail);
      return true;
    }
  }

  /// 在 LightingStore.fetchNext() 开头调用
  static Future<bool> interceptNext(dynamic store) async {
    if (!_isHomeStore(store)) return false;
    if (!enabled) return false;

    try {
      if (_buffer.isEmpty) {
        final more = await _buildRound(seedCount: 2, shuffle: false);
        if (more.isEmpty) {
          store.easyRefreshController?.finishLoad(IndicatorResult.noMore);
          return true;
        }
        _buffer.addAll(more);
      }
      final take = _buffer.take(24).toList();
      _buffer.removeRange(0, take.length);
      final existing = <int>{
        for (final e in store.iStores as Iterable) (e as IllustStore).id,
      };
      store.iStores.addAll(
        take
            .where((j) => !existing.contains(j['id']))
            .map((j) => IllustStore(j['id'] as int, Illusts.fromJson(j))),
      );
      store.easyRefreshController?.finishLoad(IndicatorResult.success);
      return true;
    } catch (e) {
      store.easyRefreshController?.finishLoad(IndicatorResult.fail);
      return true;
    }
  }

  static bool _isHomeStore(dynamic store) {
    try {
      return store?.source?.glanceKey == 'recom';
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 核心组装

  static Future<List<Map<String, dynamic>>> _buildRound({
    required int seedCount,
    bool shuffle = true,
  }) async {
    final seeds = await _ensureSeeds();
    if (seeds.isEmpty) {
      throw StateError('还没有可用的 R-18 收藏作为种子');
    }

    final used = _loadUsed();
    // 最久没用过的种子优先，保证每次刷新都是新内容
    final ordered = [...seeds]
      ..sort((a, b) => (used[a] ?? 0).compareTo(used[b] ?? 0));
    final picks = ordered.take(seedCount).toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in picks) {
      used[s] = now;
    }
    await _saveUsed(used);

    final seen = _loadSeen();
    final out = <Map<String, dynamic>>[];
    final ids = <int>{};

    for (final seed in picks) {
      try {
        final resp = await apiClient.getIllustRelated(seed, force: true);
        final data = resp.data;
        final list = (data is Map ? data['illusts'] : null) as List? ?? const [];
        for (final raw in list) {
          final map = _asMap(raw);
          if (map == null) continue;
          final id = map['id'];
          if (id is! int) continue;
          if (id == seed) continue;
          if (ids.contains(id) || seen.contains(id)) continue;
          if (!_isR18(map)) continue;
          ids.add(id);
          out.add(map);
        }
      } catch (_) {
        // 单个种子失败不影响整体
      }
      await Future<void>.delayed(const Duration(milliseconds: 260));
    }

    if (out.isEmpty) {
      throw StateError('种子没有扩散出 R-18 作品，可能需要在 pixiv 网页端开启 R-18 显示');
    }

    // 轮换种子顺序，避免每次都以同一批打头
    if (shuffle) out.shuffle(_rand);

    await _saveSeen(seen, ids);
    // 顺手补一页种子，让池子随使用慢慢变大
    _expandSeedsInBackground();
    return out;
  }

  /// Dio 解析出来的嵌套 Map 类型不一定严格是 Map<String, dynamic>
  static Map<String, dynamic>? _asMap(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      return raw.map((k, v) => MapEntry('$k', v));
    }
    return null;
  }

  static bool _isR18(Map<String, dynamic> j) {
    final x = j['x_restrict'];
    if (x is num && x > 0) return true;
    final tags = j['tags'];
    if (tags is List) {
      for (final t in tags) {
        if (t is Map && ((t['name'] as String?) ?? '').startsWith('R-18')) {
          return true;
        }
      }
    }
    return false;
  }

  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('429')) return '请求太频繁，稍后再试';
    return s;
  }

  // ---------------------------------------------------------------- 种子池

  static String get _uid => accountStore.now?.userId ?? '0';

  static Future<List<int>> _ensureSeeds() async {
    var seeds = _loadSeeds();
    if (seeds.length >= _seedsPerRound * 2) return seeds;
    await _expandSeeds(pages: 10);
    seeds = _loadSeeds();
    return seeds;
  }

  static List<int> _loadSeeds() {
    final raw = Prefer.getString('${_kSeeds}_$_uid');
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).whereType<int>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveSeeds(List<int> seeds) async {
    await Prefer.setString('${_kSeeds}_$_uid', jsonEncode(seeds));
  }

  static void _expandSeedsInBackground() {
    // 不阻塞 UI，失败也不影响当前这一轮
    Future<void>(() async {
      try {
        await _expandSeeds(pages: 1);
      } catch (_) {}
    });
  }

  /// 从收藏里分页捞 R-18 作品当种子；每轮只推进一页，池子随使用增长
  static Future<void> _expandSeeds({int pages = 1}) async {
    final userId = int.tryParse(_uid);
    if (userId == null) return;

    var seeds = _loadSeeds();
    final known = seeds.toSet();
    var page = Prefer.getInt('${_kSeedPage}_$_uid') ?? 0;
    String? url =
        'https://app-api.pixiv.net/v1/user/bookmarks/illust'
        '?user_id=$userId&restrict=public&filter=for_android';

    // 跳过已经读过的页
    for (var i = 0; i < page && url != null; i++) {
      final r = await apiClient.httpClient.get(url);
      url = (r.data is Map ? r.data['next_url'] : null) as String?;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    for (var i = 0; i < pages && url != null; i++) {
      final resp = await apiClient.httpClient.get(url);
      final data = resp.data;
      final list = (data is Map ? data['illusts'] : null) as List? ?? const [];
      for (final entry in list) {
        final holder = _asMap(entry);
        if (holder == null) continue;
        final illus = _asMap(holder['illust'] ?? holder);
        if (illus == null) continue;
        final id = illus['id'];
        if (id is int && !known.contains(id) && _isR18(illus)) {
          known.add(id);
          seeds.add(id);
        }
      }
      url = (data is Map ? data['next_url'] : null) as String?;
      page++;
      await Prefer.setInt('${_kSeedPage}_$_uid', page);
      await _saveSeeds(seeds);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  // ---------------------------------------------------------------- 去重与轮换

  static Set<int> _loadSeen() {
    final raw = Prefer.getString('${_kSeen}_$_uid');
    if (raw == null || raw.isEmpty) return <int>{};
    try {
      return (jsonDecode(raw) as List).whereType<int>().toSet();
    } catch (_) {
      return <int>{};
    }
  }

  static Future<void> _saveSeen(Set<int> seen, Set<int> added) async {
    seen.addAll(added);
    // 只保留最近 4000 条，避免无限增长
    final trimmed = seen.length > 4000
        ? seen.toList().sublist(seen.length - 4000)
        : seen.toList();
    await Prefer.setString('${_kSeen}_$_uid', jsonEncode(trimmed));
  }

  static Map<int, int> _loadUsed() {
    final raw = Prefer.getString('${_kUsed}_$_uid');
    if (raw == null || raw.isEmpty) return <int, int>{};
    try {
      final m = jsonDecode(raw) as Map;
      return m.map((k, v) => MapEntry(int.parse('$k'), (v as num).toInt()));
    } catch (_) {
      return <int, int>{};
    }
  }

  static Future<void> _saveUsed(Map<int, int> used) async {
    if (used.length > 2000) {
      final sorted = used.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      used = Map.fromEntries(sorted.take(2000));
    }
    await Prefer.setString(
      '${_kUsed}_$_uid',
      jsonEncode(used.map((k, v) => MapEntry('$k', v))),
    );
  }
}

/// 首页顶部的模式切换条：「推荐」/「仅 R-18」
///
/// 为什么不做浮层胶囊、也不做长按手势（上一版三个方案都失败的真实原因）：
///   1. 右上角已被占用：首页第一行右侧就是 Spotlight 的「更多」按钮
///      （recom_spotlight_page.dart 的 _buildFirstRow），而上面的 SliverAppBar
///      标题为空、背景色被注释掉（透明），任何浮层都会和它叠在同一块像素上。
///   2. 右下角也被占用：HelloPage 的 Scaffold 是 extendBody: true，
///      NavigationBar 高 68 且第 5 项就是「更多」，浮层不是压住导航栏就是盖住卡片。
///   3. 长按更不可行：卡片自身已用 onLongPress 做「长按保存」（illust_card.dart），
///      外层还有 PageView 横滑和 EasyRefresh 滚动，手势必然互相吞。
///
/// 所以：把它做成内容流里的第一行（不是浮层），遮挡、手势、安全区三个问题一次性消失。
class R18OnlyBar extends StatefulWidget {
  const R18OnlyBar({super.key});

  @override
  State<R18OnlyBar> createState() => _R18OnlyBarState();
}

class _R18OnlyBarState extends State<R18OnlyBar> {
  bool _busy = false;

  Future<void> _switch(bool value) async {
    if (_busy || R18OnlyFeed.enabled == value) return;
    setState(() => _busy = true);
    await R18OnlyFeed.setEnabled(value);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value ? '已切到「仅 R-18」：内容来自你的收藏' : '已恢复常规推荐'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final on = R18OnlyFeed.enabled;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 10),
      child: Opacity(
        opacity: _busy ? 0.55 : 1,
        child: Container(
          height: 38,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(19),
          ),
          child: Row(
            children: <Widget>[
              _segment(context, '推荐', !on, () => _switch(false)),
              _segment(context, '仅 R-18', on, () => _switch(true)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    bool active,
    VoidCallback onTap,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? scheme.primary : const Color(0x00000000),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active
                    ? scheme.onPrimary
                    : scheme.primary.withValues(alpha: 0.75),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

