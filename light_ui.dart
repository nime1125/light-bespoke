// =============================================================================
//  통합 조명 제어 — 반응형 프런트엔드 컴포넌트 (Flutter / Neo-Dark Theme)
//  -----------------------------------------------------------------------------
//  · 다크 미니멀 디자인 시스템(AppColors / NeoDarkTheme)
//  · 패널 진입 → 세그먼트 분기: CCT / HSI / Effect
//  · 2D 스테이지 맵(InteractiveViewer + CustomPainter, 드래그/회전, 탭→바텀시트)
//  · 슬라이더 onChanged 는 엔진(LightController.setBrightness 등)의
//    저지연 스로틀 콜백에 바인딩 — UI는 상태값만 갱신(스레드 오버헤드 최소).
//  · 성능: const 생성자 / RepaintBoundary / 셰이더 기반 컬러휠(픽셀 루프 없음).
// =============================================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 0) 디자인 토큰 & 테마 (Neo-Dark)
// ─────────────────────────────────────────────────────────────────────────────
class AppColors {
  static const bgApp     = Color(0xFF0A0A0A); // 최하단 배경
  static const bgPanel   = Color(0xFF0F0F0F); // 패널/탑바
  static const bgCard    = Color(0xFF161616); // 카드
  static const bgSunken  = Color(0xFF111111); // 슬라이더 트랙 베이스
  static const border    = Color(0xFF222222);
  static const border2   = Color(0xFF333333);
  static const textPri   = Color(0xFFDDE0EC);
  static const textSub   = Color(0xFF888888);
  static const textFaint = Color(0xFF3A3A3A);
  static const accent    = Color(0xFFFF6B00); // 오렌지(기본 강조)
  static const accentFx  = Color(0xFF46AA5F); // 그린(효과/선택 강조)
  static const cctCool   = Color(0xFF93C5FD); // 색온도 차가운쪽
}

class NeoDarkTheme {
  static ThemeData build() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bgApp,
      fontFamily: 'Pretendard', // 없으면 기본 폰트로 대체됨
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.accentFx,
        surface: AppColors.bgCard,
      ),
      sliderTheme: const SliderThemeData(
        trackHeight: 5,
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 9),
      ),
    );
  }
}

// 공통: 라벨 + 값 + 슬라이더 한 줄
class LabeledSlider extends StatelessWidget {
  final String label;
  final String valueText;
  final double value;       // 0~1 정규화
  final ValueChanged<double> onChanged;
  final Gradient? trackGradient; // CCT 등 그라디언트 트랙
  final Color accent;

  const LabeledSlider({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.onChanged,
    this.trackGradient,
    this.accent = AppColors.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(
                fontSize: 9, fontWeight: FontWeight.w700,
                letterSpacing: 1.2, color: AppColors.textFaint)),
              Text(valueText, style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700,
                fontFeatures: const [], color: accent)),
            ],
          ),
        ),
        // 그라디언트 트랙이 있으면 배경에 깔고 그 위에 투명 슬라이더
        Stack(alignment: Alignment.center, children: [
          if (trackGradient != null)
            Container(
              height: 5, margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                gradient: trackGradient,
                borderRadius: BorderRadius.circular(3)),
            ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: trackGradient != null ? Colors.transparent : accent,
              inactiveTrackColor: trackGradient != null ? Colors.transparent : AppColors.bgSunken,
              thumbColor: accent,
            ),
            child: Slider(value: value.clamp(0, 1), onChanged: onChanged),
          ),
        ]),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1) 제어 패널 — 세그먼트(CCT / HSI / Effect) 분기
// ─────────────────────────────────────────────────────────────────────────────
enum ControlMode { cct, hsi, effect }

class LightControlPanel extends StatefulWidget {
  // 엔진 콜백(예: controller.setBrightness). UI는 값만 넘기고 스로틀은 엔진이 처리.
  final ValueChanged<int>? onBrightness;       // 0~100
  final ValueChanged<int>? onCct;              // 켈빈
  final ValueChanged<double>? onTint;          // -1.0~+1.0
  final void Function(double hue, double sat, double intensity)? onHsi;
  final void Function(String effect, int speed, String cycle)? onEffect;

  const LightControlPanel({
    super.key, this.onBrightness, this.onCct, this.onTint, this.onHsi, this.onEffect,
  });

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
      // IndexedStack: 탭 전환 시 위젯 상태 보존 + 불필요한 재빌드/애니메이션 억제
      Expanded(child: IndexedStack(
        index: _mode.index,
        children: [
          CctModeView(onBrightness: widget.onBrightness, onCct: widget.onCct, onTint: widget.onTint),
          HsiModeView(onHsi: widget.onHsi),
          EffectModeView(onEffect: widget.onEffect),
        ],
      )),
    ]);
  }
}

// 커스텀 세그먼트 컨트롤(CCT MODE / HSI MODE / EFFECT MODE)
class _ModeSegment extends StatelessWidget {
  final ControlMode mode;
  final ValueChanged<ControlMode> onChanged;
  const _ModeSegment({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const labels = ['CCT MODE', 'HSI MODE', 'EFFECT MODE'];
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.bgPanel, borderRadius: BorderRadius.circular(8)),
      child: Row(children: List.generate(3, (i) {
        final selected = mode.index == i;
        final accent = i == 2 ? AppColors.accentFx : AppColors.accent;
        return Expanded(child: GestureDetector(
          onTap: () => onChanged(ControlMode.values[i]),
          child: AnimatedContainer( // 짧은 색 전이만(부하 적음)
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? AppColors.bgCard : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: selected ? AppColors.border2 : Colors.transparent),
            ),
            child: Text(labels[i], style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700,
              color: selected ? accent : AppColors.textSub)),
          ),
        ));
      })),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2) CCT 모드 뷰 — DIM / CCT / G·M
// ─────────────────────────────────────────────────────────────────────────────
class CctModeView extends StatefulWidget {
  final ValueChanged<int>? onBrightness;
  final ValueChanged<int>? onCct;
  final ValueChanged<double>? onTint;
  const CctModeView({super.key, this.onBrightness, this.onCct, this.onTint});

  @override
  State<CctModeView> createState() => _CctModeViewState();
}

class _CctModeViewState extends State<CctModeView> {
  double _dim = 0.8;   // 0~1
  int _cct = 5600;     // K
  double _tint = 0.0;  // -1~+1
  static const _cctMin = 2700, _cctMax = 7500;

  @override
  Widget build(BuildContext context) {
    final cctNorm = (_cct - _cctMin) / (_cctMax - _cctMin);
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      LabeledSlider(
        label: 'DIM', valueText: '${(_dim * 100).round()}%', value: _dim,
        onChanged: (v) { setState(() => _dim = v); widget.onBrightness?.call((v * 100).round()); },
      ),
      LabeledSlider(
        label: 'CCT', valueText: '${_cct}K', value: cctNorm,
        accent: AppColors.cctCool,
        trackGradient: const LinearGradient(colors: [
          Color(0xFFFF8800), Color(0xFFFFFCE0), Color(0xFFAACCFF)]),
        onChanged: (v) {
          final k = (_cctMin + v * (_cctMax - _cctMin)).round();
          setState(() => _cct = k); widget.onCct?.call(k);
        },
      ),
      LabeledSlider(
        label: 'G / M', valueText: _tint == 0 ? '0' : (_tint > 0 ? '+${_tint.toStringAsFixed(2)}' : _tint.toStringAsFixed(2)),
        value: (_tint + 1) / 2, // -1~1 → 0~1
        trackGradient: const LinearGradient(colors: [
          Color(0xFF3BD16A), Color(0xFF888888), Color(0xFFE05AD0)]),
        onChanged: (v) { final t = v * 2 - 1; setState(() => _tint = t); widget.onTint?.call(t); },
      ),
    ]);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3) HSI 모드 뷰 — 컬러 프리뷰 바 / 컬러휠 / 수치 입력
// ─────────────────────────────────────────────────────────────────────────────
class HsiModeView extends StatefulWidget {
  final void Function(double hue, double sat, double intensity)? onHsi;
  const HsiModeView({super.key, this.onHsi});

  @override
  State<HsiModeView> createState() => _HsiModeViewState();
}

class _HsiModeViewState extends State<HsiModeView> {
  double _hue = 77, _sat = 48, _int = 100;
  late final TextEditingController _hCtrl = TextEditingController(text: '77');
  late final TextEditingController _sCtrl = TextEditingController(text: '48');

  Color get _preview => HSVColor.fromAHSV(1, _hue, _sat / 100, 1).toColor();

  void _emit() => widget.onHsi?.call(_hue, _sat, _int);

  @override
  void dispose() { _hCtrl.dispose(); _sCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      // 실시간 컬러 프리뷰 바
      Container(height: 26, margin: const EdgeInsets.only(top: 6, bottom: 14),
        decoration: BoxDecoration(color: _preview, borderRadius: BorderRadius.circular(6))),
      // 컬러휠
      Center(child: RepaintBoundary(child: ColorWheelPicker(
        hue: _hue, sat: _sat / 100, size: 220,
        onChanged: (h, s) {
          setState(() { _hue = h; _sat = s * 100;
            _hCtrl.text = h.round().toString(); _sCtrl.text = (s * 100).round().toString(); });
          _emit();
        },
      ))),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _NumField(label: 'H', ctrl: _hCtrl, max: 360,
          onSubmit: (v) { setState(() => _hue = v.clamp(0, 360)); _emit(); })),
        const SizedBox(width: 10),
        Expanded(child: _NumField(label: 'S', ctrl: _sCtrl, max: 100,
          onSubmit: (v) { setState(() => _sat = v.clamp(0, 100)); _emit(); })),
      ]),
    ]);
  }
}

// 수치 입력 필드(H/S)
class _NumField extends StatelessWidget {
  final String label; final TextEditingController ctrl; final double max;
  final ValueChanged<double> onSubmit;
  const _NumField({required this.label, required this.ctrl, required this.max, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: AppColors.bgSunken,
        borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.border)),
      child: Row(children: [
        Text('$label:', style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
        Expanded(child: TextField(
          controller: ctrl, keyboardType: TextInputType.number, textAlign: TextAlign.right,
          style: const TextStyle(color: AppColors.textPri, fontSize: 14),
          decoration: const InputDecoration(border: InputBorder.none, isDense: true),
          onSubmitted: (s) => onSubmit((double.tryParse(s) ?? 0).clamp(0, max)),
        )),
      ]),
    );
  }
}

// 원형 HSV 컬러휠 픽커 — SweepGradient(색상) + RadialGradient(채도) 셰이더로 경량 렌더
class ColorWheelPicker extends StatelessWidget {
  final double hue;     // 0~360
  final double sat;     // 0~1
  final double size;
  final void Function(double hue, double sat) onChanged;
  const ColorWheelPicker({super.key, required this.hue, required this.sat, required this.size, required this.onChanged});

  void _handle(Offset local) {
    final r = size / 2;
    final dx = local.dx - r, dy = local.dy - r;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist > r) return;
    var deg = (math.atan2(dy, dx) * 180 / math.pi + 90 + 360) % 360;
    onChanged(deg, (dist / r).clamp(0, 1));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: (d) => _handle(d.localPosition),
      onPanUpdate: (d) => _handle(d.localPosition),
      child: CustomPaint(size: Size.square(size), painter: _WheelPainter(hue, sat)),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final double hue, sat;
  _WheelPainter(this.hue, this.sat);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero); final r = size.width / 2;
    // 색상환(SweepGradient)
    final hueColors = List.generate(13, (i) => HSVColor.fromAHSV(1, (i * 30) % 360, 1, 1).toColor());
    canvas.drawCircle(c, r, Paint()..shader = SweepGradient(
      transform: const GradientRotation(-math.pi / 2), colors: hueColors).createShader(Rect.fromCircle(center: c, radius: r)));
    // 채도(중앙 흰색 → 가장자리 투명)
    canvas.drawCircle(c, r, Paint()..shader = RadialGradient(
      colors: const [Colors.white, Color(0x00FFFFFF)]).createShader(Rect.fromCircle(center: c, radius: r)));
    // 현재 선택 위치 크로스헤어
    final ang = (hue - 90) * math.pi / 180;
    final pos = c + Offset(math.cos(ang), math.sin(ang)) * (sat * r);
    canvas.drawCircle(pos, 9, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3);
    canvas.drawCircle(pos, 9, Paint()..color = HSVColor.fromAHSV(1, hue, sat, 1).toColor());
  }

  // 색상환 자체는 정적 → 선택점만 바뀌므로 hue/sat 변동 시에만 재페인트
  @override
  bool shouldRepaint(_WheelPainter old) => old.hue != hue || old.sat != sat;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4) Effect 모드 뷰 — 효과 캐러셀 / Speed / Cycle
// ─────────────────────────────────────────────────────────────────────────────
class EffectModeView extends StatefulWidget {
  final void Function(String effect, int speed, String cycle)? onEffect;
  const EffectModeView({super.key, this.onEffect});

  @override
  State<EffectModeView> createState() => _EffectModeViewState();
}

class _EffectModeViewState extends State<EffectModeView> {
  static const _effects = ['Hue Loop', 'CCT Loop', 'Flash', 'Pulse', 'Storm', 'Fire', 'TV', 'Cop Car'];
  static const _cycles = ['ONE-WAY', 'TWO-WAY', 'REVERSE'];
  int _fx = 0; double _speed = 0.4; int _cycle = 1;

  void _emit() => widget.onEffect?.call(_effects[_fx], (_speed * 100).round(), _cycles[_cycle]);
  void _step(int d) { setState(() => _fx = (_fx + d + _effects.length) % _effects.length); _emit(); }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
      // 효과 캐러셀(좌우 chevron + 이름)
      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
        _chevron(Icons.chevron_left, () => _step(-1)),
        Expanded(child: Container(
          alignment: Alignment.center, padding: const EdgeInsets.symmetric(vertical: 10),
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: AppColors.accentFx.withOpacity(0.08),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: AppColors.accentFx.withOpacity(0.35))),
          child: Text(_effects[_fx], style: const TextStyle(
            color: Color(0xFF5FD07F), fontSize: 13, fontWeight: FontWeight.w800)),
        )),
        _chevron(Icons.chevron_right, () => _step(1)),
      ])),
      LabeledSlider(
        label: 'SPEED', valueText: '${(_speed * 100).round()}%', value: _speed,
        accent: AppColors.accentFx,
        onChanged: (v) { setState(() => _speed = v); _emit(); },
      ),
      const Padding(padding: EdgeInsets.only(top: 14, bottom: 4),
        child: Text('CYCLE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
          letterSpacing: 1.2, color: AppColors.textFaint))),
      Row(children: List.generate(3, (i) {
        final on = _cycle == i;
        return Expanded(child: Padding(
          padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
          child: GestureDetector(
            onTap: () { setState(() => _cycle = i); _emit(); },
            child: Container(
              alignment: Alignment.center, padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: on ? AppColors.accentFx.withOpacity(0.12) : AppColors.bgPanel,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: on ? AppColors.accentFx : AppColors.border)),
              child: Text(_cycles[i], style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                color: on ? const Color(0xFF6FD98A) : AppColors.textSub)),
            ),
          ),
        ));
      })),
    ]);
  }

  Widget _chevron(IconData icon, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(width: 36, height: 36,
      decoration: BoxDecoration(color: AppColors.bgPanel,
        borderRadius: BorderRadius.circular(9), border: Border.all(color: AppColors.border)),
      child: Icon(icon, color: AppColors.accentFx, size: 22)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// 5) 2D 스테이지 맵 — InteractiveViewer + CustomPainter, 드래그/회전, 탭→바텀시트
// ─────────────────────────────────────────────────────────────────────────────
enum NodeType { light, camera, subject, background }

class StageNode {
  final String id;
  NodeType type;
  Offset pos;       // 캔버스 좌표
  double angle;     // 방향각(라디안) — 조명용
  Color color;
  String label;
  StageNode({required this.id, required this.type, required this.pos,
    this.angle = 0, this.color = AppColors.accent, this.label = ''});
}

class StageMapView extends StatefulWidget {
  // 노드 탭 시 열릴 제어 패널(보통 LightControlPanel 을 넘김)
  final Widget Function(StageNode node) controlBuilder;
  final List<StageNode> initialNodes;
  const StageMapView({super.key, required this.controlBuilder, this.initialNodes = const []});

  @override
  State<StageMapView> createState() => _StageMapViewState();
}

class _StageMapViewState extends State<StageMapView> {
  late List<StageNode> _nodes = [...widget.initialNodes];

  void _openControl(StageNode node) {
    showModalBottomSheet(
      context: context, backgroundColor: AppColors.bgCard, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 40, height: 4, alignment: Alignment.center,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(color: AppColors.border2, borderRadius: BorderRadius.circular(2))),
            Text(node.label.isEmpty ? node.type.name.toUpperCase() : node.label,
              style: const TextStyle(color: AppColors.textPri, fontWeight: FontWeight.w800, fontSize: 15)),
            // 조명이면 방향각 회전 슬라이더 제공
            if (node.type == NodeType.light)
              LabeledSlider(label: 'ANGLE', valueText: '${(node.angle * 180 / math.pi).round()}°',
                value: (node.angle % (2 * math.pi)) / (2 * math.pi),
                onChanged: (v) => setState(() => node.angle = v * 2 * math.pi)),
            const SizedBox(height: 8),
            Expanded(child: widget.controlBuilder(node)), // 상단 BLE 파라미터 제어창
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 가로/세로 모드 모두 대응 — 캔버스는 고정 크기, InteractiveViewer 로 팬·줌
    return ColoredBox(
      color: AppColors.bgApp,
      child: InteractiveViewer(
        minScale: 0.5, maxScale: 3.0, boundaryMargin: const EdgeInsets.all(400),
        child: SizedBox(
          width: 1200, height: 1200,
          child: Stack(children: [
            // 바닥 격자(정적 → shouldRepaint=false)
            const Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _GridPainter()))),
            // 노드들(드래그/탭)
            ..._nodes.map((n) => Positioned(
              left: n.pos.dx, top: n.pos.dy,
              child: GestureDetector(
                onTap: () => _openControl(n),
                onPanUpdate: (d) => setState(() => n.pos += d.delta),
                child: _NodeWidget(node: n),
              ),
            )),
          ]),
        ),
      ),
    );
  }
}

class _NodeWidget extends StatelessWidget {
  final StageNode node;
  const _NodeWidget({required this.node});

  IconData get _icon => switch (node.type) {
    NodeType.light => Icons.wb_incandescent,
    NodeType.camera => Icons.videocam,
    NodeType.subject => Icons.person,
    NodeType.background => Icons.crop_landscape,
  };

  @override
  Widget build(BuildContext context) {
    final isLight = node.type == NodeType.light;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Transform.rotate(
        angle: isLight ? node.angle : 0,
        child: Container(
          width: 44, height: 44, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.bgCard, shape: BoxShape.circle,
            border: Border.all(color: isLight ? node.color : AppColors.border2, width: 2)),
          child: Icon(_icon, color: isLight ? node.color : AppColors.textSub, size: 22),
        ),
      ),
      if (node.label.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 2),
          child: Text(node.label, style: const TextStyle(color: AppColors.textSub, fontSize: 9))),
    ]);
  }
}

// 바닥 격자 그리기(정적)
class _GridPainter extends CustomPainter {
  const _GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFF181818)..strokeWidth = 1;
    const step = 48.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }
  @override
  bool shouldRepaint(_) => false; // 정적 → 재페인트 없음
}
