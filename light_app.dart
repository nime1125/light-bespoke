// =============================================================================
//  통합 조명 제어 — 메인 화면 (Scaffold + 스캔 리스트 → 패널/맵 토글)
//  -----------------------------------------------------------------------------
//  light_engine.dart (BLE 엔진/어댑터) + light_ui.dart (컴포넌트) 를 묶는 진입부.
//  · 스캔 → 기기 선택 → 연결(LightController) → 제어 패널 진입
//  · 상단 토글로 [리스트/패널] ↔ [2D 스테이지 맵] 전환
//  · 권한/스캔은 flutter_blue_plus 표준 흐름
//
//  pubspec.yaml: flutter_blue_plus, shared_preferences
//  (Android: BLUETOOTH_SCAN/CONNECT, iOS: NSBluetoothAlwaysUsageDescription 설정 필요)
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'light_engine.dart';
import 'light_ui.dart';

void main() => runApp(const LightApp());

class LightApp extends StatelessWidget {
  const LightApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LIGHT-BESPOKE',
        debugShowCheckedModeBanner: false,
        theme: NeoDarkTheme.build(),
        home: const HomeScreen(),
      );
}

// 기기 이름 → 브랜드 추정(스캔 결과 분류)
String? detectBrand(String name) {
  final n = name.toLowerCase();
  if (n.contains('godox') || n.startsWith('gdb') || n.startsWith('sl') || n.startsWith('ml')) return 'godox';
  if (n.contains('nanlite') || n.contains('pavo') || n.contains('forza') || n.contains('fc-')) return 'nanlite';
  if (n.contains('amaran') || n.contains('aputure') || n.startsWith('ap-')) return 'aputure';
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// 홈 — 스캔 리스트 + 뷰 토글
// ─────────────────────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _scanning = false;
  bool _mapView = false;
  final Map<String, LightController> _connected = {}; // deviceId → controller
  final List<StageNode> _nodes = []; // 맵 노드

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    } finally {
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    final brand = detectBrand(device.platformName);
    if (brand == null) {
      _toast('지원 브랜드(Godox/Nanlite/Aputure)가 아닙니다');
      return;
    }
    final controller = LightController(device, AdapterFactory.create(brand));
    try {
      await controller.connect(); // 연결 + 무음 동기화
      _connected[device.remoteId.str] = controller;
      // 맵에도 조명 노드 추가
      _nodes.add(StageNode(
        id: device.remoteId.str, type: NodeType.light,
        pos: Offset(400 + _nodes.length * 80.0, 400),
        color: AppColors.accent, label: device.platformName));
      if (!mounted) return;
      setState(() {});
      _openPanel(controller, device.platformName);
    } catch (e) {
      _toast('연결 실패: $e');
    }
  }

  void _openPanel(LightController c, String title) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ControlScreen(controller: c, title: title)));
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _TopBar(
        mapView: _mapView,
        onToggleView: () => setState(() => _mapView = !_mapView),
        scanning: _scanning,
        onScan: _scan,
      ),
      body: _mapView ? _buildMap() : _buildList(),
    );
  }

  // 2D 스테이지 맵 — 노드 탭 시 해당 조명 제어 패널 오버레이
  Widget _buildMap() => StageMapView(
        initialNodes: _nodes,
        controlBuilder: (node) {
          final c = _connected[node.id];
          if (c == null) return const Center(child: Text('연결 안 됨', style: TextStyle(color: AppColors.textSub)));
          return LightControlPanel(
            onBrightness: c.setBrightness,
            onCct: c.setCct,
            onTint: (t) {}, // G/M 채널은 어댑터 확장 시 연결
            onHsi: c.setHsi,
            onEffect: c.setEffect,
          );
        },
      );

  // 스캔 결과 리스트
  Widget _buildList() => StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,
        initialData: const [],
        builder: (context, snap) {
          final results = (snap.data ?? [])
              .where((r) => detectBrand(r.device.platformName) != null)
              .toList();
          if (results.isEmpty) {
            return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.bluetooth_searching, size: 52, color: AppColors.border2),
              const SizedBox(height: 12),
              Text(_scanning ? '조명 검색 중...' : '상단 PAIR 버튼으로 BLE 조명을 검색하세요',
                style: const TextStyle(color: AppColors.textSub, fontSize: 12)),
            ]));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: results.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final r = results[i];
              final brand = detectBrand(r.device.platformName)!;
              final connected = _connected.containsKey(r.device.remoteId.str);
              return _DeviceCard(
                name: r.device.platformName.isEmpty ? 'Unknown' : r.device.platformName,
                brand: brand, rssi: r.rssi, connected: connected,
                onTap: () => connected
                    ? _openPanel(_connected[r.device.remoteId.str]!, r.device.platformName)
                    : _connect(r.device),
              );
            },
          );
        },
      );
}

// 상단바
class _TopBar extends StatelessWidget implements PreferredSizeWidget {
  final bool mapView, scanning;
  final VoidCallback onToggleView, onScan;
  const _TopBar({required this.mapView, required this.scanning, required this.onToggleView, required this.onScan});

  @override
  Size get preferredSize => const Size.fromHeight(54);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.bgPanel,
      elevation: 0,
      titleSpacing: 14,
      title: Row(children: [
        Container(width: 28, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFFFFA24B), Color(0xFFFF6B00), Color(0xFFE0431A)]),
            borderRadius: BorderRadius.circular(8)),
          child: const Icon(Icons.tune, color: Colors.white, size: 16)),
        const SizedBox(width: 8),
        const Text('LIGHT-BESPOKE', style: TextStyle(
          fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPri)),
      ]),
      actions: [
        IconButton(
          tooltip: mapView ? '리스트' : '2D 맵',
          onPressed: onToggleView,
          icon: Icon(mapView ? Icons.list : Icons.map, color: AppColors.accent)),
        Padding(
          padding: const EdgeInsets.only(right: 10, left: 4),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent, foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14)),
            onPressed: scanning ? null : onScan,
            icon: scanning
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Icon(Icons.add, size: 16),
            label: const Text('PAIR', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

// 기기 카드
class _DeviceCard extends StatelessWidget {
  final String name, brand; final int rssi; final bool connected; final VoidCallback onTap;
  const _DeviceCard({required this.name, required this.brand, required this.rssi, required this.connected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bgCard,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap, borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: connected ? AppColors.accentFx.withOpacity(0.4) : AppColors.border)),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(
              shape: BoxShape.circle, color: connected ? AppColors.accentFx : AppColors.border2)),
            const SizedBox(width: 10),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppColors.accent.withOpacity(0.12), borderRadius: BorderRadius.circular(3)),
              child: Text(brand.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.accent))),
            const SizedBox(width: 10),
            Expanded(child: Text(name, style: const TextStyle(color: AppColors.textPri, fontSize: 13), overflow: TextOverflow.ellipsis)),
            Text(connected ? '연결됨' : '$rssi dBm', style: TextStyle(
              fontSize: 11, color: connected ? AppColors.accentFx : AppColors.textSub)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 제어 화면 — 패널(CCT/HSI/Effect)
// ─────────────────────────────────────────────────────────────────────────────
class ControlScreen extends StatelessWidget {
  final LightController controller;
  final String title;
  const ControlScreen({super.key, required this.controller, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bgPanel, elevation: 0,
        title: Text(title, style: const TextStyle(fontSize: 15, color: AppColors.textPri)),
        actions: [
          IconButton(onPressed: () => controller.setPower(true), icon: const Icon(Icons.power_settings_new, color: AppColors.accentFx)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: LightControlPanel(
          onBrightness: controller.setBrightness, // 코얼레싱 큐에 바인딩
          onCct: controller.setCct,
          onTint: (t) {},
          onHsi: controller.setHsi,
          onEffect: controller.setEffect,
        ),
      ),
    );
  }
}
