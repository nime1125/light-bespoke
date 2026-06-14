// =============================================================================
//  통합 촬영 조명 제어 엔진 — Flutter / flutter_blue_plus (Clean Architecture)
//  -----------------------------------------------------------------------------
//  · 추상 인터페이스(LightAdapter) ← Godox / Nanlite / Aputure 어댑터(플러그인)
//  · 외부 동글 없이 폰 내장 BLE 로 다이렉트 GATT writeWithoutResponse
//  · 저지연 코얼레싱 큐: 구형 명령 즉시 드롭, 최신 1개만 35ms 인터벌로 송출
//  · 무음 동기화(Silent Sync): (재)연결 직후 마지막 상태 1회 주입 → 상태 튐 차단
//  · 지수 백오프(1·2·4·8s) 무중단 자동 재연결
//
//  pubspec.yaml:
//    flutter_blue_plus: ^1.32.0
//    shared_preferences: ^2.2.0
//
//  ⚠ 신뢰도: Godox 전원/밝기 = 제공 스펙(verified). CCT/HSI/Effect 및
//     Nanlite/Aputure 의 일부는 best-effort(verified=false) — HCI 캡처로 교정.
// =============================================================================

import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1) 공통 인터페이스 (Abstract Adapter)
//    CCT/HSI/Effect 는 기본 빈 배열(미지원) → 어댑터가 선택적으로 override.
// ─────────────────────────────────────────────────────────────────────────────
abstract class LightAdapter {
  String get brand;
  String get serviceUuid;
  String get characteristicUuid;
  String? get notifyUuid => null;
  bool get verified;
  bool get preferWriteWithoutResponse => true;

  List<int> encodePower(bool isOn);
  List<int> encodeBrightness(int percentage);

  // 확장 채널(미구현 시 빈 배열 → 컨트롤러가 송신 생략)
  List<int> encodeCct(int kelvin) => const [];
  List<int> encodeHsi(double hue, double sat, double intensity) => const [];
  List<int> encodeEffect(String effect, int speed, String cycle) => const [];

  int clampPct(int p) => p < 0 ? 0 : (p > 100 ? 100 : p);
}

// ─────────────────────────────────────────────────────────────────────────────
// 2) 체크섬 유틸 — 정적 함수(중간 객체 생성 없음)
// ─────────────────────────────────────────────────────────────────────────────
class Checksum {
  static int sumLow(List<int> bytes) {
    int s = 0;
    for (final b in bytes) s += b;
    return s & 0xFF;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3) 브랜드별 구체 어댑터
// ─────────────────────────────────────────────────────────────────────────────

/// ── Godox ─ GATT Write + 합산&0xFF 체크섬 (전원/밝기 verified) ───────────────
class GodoxAdapter extends LightAdapter {
  @override String get brand => 'Godox';
  @override String get serviceUuid => '0000fff0-0000-1000-8000-00805f9b34fb';
  @override String get characteristicUuid => '0000fff1-0000-1000-8000-00805f9b34fb';
  @override bool get verified => true;

  static const List<int> _powerOn  = [0x55, 0xAA, 0x01, 0x01, 0x00, 0xFE];
  static const List<int> _powerOff = [0x55, 0xAA, 0x01, 0x00, 0x00, 0xFF];

  List<int> _frame(int cmd, int value) {
    final body = [0x55, 0xAA, cmd, value & 0xFF, 0x00];
    return [...body, Checksum.sumLow(body)];
  }

  @override List<int> encodePower(bool isOn) => isOn ? _powerOn : _powerOff;

  // 밝기: [0x55,0xAA,0x02, pct, 0x00, sum] — 예) 100% → 55 AA 02 64 00 65
  @override List<int> encodeBrightness(int percentage) => _frame(0x02, clampPct(percentage));

  // 이하 best-effort(미검증): 동일 프레임 패턴으로 cmd 분기. HCI 캡처로 교정 필요.
  @override List<int> encodeCct(int kelvin) =>
      _frame(0x03, (((kelvin - 2700) / (7500 - 2700)) * 255).round().clamp(0, 255));
  @override List<int> encodeHsi(double hue, double sat, double intensity) =>
      _frame(0x04, (hue / 360 * 255).round().clamp(0, 255)); // 단순화(색조만)
}

/// ── Nanlite ─ 8바이트 시리얼 스트림. 파라미터 코드는 문서화된 표 기준 ─────────
/// optionCode: 밝기 0x01, CCT 0x03, Hue 0x05, Sat 0x0C
class NanliteAdapter extends LightAdapter {
  @override String get brand => 'Nanlite';
  @override String get serviceUuid => '0003cdd0-0000-1000-8000-00805f9b0131';
  @override String get characteristicUuid => '0003cdd2-0000-1000-8000-00805f9b0131';
  @override String? get notifyUuid => '0003cdd1-0000-1000-8000-00805f9b0131';
  @override bool get verified => false;

  // [0x03,0x20, opt, 0x01, valHi, valLo, 0x00,0x04]
  List<int> _stream(int opt, int value16) =>
      [0x03, 0x20, opt, 0x01, (value16 >> 8) & 0xFF, value16 & 0xFF, 0x00, 0x04];

  // 제공 스펙 그대로(밝기): [0x03,0x20,0x01,0x01,0x00,pct,0x00,0x04]
  @override List<int> encodeBrightness(int percentage) =>
      [0x03, 0x20, 0x01, 0x01, 0x00, clampPct(percentage), 0x00, 0x04];

  @override List<int> encodePower(bool isOn) => encodeBrightness(isOn ? 100 : 0);
  @override List<int> encodeCct(int kelvin) => _stream(0x03, kelvin);
  @override List<int> encodeHsi(double hue, double sat, double intensity) =>
      _stream(0x05, hue.round()); // Hue 채널(채도는 0x0C 별도 전송 권장)
}

/// ── Aputure / Amaran (Sidus Mesh) ─ placeholder 프레임(미검증) ──────────────
class AputureAdapter extends LightAdapter {
  final int nodeId;
  AputureAdapter({this.nodeId = 0x00});

  @override String get brand => 'Aputure';
  @override String get serviceUuid => '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  @override String get characteristicUuid => '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  @override String? get notifyUuid => '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  @override bool get verified => false;

  List<int> _mesh(int command, List<int> payload) {
    final header = [0x55, 0xAA, nodeId & 0xFF, command & 0xFF, payload.length & 0xFF];
    int xor = 0;
    for (final b in header) xor ^= b;
    for (final b in payload) xor ^= b;
    return [...header, ...payload, xor & 0xFF];
  }

  @override List<int> encodePower(bool isOn) => _mesh(0x01, [isOn ? 0x01 : 0x00]);
  @override List<int> encodeBrightness(int percentage) => _mesh(0x02, [clampPct(percentage)]);
  @override List<int> encodeCct(int kelvin) => _mesh(0x03, [(kelvin >> 8) & 0xFF, kelvin & 0xFF]);
  @override List<int> encodeHsi(double hue, double sat, double intensity) =>
      _mesh(0x04, [(hue.round() >> 8) & 0xFF, hue.round() & 0xFF, sat.round() & 0xFF]);
}

// ─────────────────────────────────────────────────────────────────────────────
// 4) 팩토리
// ─────────────────────────────────────────────────────────────────────────────
class AdapterFactory {
  static LightAdapter create(String brand, {int aputureNodeId = 0x00}) {
    switch (brand.toLowerCase()) {
      case 'godox':   return GodoxAdapter();
      case 'nanlite': return NanliteAdapter();
      case 'aputure':
      case 'amaran':  return AputureAdapter(nodeId: aputureNodeId);
      default: throw ArgumentError('지원하지 않는 브랜드: $brand');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5) 기기 상태 메모리 테이블(로컬 영속화) — 무음 동기화의 원천
// ─────────────────────────────────────────────────────────────────────────────
class DeviceState {
  int brightness; // 0~100
  int cct;        // K
  double hue, sat;
  bool isOn;
  DeviceState({this.brightness = 100, this.cct = 5600, this.hue = 0, this.sat = 0, this.isOn = true});
}

class LightStateStore {
  static String _key(String id) => 'lightstate_$id';
  static Future<void> save(String id, DeviceState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key(id), '${s.isOn ? 1 : 0}|${s.brightness}|${s.cct}|${s.hue.round()}|${s.sat.round()}');
  }
  static Future<DeviceState?> load(String id) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key(id));
    if (raw == null) return null;
    final v = raw.split('|');
    if (v.length < 2) return null;
    return DeviceState(
      isOn: v[0] == '1',
      brightness: int.tryParse(v[1]) ?? 100,
      cct: v.length > 2 ? (int.tryParse(v[2]) ?? 5600) : 5600,
      hue: v.length > 3 ? (double.tryParse(v[3]) ?? 0) : 0,
      sat: v.length > 4 ? (double.tryParse(v[4]) ?? 0) : 0,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6) 통합 컨트롤러 — 연결 / 무음 동기화 / 코얼레싱 큐 송신 / 자동 재연결
// ─────────────────────────────────────────────────────────────────────────────
class LightController {
  final BluetoothDevice device;
  final LightAdapter adapter;
  final int sendIntervalMs;

  BluetoothCharacteristic? _writeChar;
  bool _writeNoResponse = false;
  DeviceState _state = DeviceState();

  // ── 코얼레싱 큐: '가장 최근 인코딩 동작 1개'만 보관(구형은 덮어써져 드롭) ──
  List<int> Function()? _pendingEncode;
  bool _flushScheduled = false;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);

  // 진단용 카운터(테스트/모니터링)
  int enqueuedCount = 0; // 요청 누적
  int sentCount = 0;     // 실제 송신 누적(= 드롭 후 살아남은 최신 패킷 수)

  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<BluetoothConnectionState>? _connSub;
  bool _manualDisconnect = false;
  int _reconnectAttempt = 0;
  static const List<int> _backoffSec = [1, 2, 4, 8];

  LightController(this.device, this.adapter, {this.sendIntervalMs = 35});

  String get _id => device.remoteId.str;

  // ─── 연결 + 탐색 + 무음 동기화 ──────────────────────────────────────────────
  Future<void> connect() async {
    _manualDisconnect = false;
    _listenConnectionState();
    await device.connect(timeout: const Duration(seconds: 10), autoConnect: false);
    await _discover();
    await _silentSync();
    _reconnectAttempt = 0;
  }

  Future<void> _discover() async {
    final services = await device.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == Guid(adapter.serviceUuid),
      orElse: () => throw StateError('서비스 없음: ${adapter.serviceUuid}'),
    );
    final ch = svc.characteristics.firstWhere(
      (c) => c.uuid == Guid(adapter.characteristicUuid),
      orElse: () => throw StateError('캐릭터리스틱 없음: ${adapter.characteristicUuid}'),
    );
    _writeChar = ch;
    _writeNoResponse = adapter.preferWriteWithoutResponse && ch.properties.writeWithoutResponse;
  }

  Future<void> _silentSync() async {
    final saved = await LightStateStore.load(_id);
    if (saved == null) return;
    _state = saved;
    final pkt = saved.isOn ? adapter.encodeBrightness(saved.brightness) : adapter.encodePower(false);
    await _writeRaw(pkt);
  }

  // ─── 코얼레싱 큐 핵심 ────────────────────────────────────────────────────────
  /// 연속 제어(밝기/CCT/HSI)는 이 큐를 통해 최신 1개만 인터벌로 송출.
  void _enqueue(List<int> Function() encode) {
    enqueuedCount++;
    _pendingEncode = encode; // 이전 대기분 즉시 폐기(드롭)
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
    final bytes = encode(); // 전송 직전 '1회만' 인코딩(폐기분은 인코딩조차 안 함)
    if (bytes.isNotEmpty) { await _writeRaw(bytes); sentCount++; }
    _persist();
    if (_pendingEncode != null) _scheduleFlush();
  }

  // ─── 연속 제어 API (슬라이더/휠이 매 프레임 호출) ────────────────────────────
  void setBrightness(int percentage) {
    final p = adapter.clampPct(percentage);
    _state.brightness = p; if (p > 0) _state.isOn = true;
    _enqueue(() => adapter.encodeBrightness(p));
  }

  void setCct(int kelvin) {
    _state.cct = kelvin;
    _enqueue(() => adapter.encodeCct(kelvin));
  }

  void setHsi(double hue, double sat, double intensity) {
    _state.hue = hue; _state.sat = sat;
    _enqueue(() => adapter.encodeHsi(hue, sat, intensity));
  }

  // ─── 단발성 제어(스로틀 불필요) ──────────────────────────────────────────────
  Future<void> setPower(bool isOn) async {
    _state.isOn = isOn;
    await _writeRaw(adapter.encodePower(isOn));
    _persist();
  }

  Future<void> setEffect(String effect, int speed, String cycle) async {
    final bytes = adapter.encodeEffect(effect, speed, cycle);
    if (bytes.isNotEmpty) await _writeRaw(bytes);
  }

  Future<void> _writeRaw(List<int> bytes) async {
    final ch = _writeChar;
    if (ch == null || bytes.isEmpty) return;
    try {
      await ch.write(bytes, withoutResponse: _writeNoResponse);
    } catch (_) {/* 연결 유실 신호 → 재연결 핸들러가 처리 */}
  }

  void _persist() {
    final now = DateTime.now();
    if (now.difference(_lastSave).inMilliseconds < 500) return;
    _lastSave = now;
    LightStateStore.save(_id, _state);
  }

  // ─── 지수 백오프 자동 재연결(UI 비차단) ─────────────────────────────────────
  void _listenConnectionState() {
    _connSub?.cancel();
    _connSub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && !_manualDisconnect) _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    final idx = _reconnectAttempt < _backoffSec.length ? _reconnectAttempt : _backoffSec.length - 1;
    final delay = _backoffSec[idx];
    _reconnectAttempt++;
    Future.delayed(Duration(seconds: delay), () async {
      if (_manualDisconnect) return;
      try {
        await device.connect(timeout: const Duration(seconds: 10), autoConnect: false);
        await _discover();
        await _silentSync();
        _reconnectAttempt = 0;
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
