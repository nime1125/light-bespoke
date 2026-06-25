// =============================================================================
//  LIGHT-BESPOKE — 3사 통합 조명 제어 (단일 파일 빌드용 main.dart)
//  실기기 패킷 로그 테스트판 : 스캔 → 연결 → 제어(CCT/HSI/Effect) → 송신 Hex 로그
// =============================================================================
//  ■ 빌드 준비
//   1) flutter create light_bespoke && cd light_bespoke
//   2) 이 파일로 lib/main.dart 교체
//   3) pubspec.yaml 에 의존성 추가:
//        dependencies:
//          flutter_blue_plus: ^1.32.0
//          shared_preferences: ^2.2.0
//   4) flutter pub get
//   5) flutter run   (또는 flutter build apk --release)
//
//  ■ Android — android/app/src/main/AndroidManifest.xml <manifest> 안:
//      <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
//          android:usesPermissionFlags="neverForLocation" />
//      <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
//      <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
//    (minSdk 21 이상 권장: android/app/build.gradle → minSdkVersion 21)
//
//  ■ iOS — ios/Runner/Info.plist:
//      <key>NSBluetoothAlwaysUsageDescription</key><string>조명 제어를 위해 블루투스를 사용합니다</string>
//
//  ⚠ 신뢰도: Godox 전원/밝기 = 검증된 제공 스펙. CCT/HSI/Effect 및
//     Nanlite/Aputure 패킷은 best-effort → 이 앱의 "패킷 로그"로 실제 앱 캡처와
//     대조·교정하는 것이 목적. (Aputure 직접 GATT 는 Sidus 메시 암호화로 미공개)
// =============================================================================

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const LightApp());

// ─────────────────────────────────────────────────────────────────────────────
//  공용 — 패킷 로거 (실기기 테스트의 핵심)
// ─────────────────────────────────────────────────────────────────────────────
String toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join(' ');

class PacketLogger {
  PacketLogger._();
  static final PacketLogger I = PacketLogger._();
  final ValueNotifier<List<String>> lines = ValueNotifier<List<String>>(<String>[]);

  void log(String msg) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}'
        ':${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
    final next = [...lines.value, '[$ts] $msg'];
    if (next.length > 200) next.removeRange(0, next.length - 200); // 최근 200줄 유지
    lines.value = next;
    // ignore: avoid_print
    print('PKT $msg');
  }

  void clear() => lines.value = <String>[];
}

// ─────────────────────────────────────────────────────────────────────────────
//  디자인 토큰 & 테마 (Neo-Dark)
// ─────────────────────────────────────────────────────────────────────────────
class AppColors {
  static const bgApp = Color(0xFF0A0A0A);
  static const bgPanel = Color(0xFF0F0F0F);
  static const bgCard = Color(0xFF161616);
  static const bgSunken = Color(0xFF111111);
  static const border = Color(0xFF222222);
  static const border2 = Color(0xFF333333);
  static const textPri = Color(0xFFDDE0EC);
  static const textSub = Color(0xFF888888);
  static const textFaint = Color(0xFF3A3A3A);
  static const accent = Color(0xFFFF6B00);
  static const accentFx = Color(0xFF46AA5F);
  static const cctCool = Color(0xFF93C5FD);
  static const logGreen = Color(0xFF6FE39A);
}

ThemeData buildTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgApp,
      colorScheme: const ColorScheme.dark(
          primary: AppColors.accent, secondary: AppColors.accentFx, surface: AppColors.bgCard),
      sliderTheme: const SliderThemeData(
          trackHeight: 5,
          overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 9)),
    );

// ─────────────────────────────────────────────────────────────────────────────
//  체크섬 / 어댑터 인터페이스 / 브랜드 구현 / 팩토리
// ─────────────────────────────────────────────────────────────────────────────
class Checksum {
  // 🔧 교정 포인트(체크섬): 기기가 패킷을 거부하면 이 공식을 캡처값에 맞게 교체.
  //   sum&0xFF(현재) / XOR / 2의보수((0x100-sum)&0xFF) / CRC8-Maxim 중 택1.
  static int sumLow(List<int> bytes) {              // Σbytes & 0xFF
    int s = 0;
    for (final b in bytes) s += b;
    return s & 0xFF;
  }
  static int xor8(List<int> bytes) { int x = 0; for (final b in bytes) x ^= b; return x & 0xFF; }
  static int twos(List<int> bytes) { int s = 0; for (final b in bytes) s += b; return (0x100 - (s & 0xFF)) & 0xFF; }
  static int crc8Maxim(List<int> bytes) {
    int c = 0;
    for (final b in bytes) { c ^= b & 0xFF; for (int i = 0; i < 8; i++) c = (c & 1) != 0 ? (c >> 1) ^ 0x8C : (c >> 1); }
    return c & 0xFF;
  }
}

abstract class LightAdapter {
  String get brand;
  String get serviceUuid;
  String get characteristicUuid;
  String? get notifyUuid => null;
  bool get verified;
  bool get preferWriteWithoutResponse => true;

  List<int> encodePower(bool isOn);
  List<int> encodeBrightness(int percentage);
  List<int> encodeCct(int kelvin) => const [];
  List<int> encodeHsi(double hue, double sat, double intensity) => const [];
  List<int> encodeEffect(String effect, int speed, String cycle) => const [];

  int clampPct(int p) => p < 0 ? 0 : (p > 100 ? 100 : p);
}

class GodoxAdapter extends LightAdapter {
  @override String get brand => 'Godox';
  @override String get serviceUuid => '0000fff0-0000-1000-8000-00805f9b34fb';
  @override String get characteristicUuid => '0000fff1-0000-1000-8000-00805f9b34fb';
  @override bool get verified => true;

  static const List<int> _on = [0x55, 0xAA, 0x01, 0x01, 0x00, 0xFE];
  static const List<int> _off = [0x55, 0xAA, 0x01, 0x00, 0x00, 0xFF];
  // 🔧 교정(Godox): 프레임 [55 AA cmd value 00 checksum]. cmd(전원01·밝기02·CCT03·HSI04·효과07추정)
  //   value 스케일·checksum(sumLow→xor8/twos/crc8Maxim)을 HCI 캡처값에 맞춰 수정.
  List<int> _frame(int cmd, int v) {
    final body = [0x55, 0xAA, cmd, v & 0xFF, 0x00];
    return [...body, Checksum.sumLow(body)];
  }

  @override List<int> encodePower(bool isOn) => isOn ? _on : _off;
  @override List<int> encodeBrightness(int p) => _frame(0x02, clampPct(p));
  @override List<int> encodeCct(int k) => _frame(0x03, (((k - 2700) / 4800) * 255).round().clamp(0, 255));
  @override List<int> encodeHsi(double h, double s, double i) => _frame(0x04, (h / 360 * 255).round().clamp(0, 255));
}

class NanliteAdapter extends LightAdapter {
  @override String get brand => 'Nanlite';
  @override String get serviceUuid => '0003cdd0-0000-1000-8000-00805f9b0131';
  @override String get characteristicUuid => '0003cdd2-0000-1000-8000-00805f9b0131';
  @override String? get notifyUuid => '0003cdd1-0000-1000-8000-00805f9b0131';
  @override bool get verified => false;

  List<int> _stream(int opt, int v16) =>
      [0x03, 0x20, opt, 0x01, (v16 >> 8) & 0xFF, v16 & 0xFF, 0x00, 0x04];

  // 🔧 교정(Nanlite): 8바이트 [03 20 opt 01 valHi valLo 00 04]. opt(밝기01·CCT03·Hue05·Sat0C),
  //   value 엔디안/위치(idx4·5), 효과 opcode 를 캡처값에 맞춰 수정.
  @override List<int> encodeBrightness(int p) => [0x03, 0x20, 0x01, 0x01, 0x00, clampPct(p), 0x00, 0x04];
  @override List<int> encodePower(bool isOn) => encodeBrightness(isOn ? 100 : 0);
  @override List<int> encodeCct(int k) => _stream(0x03, k);
  @override List<int> encodeHsi(double h, double s, double i) => _stream(0x05, h.round());
}

class AputureAdapter extends LightAdapter {
  final int nodeId;
  AputureAdapter({this.nodeId = 0x00});
  @override String get brand => 'Aputure';
  @override String get serviceUuid => '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  @override String get characteristicUuid => '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  @override String? get notifyUuid => '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  @override bool get verified => false;

  List<int> _mesh(int cmd, List<int> p) {
    final h = [0x55, 0xAA, nodeId & 0xFF, cmd & 0xFF, p.length & 0xFF];
    int x = 0;
    for (final b in h) x ^= b;
    for (final b in p) x ^= b;
    return [...h, ...p, x & 0xFF];
  }

  // 🔧 교정(Aputure/Sidus Mesh): header[2]=nodeId, header[3]=cmd, payload·XOR.
  //   ※ 메시 암호화로 직접 GATT 미작동 시 Sidus Open API(WebSocket) 경로로 전환.
  @override List<int> encodePower(bool isOn) => _mesh(0x01, [isOn ? 0x01 : 0x00]);
  @override List<int> encodeBrightness(int p) => _mesh(0x02, [clampPct(p)]);
  @override List<int> encodeCct(int k) => _mesh(0x03, [(k >> 8) & 0xFF, k & 0xFF]);
  @override List<int> encodeHsi(double h, double s, double i) =>
      _mesh(0x04, [(h.round() >> 8) & 0xFF, h.round() & 0xFF, s.round() & 0xFF]);
}

class AdapterFactory {
  static LightAdapter create(String brand, {int aputureNodeId = 0x00}) {
    switch (brand.toLowerCase()) {
      case 'godox': return GodoxAdapter();
      case 'nanlite': return NanliteAdapter();
      case 'aputure':
      case 'amaran': return AputureAdapter(nodeId: aputureNodeId);
      default: throw ArgumentError('지원하지 않는 브랜드: $brand');
    }
  }
}

String? detectBrand(String name) {
  final n = name.toLowerCase();
  if (n.contains('godox') || n.startsWith('gdb') || n.startsWith('sl') || n.startsWith('ml')) return 'godox';
  if (n.contains('nanlite') || n.contains('pavo') || n.contains('forza') || n.contains('fc-')) return 'nanlite';
  if (n.contains('amaran') || n.contains('aputure') || n.startsWith('ap-')) return 'aputure';
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
//  상태 메모리 (무음 동기화)
// ─────────────────────────────────────────────────────────────────────────────
class DeviceState {
  int brightness, cct;
  double hue, sat;
  bool isOn;
  DeviceState({this.brightness = 100, this.cct = 5600, this.hue = 0, this.sat = 0, this.isOn = true});
}

class LightStateStore {
  static String _k(String id) => 'lightstate_$id';
  static Future<void> save(String id, DeviceState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_k(id), '${s.isOn ? 1 : 0}|${s.brightness}|${s.cct}|${s.hue.round()}|${s.sat.round()}');
  }
  static Future<DeviceState?> load(String id) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_k(id));
    if (raw == null) return null;
    final v = raw.split('|');
    if (v.length < 2) return null;
    return DeviceState(
      isOn: v[0] == '1',
      brightness: int.tryParse(v[1]) ?? 100,
      cct: v.length > 2 ? int.tryParse(v[2]) ?? 5600 : 5600,
      hue: v.length > 3 ? double.tryParse(v[3]) ?? 0 : 0,
      sat: v.length > 4 ? double.tryParse(v[4]) ?? 0 : 0,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  컨트롤러 — 연결/무음동기화/코얼레싱 큐/재연결 + 패킷 로깅
// ─────────────────────────────────────────────────────────────────────────────
class LightController {
  final BluetoothDevice device;
  final LightAdapter adapter;
  final int sendIntervalMs;

  BluetoothCharacteristic? _writeChar;
  bool _writeNoResponse = false;
  DeviceState _state = DeviceState();

  List<int> Function()? _pendingEncode;
  bool _flushScheduled = false;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);
  int enqueuedCount = 0, sentCount = 0;

  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _manualDisconnect = false;
  int _reconnectAttempt = 0;
  static const List<int> _backoff = [1, 2, 4, 8];

  LightController(this.device, this.adapter, {this.sendIntervalMs = 35});
  String get _id => device.remoteId.str;

  Future<void> connect() async {
    _manualDisconnect = false;
    _listenConn();
    PacketLogger.I.log('${adapter.brand} 연결 시도...');
    await device.connect(timeout: const Duration(seconds: 10), autoConnect: false, license: License.free);
    await _discover();
    await _silentSync();
    _reconnectAttempt = 0;
    PacketLogger.I.log('${adapter.brand} 연결 완료 (WWR=$_writeNoResponse)');
  }

  Future<void> _discover() async {
    final services = await device.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == Guid(adapter.serviceUuid),
        orElse: () => throw StateError('서비스 없음: ${adapter.serviceUuid}'));
    final ch = svc.characteristics.firstWhere((c) => c.uuid == Guid(adapter.characteristicUuid),
        orElse: () => throw StateError('캐릭터리스틱 없음: ${adapter.characteristicUuid}'));
    _writeChar = ch;
    _writeNoResponse = adapter.preferWriteWithoutResponse && ch.properties.writeWithoutResponse;
  }

  Future<void> _silentSync() async {
    final saved = await LightStateStore.load(_id);
    if (saved == null) return;
    _state = saved;
    PacketLogger.I.log('무음 동기화: 밝기 ${saved.brightness}% 복원');
    await _writeRaw(saved.isOn ? adapter.encodeBrightness(saved.brightness) : adapter.encodePower(false), tag: 'SYNC');
  }

  void _enqueue(List<int> Function() encode) {
    enqueuedCount++;
    _pendingEncode = encode;
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    final elapsed = DateTime.now().difference(_lastSend).inMilliseconds;
    final wait = elapsed >= sendIntervalMs ? 0 : (sendIntervalMs - elapsed);
    _flushScheduled = true;
    Future.delayed(Duration(milliseconds: wait), _flush);
  }

  Future<void> _flush() async {
    _flushScheduled = false;
    final encode = _pendingEncode;
    if (encode == null) return;
    _pendingEncode = null;
    _lastSend = DateTime.now();
    final bytes = encode();
    if (bytes.isNotEmpty) {
      await _writeRaw(bytes);
      sentCount++;
    }
    _persist();
    if (_pendingEncode != null) _scheduleFlush();
  }

  void setBrightness(int p) {
    final v = adapter.clampPct(p);
    _state.brightness = v; if (v > 0) _state.isOn = true;
    _enqueue(() => adapter.encodeBrightness(v));
  }
  void setCct(int k) { _state.cct = k; _enqueue(() => adapter.encodeCct(k)); }
  void setHsi(double h, double s, double i) { _state.hue = h; _state.sat = s; _enqueue(() => adapter.encodeHsi(h, s, i)); }

  Future<void> setPower(bool isOn) async { _state.isOn = isOn; await _writeRaw(adapter.encodePower(isOn), tag: 'PWR'); _persist(); }
  Future<void> setEffect(String e, int sp, String cy) async {
    final b = adapter.encodeEffect(e, sp, cy);
    if (b.isNotEmpty) await _writeRaw(b, tag: 'FX'); else PacketLogger.I.log('${adapter.brand} 효과 인코딩 미구현');
  }

  Future<void> _writeRaw(List<int> bytes, {String tag = 'DIM'}) async {
    final ch = _writeChar;
    if (bytes.isEmpty) return;
    // ★ 패킷 로그: 송신 직전 Hex 기록
    PacketLogger.I.log('${adapter.brand} ◀ [$tag] ${toHex(bytes)}${_writeNoResponse ? ' (WWR)' : ''}');
    if (ch == null) { PacketLogger.I.log('  └ 미연결 — 송신 생략'); return; }
    try {
      await ch.write(bytes, withoutResponse: _writeNoResponse);
    } catch (e) {
      PacketLogger.I.log('  └ 송신 실패: $e');
    }
  }

  void _persist() {
    final now = DateTime.now();
    if (now.difference(_lastSave).inMilliseconds < 500) return;
    _lastSave = now;
    LightStateStore.save(_id, _state);
  }

  void _listenConn() {
    _connSub?.cancel();
    _connSub = device.connectionState.listen((st) {
      if (st == BluetoothConnectionState.disconnected && !_manualDisconnect) {
        PacketLogger.I.log('${adapter.brand} 연결 끊김 → 재연결 대기');
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    final idx = _reconnectAttempt < _backoff.length ? _reconnectAttempt : _backoff.length - 1;
    final delay = _backoff[idx];
    _reconnectAttempt++;
    Future.delayed(Duration(seconds: delay), () async {
      if (_manualDisconnect) return;
      try {
        await device.connect(timeout: const Duration(seconds: 10), autoConnect: false, license: License.free);
        await _discover();
        await _silentSync();
        _reconnectAttempt = 0;
        PacketLogger.I.log('${adapter.brand} 재연결 성공');
      } catch (_) { _scheduleReconnect(); }
    });
  }

  Future<void> dispose() async {
    _manualDisconnect = true;
    await LightStateStore.save(_id, _state);
    await _connSub?.cancel();
    try { await device.disconnect(); } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  앱 진입 / 홈(스캔)
// ─────────────────────────────────────────────────────────────────────────────
class LightApp extends StatelessWidget {
  const LightApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'LIGHT-BESPOKE', debugShowCheckedModeBanner: false,
      theme: buildTheme(), home: const HomeScreen());
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _scanning = false;
  final Map<String, LightController> _connected = {};

  // 스캔 결과에서 표시 이름(광고이름 우선 — 스캔 단계 platformName은 보통 비어있음)
  String _nameOf(ScanResult r) {
    final a = r.advertisementData.advName;
    if (a.isNotEmpty) return a;
    if (r.device.platformName.isNotEmpty) return r.device.platformName;
    return '';
  }

  Future<void> _scan() async {
    if (await FlutterBluePlus.isSupported == false) { _toast('이 기기는 BLE 미지원'); return; }

    // ★ Android 12+ 런타임 권한 요청 (없으면 스캔 결과가 0 → 리스트 안 뜸)
    final st = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    if (st[Permission.bluetoothScan]?.isGranted != true ||
        st[Permission.bluetoothConnect]?.isGranted != true) {
      PacketLogger.I.log('권한 거부: BLUETOOTH_SCAN/CONNECT — 설정에서 허용 필요');
      _toast('블루투스 권한을 허용해주세요');
      if (st.values.any((s) => s.isPermanentlyDenied)) await openAppSettings();
      return;
    }

    // 어댑터 ON 확인
    try {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
    } catch (_) {}

    setState(() => _scanning = true);
    PacketLogger.I.log('스캔 시작...');
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        androidUsesFineLocation: false,   // neverForLocation 선언과 일치
      );
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(BluetoothDevice d, String name) async {
    final brand = detectBrand(name);
    if (brand == null) {
      // 미인식 이름은 로그로 남겨 detectBrand 패턴을 추가할 수 있게 함
      PacketLogger.I.log('미인식 기기: "$name" (${d.remoteId.str}) — 패턴 추가 필요');
      _toast('브랜드 미인식: "$name"');
      return;
    }
    final c = LightController(d, AdapterFactory.create(brand));
    try {
      await c.connect();
      _connected[d.remoteId.str] = c;
      if (!mounted) return;
      setState(() {});
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ControlScreen(controller: c, title: name)));
    } catch (e) {
      PacketLogger.I.log('연결 실패: $e');
      _toast('연결 실패: $e');
    }
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.bgPanel, elevation: 0, titleSpacing: 14,
        title: Row(children: [
          Container(width: 28, height: 28, alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFFFA24B), Color(0xFFFF6B00), Color(0xFFE0431A)]),
              borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.tune, color: Colors.white, size: 16)),
          const SizedBox(width: 8),
          const Text('LIGHT-BESPOKE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: AppColors.textPri)),
        ]),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 10),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.black),
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : const Icon(Icons.add, size: 16),
              label: const Text('PAIR', style: TextStyle(fontWeight: FontWeight.w800)))),
        ],
      ),
      body: Column(children: [
        Expanded(child: StreamBuilder<List<ScanResult>>(
          stream: FlutterBluePlus.scanResults, initialData: const [],
          builder: (context, snap) {
            // ★ 브랜드 과필터 제거: 스캔된 모든 기기를 표시(이름은 advName 우선)
            final results = (snap.data ?? []).toList()
              ..sort((a, b) => b.rssi.compareTo(a.rssi)); // 가까운 순
            if (results.isEmpty) {
              return Center(child: Text(_scanning ? '조명 검색 중...' : 'PAIR 로 BLE 기기를 검색하세요',
                  style: const TextStyle(color: AppColors.textSub, fontSize: 12)));
            }
            return ListView.separated(
              padding: const EdgeInsets.all(12), itemCount: results.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final r = results[i];
                final nm = _nameOf(r);
                final disp = nm.isEmpty ? '(이름 없음)' : nm;
                final brand = detectBrand(nm);          // null 이면 'BLE' 로 표시
                final connected = _connected.containsKey(r.device.remoteId.str);
                return _DeviceCard(
                  name: disp,
                  brand: brand ?? 'BLE', rssi: r.rssi, connected: connected,
                  onTap: () => connected
                      ? Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ControlScreen(controller: _connected[r.device.remoteId.str]!, title: disp)))
                      : _connect(r.device, nm));
              },
            );
          },
        )),
        const LogConsole(height: 180), // 홈에서도 패킷 로그 확인
      ]),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final String name, brand; final int rssi; final bool connected; final VoidCallback onTap;
  const _DeviceCard({required this.name, required this.brand, required this.rssi, required this.connected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bgCard, borderRadius: BorderRadius.circular(10),
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
            border: Border.all(color: connected ? AppColors.accentFx : AppColors.border)),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: connected ? AppColors.accentFx : AppColors.border2)),
            const SizedBox(width: 10),
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppColors.accent.withOpacity(0.12), borderRadius: BorderRadius.circular(3)),
              child: Text(brand.toUpperCase(), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.accent))),
            const SizedBox(width: 10),
            Expanded(child: Text(name, style: const TextStyle(color: AppColors.textPri, fontSize: 13), overflow: TextOverflow.ellipsis)),
            Text(connected ? '연결됨' : '$rssi dBm', style: TextStyle(fontSize: 11, color: connected ? AppColors.accentFx : AppColors.textSub)),
          ]),
        )),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  제어 화면 — CCT/HSI/Effect + 실시간 패킷 로그
// ─────────────────────────────────────────────────────────────────────────────
class ControlScreen extends StatelessWidget {
  final LightController controller;
  final String title;
  const ControlScreen({super.key, required this.controller, required this.title});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: AppColors.bgPanel, elevation: 0,
        title: Text(title.isEmpty ? controller.adapter.brand : title, style: const TextStyle(fontSize: 15, color: AppColors.textPri)),
        actions: [
          IconButton(tooltip: '전원 ON', onPressed: () => controller.setPower(true), icon: const Icon(Icons.power_settings_new, color: AppColors.accentFx)),
          IconButton(tooltip: '전원 OFF', onPressed: () => controller.setPower(false), icon: const Icon(Icons.power_off, color: AppColors.textSub)),
        ]),
      body: Column(children: [
        Expanded(child: Padding(
          padding: const EdgeInsets.all(14),
          child: LightControlPanel(
            onBrightness: controller.setBrightness,
            onCct: controller.setCct,
            onTint: (t) {},
            onHsi: controller.setHsi,
            onEffect: controller.setEffect),
        )),
        const LogConsole(height: 200),
      ]),
    );
  }
}

// 실시간 패킷 로그 콘솔
class LogConsole extends StatelessWidget {
  final double height;
  const LogConsole({super.key, this.height = 180});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: height, width: double.infinity,
      decoration: const BoxDecoration(color: Color(0xFF070707), border: Border(top: BorderSide(color: AppColors.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(children: [
            const Text('PACKET LOG', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.textFaint)),
            const Spacer(),
            InkWell(onTap: PacketLogger.I.clear, child: const Padding(padding: EdgeInsets.all(4),
              child: Text('CLEAR', style: TextStyle(fontSize: 9, color: AppColors.accent, fontWeight: FontWeight.w700)))),
          ])),
        Expanded(child: ValueListenableBuilder<List<String>>(
          valueListenable: PacketLogger.I.lines,
          builder: (_, lines, __) {
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              reverse: true, // 최신이 아래에 보이도록
              itemCount: lines.length,
              itemBuilder: (_, i) {
                final line = lines[lines.length - 1 - i];
                final isTx = line.contains('◀');
                return Text(line, style: TextStyle(
                  fontFamily: 'monospace', fontSize: 10.5, height: 1.5,
                  color: isTx ? AppColors.logGreen : AppColors.textSub));
              },
            );
          },
        )),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  제어 컴포넌트 (CCT / HSI / Effect)
// ─────────────────────────────────────────────────────────────────────────────
class LabeledSlider extends StatelessWidget {
  final String label, valueText;
  final double value;
  final ValueChanged<double> onChanged;
  final Gradient? trackGradient;
  final Color accent;
  const LabeledSlider({super.key, required this.label, required this.valueText, required this.value, required this.onChanged, this.trackGradient, this.accent = AppColors.accent});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(label, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.textFaint)),
          Text(valueText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: accent)),
        ])),
      Stack(alignment: Alignment.center, children: [
        if (trackGradient != null)
          Container(height: 5, margin: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(gradient: trackGradient, borderRadius: BorderRadius.circular(3))),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: trackGradient != null ? Colors.transparent : accent,
            inactiveTrackColor: trackGradient != null ? Colors.transparent : AppColors.bgSunken,
            thumbColor: accent),
          child: Slider(value: value.clamp(0, 1), onChanged: onChanged)),
      ]),
    ]);
  }
}

enum ControlMode { cct, hsi, effect }

class LightControlPanel extends StatefulWidget {
  final ValueChanged<int>? onBrightness;
  final ValueChanged<int>? onCct;
  final ValueChanged<double>? onTint;
  final void Function(double, double, double)? onHsi;
  final void Function(String, int, String)? onEffect;
  const LightControlPanel({super.key, this.onBrightness, this.onCct, this.onTint, this.onHsi, this.onEffect});
  @override
  State<LightControlPanel> createState() => _LightControlPanelState();
}

class _LightControlPanelState extends State<LightControlPanel> {
  ControlMode _mode = ControlMode.cct;
  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _ModeSegment(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
      const SizedBox(height: 12),
      Expanded(child: IndexedStack(index: _mode.index, children: [
        CctModeView(onBrightness: widget.onBrightness, onCct: widget.onCct, onTint: widget.onTint),
        HsiModeView(onHsi: widget.onHsi),
        EffectModeView(onEffect: widget.onEffect),
      ])),
    ]);
  }
}

class _ModeSegment extends StatelessWidget {
  final ControlMode mode; final ValueChanged<ControlMode> onChanged;
  const _ModeSegment({required this.mode, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    const labels = ['CCT MODE', 'HSI MODE', 'EFFECT MODE'];
    return Container(padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: AppColors.bgPanel, borderRadius: BorderRadius.circular(8)),
      child: Row(children: List.generate(3, (i) {
        final sel = mode.index == i;
        final accent = i == 2 ? AppColors.accentFx : AppColors.accent;
        return Expanded(child: GestureDetector(onTap: () => onChanged(ControlMode.values[i]),
          child: AnimatedContainer(duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 9), alignment: Alignment.center,
            decoration: BoxDecoration(color: sel ? AppColors.bgCard : Colors.transparent,
              borderRadius: BorderRadius.circular(6), border: Border.all(color: sel ? AppColors.border2 : Colors.transparent)),
            child: Text(labels[i], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: sel ? accent : AppColors.textSub)))));
      })));
  }
}

class CctModeView extends StatefulWidget {
  final ValueChanged<int>? onBrightness; final ValueChanged<int>? onCct; final ValueChanged<double>? onTint;
  const CctModeView({super.key, this.onBrightness, this.onCct, this.onTint});
  @override
  State<CctModeView> createState() => _CctModeViewState();
}

class _CctModeViewState extends State<CctModeView> {
  double _dim = 0.8; int _cct = 5600; double _tint = 0;
  static const _min = 2700, _max = 7500;
  @override
  Widget build(BuildContext context) {
    final norm = (_cct - _min) / (_max - _min);
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      LabeledSlider(label: 'DIM', valueText: '${(_dim * 100).round()}%', value: _dim,
        onChanged: (v) { setState(() => _dim = v); widget.onBrightness?.call((v * 100).round()); }),
      LabeledSlider(label: 'CCT', valueText: '${_cct}K', value: norm, accent: AppColors.cctCool,
        trackGradient: const LinearGradient(colors: [Color(0xFFFF8800), Color(0xFFFFFCE0), Color(0xFFAACCFF)]),
        onChanged: (v) { final k = (_min + v * (_max - _min)).round(); setState(() => _cct = k); widget.onCct?.call(k); }),
      LabeledSlider(label: 'G / M', valueText: _tint == 0 ? '0' : _tint.toStringAsFixed(2), value: (_tint + 1) / 2,
        trackGradient: const LinearGradient(colors: [Color(0xFF3BD16A), Color(0xFF888888), Color(0xFFE05AD0)]),
        onChanged: (v) { final t = v * 2 - 1; setState(() => _tint = t); widget.onTint?.call(t); }),
    ]);
  }
}

class HsiModeView extends StatefulWidget {
  final void Function(double, double, double)? onHsi;
  const HsiModeView({super.key, this.onHsi});
  @override
  State<HsiModeView> createState() => _HsiModeViewState();
}

class _HsiModeViewState extends State<HsiModeView> {
  double _hue = 77, _sat = 48, _int = 100;
  Color get _preview => HSVColor.fromAHSV(1, _hue, _sat / 100, 1).toColor();
  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      Container(height: 26, margin: const EdgeInsets.only(top: 6, bottom: 14),
        decoration: BoxDecoration(color: _preview, borderRadius: BorderRadius.circular(6))),
      Center(child: RepaintBoundary(child: ColorWheelPicker(hue: _hue, sat: _sat / 100, size: 220,
        onChanged: (h, s) { setState(() { _hue = h; _sat = s * 100; }); widget.onHsi?.call(_hue, _sat, _int); }))),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: _readout('H', '${_hue.round()}')),
        const SizedBox(width: 10),
        Expanded(child: _readout('S', '${_sat.round()}%')),
      ]),
    ]);
  }
  Widget _readout(String k, String v) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(color: AppColors.bgSunken, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
    child: Row(children: [Text('$k:', style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
      const Spacer(), Text(v, style: const TextStyle(color: AppColors.textPri, fontSize: 14, fontFamily: 'monospace'))]));
}

class ColorWheelPicker extends StatelessWidget {
  final double hue, sat, size;
  final void Function(double, double) onChanged;
  const ColorWheelPicker({super.key, required this.hue, required this.sat, required this.size, required this.onChanged});
  void _h(Offset p) {
    final r = size / 2; final dx = p.dx - r, dy = p.dy - r;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist > r) return;
    final deg = (math.atan2(dy, dx) * 180 / math.pi + 90 + 360) % 360;
    onChanged(deg, (dist / r).clamp(0, 1));
  }
  @override
  Widget build(BuildContext context) => GestureDetector(
    onPanDown: (d) => _h(d.localPosition), onPanUpdate: (d) => _h(d.localPosition),
    child: CustomPaint(size: Size.square(size), painter: _WheelPainter(hue, sat)));
}

class _WheelPainter extends CustomPainter {
  final double hue, sat;
  _WheelPainter(this.hue, this.sat);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero); final r = size.width / 2;
    final hues = List.generate(13, (i) => HSVColor.fromAHSV(1, (i * 30) % 360, 1, 1).toColor());
    canvas.drawCircle(c, r, Paint()..shader = SweepGradient(transform: const GradientRotation(-math.pi / 2), colors: hues).createShader(Rect.fromCircle(center: c, radius: r)));
    canvas.drawCircle(c, r, Paint()..shader = const RadialGradient(colors: [Colors.white, Color(0x00FFFFFF)]).createShader(Rect.fromCircle(center: c, radius: r)));
    final ang = (hue - 90) * math.pi / 180;
    final pos = c + Offset(math.cos(ang), math.sin(ang)) * (sat * r);
    canvas.drawCircle(pos, 9, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3);
    canvas.drawCircle(pos, 9, Paint()..color = HSVColor.fromAHSV(1, hue, sat, 1).toColor());
  }
  @override
  bool shouldRepaint(_WheelPainter o) => o.hue != hue || o.sat != sat;
}

class EffectModeView extends StatefulWidget {
  final void Function(String, int, String)? onEffect;
  const EffectModeView({super.key, this.onEffect});
  @override
  State<EffectModeView> createState() => _EffectModeViewState();
}

class _EffectModeViewState extends State<EffectModeView> {
  static const _fx = ['Hue Loop', 'CCT Loop', 'Flash', 'Pulse', 'Storm', 'Fire', 'TV', 'Cop Car'];
  static const _cy = ['ONE-WAY', 'TWO-WAY', 'REVERSE'];
  int _i = 0; double _speed = 0.4; int _c = 1;
  void _emit() => widget.onEffect?.call(_fx[_i], (_speed * 100).round(), _cy[_c]);
  void _step(int d) { setState(() => _i = (_i + d + _fx.length) % _fx.length); _emit(); }
  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
        _chev(Icons.chevron_left, () => _step(-1)),
        Expanded(child: Container(alignment: Alignment.center, padding: const EdgeInsets.symmetric(vertical: 10),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: AppColors.accentFx.withOpacity(0.08), borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.accentFx.withOpacity(0.35))),
          child: Text(_fx[_i], style: const TextStyle(color: Color(0xFF5FD07F), fontSize: 13, fontWeight: FontWeight.w800)))),
        _chev(Icons.chevron_right, () => _step(1)),
      ])),
      LabeledSlider(label: 'SPEED', valueText: '${(_speed * 100).round()}%', value: _speed, accent: AppColors.accentFx,
        onChanged: (v) { setState(() => _speed = v); _emit(); }),
      const Padding(padding: EdgeInsets.only(top: 14, bottom: 4),
        child: Text('CYCLE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: AppColors.textFaint))),
      Row(children: List.generate(3, (i) {
        final on = _c == i;
        return Expanded(child: Padding(padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
          child: GestureDetector(onTap: () { setState(() => _c = i); _emit(); },
            child: Container(alignment: Alignment.center, padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(color: on ? AppColors.accentFx.withOpacity(0.12) : AppColors.bgPanel,
                borderRadius: BorderRadius.circular(6), border: Border.all(color: on ? AppColors.accentFx : AppColors.border)),
              child: Text(_cy[i], style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: on ? const Color(0xFF6FD98A) : AppColors.textSub))))));
      })),
    ]);
  }
  Widget _chev(IconData ic, VoidCallback t) => GestureDetector(onTap: t,
    child: Container(width: 36, height: 36, decoration: BoxDecoration(color: AppColors.bgPanel,
      borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.border)),
      child: Icon(ic, color: AppColors.accentFx, size: 22)));
}
