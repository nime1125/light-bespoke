/* =====================================================================
   LIGHT-BESPOKE — BLE 3사 통합 프로토콜 (인터페이스 + 팩토리)
   ---------------------------------------------------------------------
   목적 : 브랜드(brandName)에 따라 서비스 UUID·캐릭터리스틱·Hex 패킷을
          동적 분기 생성. 기존 송신 흐름(writeBLE/dbSend/GATT/connectDev)
          과 기존 호출부(pktBr/pktCCT/pktRGB/pktFX)를 깨지 않음.
   사용 : app.html <script> 안, FDB/crc8M/nlS/xorS/hsl2rgb 정의 "다음"에
          이 블록을 붙여넣으면 됨. (기존 pktBr 등 정의는 삭제 → 아래 shim 사용)
   주의 : 각 adapter 의 verified=false 는 "실기기 HCI 캡처로 미확정"을 뜻함.
   ===================================================================== */
(function (global) {
  'use strict';

  /* 0) 공용 체크섬 — 기존 전역(crc8M/nlS/xorS)이 있으면 재사용, 없으면 정의 */
  const crc8Maxim = global.crc8M || function (buf) { let c = 0; for (const b of buf) { c ^= b; for (let i = 0; i < 8; i++) c = c & 1 ? (c >>> 1) ^ 0x8C : (c >>> 1); } return c & 0xFF; };
  const sum16be   = global.nlS   || function (buf) { let s = 0; for (const b of buf) s = (s + b) & 0xFFFF; return s; };
  const xor8      = global.xorS  || function (buf) { let x = 0; for (const b of buf) x ^= b; return x; };
  const sub8twos  = function (buf) { let s = 0; for (const b of buf) s += b; return (0x100 - (s & 0xFF)) & 0xFF; };
  const hsl2rgb   = global.hsl2rgb || function (h, s, l) { s /= 100; l /= 100; const k = n => (n + h / 30) % 12, a = s * Math.min(l, 1 - l); const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1))); return [Math.round(f(0) * 255), Math.round(f(8) * 255), Math.round(f(4) * 255)]; };

  const pctToByte = p => Math.round(Math.max(0, Math.min(100, p)) * 2.55) & 0xFF; // 0~100 → 0~255
  const clampPct  = p => Math.max(0, Math.min(100, Math.round(p)));

  /* 1) 프로토콜 사양(JSON, 데이터 주도) — 지난 분석 스키마와 호환 ----------- */
  const PROTO_SPEC = {
    godox: {
      brand: 'godox', service: '0000fff0-0000-1000-8000-00805f9b34fb',
      write: '0000fff1-0000-1000-8000-00805f9b34fb', notify: '0000fff2-0000-1000-8000-00805f9b34fb',
      checksum: 'crc8maxim', value_range: '0 to 255 (pct*2.55)', verified: false
    },
    nanlite: {
      brand: 'nanlite', service: '0000fff0-0000-1000-8000-00805f9b34fb',
      write: '0000fff1-0000-1000-8000-00805f9b34fb', notify: '0000fff2-0000-1000-8000-00805f9b34fb',
      checksum: 'sum16be', envelope: 'FA55 ... 0D0A', value_range: '0 to 255', verified: false
    },
    aputure: {
      brand: 'aputure', service: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
      write: '6e400002-b5a3-f393-e0a9-e50e24dcca9e', notify: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
      checksum: 'xor', value_range: '0 to 255', verified: false
    },
    /* 새로 HCI 분석한 6바이트 55 AA 패킷 (전원/밝기 확인 · 체크섬 미확정).
       service/write 는 실스캔으로 채워야 함. brandName 'captured55aa' 로 사용. */
    captured55aa: {
      brand: 'captured55aa', service: null, write: null, notify: null,
      checksum: 'sub8twos', packet_length_bytes: 6, header: [0x55, 0xAA],
      value_range: '0 to 100', verified: false
    }
  };

  /* 2) 인터페이스(추상 클래스) ----------------------------------------------
     모든 어댑터는 동일한 시그니처를 구현 → 호출부는 브랜드를 몰라도 됨. */
  class BrandProtocol {
    constructor(spec) { this.spec = spec || {}; }
    get service()   { return this.spec.service; }
    get writeUUID() { return this.spec.write; }
    get notifyUUID(){ return this.spec.notify; }
    get verified()  { return !!this.spec.verified; }
    checksum(/*bytes*/) { return []; }
    power(/*on*/)        { return []; }     // 전원 ON/OFF
    brightness(/*pct*/)  { return []; }     // 밝기 0~100
    cct(/*k,min,max*/)   { return []; }     // 색온도
    rgb(/*h,s,lum*/)     { return []; }     // 색(HSI→RGB)
    effect(/*fxId,speed,cy,ad*/) { return []; } // 효과
  }

  /* 3) 브랜드별 구현체 — 기존 app.html 의 pkt* 바이트 출력과 100% 동일 ------ */
  class GodoxProtocol extends BrandProtocol {
    checksum(b) { return crc8Maxim(b); }
    _wrap(payload) { return [0x01, ...payload, this.checksum(payload)]; }
    power(on)            { return this._wrap([0x06, 0x0c, on ? 0x01 : 0x00]); }
    brightness(pct)      { return this._wrap([0x02, 0x01, pctToByte(pct)]); }
    cct(k, mn, mx)       { return this._wrap([0x02, 0x02, Math.round(((k - mn) / (mx - mn)) * 255) & 0xFF]); }
    rgb(h, s, lum)       { const [r, g, b] = hsl2rgb(h, s, lum / 2); return this._wrap([0x05, r, g, b]); }
    effect(id, sp, cy, ad) { return this._wrap([0x07, id, pctToByte(sp), cy || 0, ad || 0]); }
  }

  class NanliteProtocol extends BrandProtocol {
    _frame(body) { const cs = sum16be(body); return [0xFA, 0x55, ...body, (cs >> 8) & 0xFF, cs & 0xFF, 0x0D, 0x0A]; }
    checksum(b) { return sum16be(b); }
    power(on)            { return this._frame([0x01, 0x00, 0x01, on ? 0x01 : 0x00]); }
    brightness(pct)      { return this._frame([0x01, 0x01, 0x00, pctToByte(pct)]); }
    cct(k, mn, mx)       { return this._frame([0x01, 0x02, 0x00, Math.round(((k - mn) / (mx - mn)) * 255) & 0xFF]); }
    rgb(h, s, lum)       { const [r, g, b] = hsl2rgb(h, s, lum / 2); return this._frame([0x03, 0x01, 0x00, r, 0x00, g, 0x00, b]); }
    effect(id, sp, cy, ad) { return this._frame([0x06, 0x01, 0x00, id, pctToByte(sp), cy || 0, ad || 0]); }
  }

  class AputureProtocol extends BrandProtocol {
    checksum(b) { return xor8(b); }
    _nus(body) { return [0x55, 0xAA, ...body, this.checksum(body)]; }
    power(on)            { return this._nus([0x07, 0x01, 0x00, on ? 0x01 : 0x00, 0x00, 0x00, 0x00]); }
    brightness(pct)      { return this._nus([0x07, 0x01, 0x01, pctToByte(pct), 0x00, 0x00, 0x00]); }
    cct(k, mn, mx)       { return this._nus([0x07, 0x01, 0x02, Math.round(((k - mn) / (mx - mn)) * 255) & 0xFF, 0x00, 0x00, 0x00]); }
    rgb(h, s, lum)       { const [r, g, b] = hsl2rgb(h, s, lum / 2); return this._nus([0x0A, 0x01, 0x08, r, g, b, 0x00, 0x00, 0x00, 0x00]); }
    effect(id, sp, cy, ad) { return this._nus([0x08, 0x01, 0x10, id, pctToByte(sp), cy || 0, ad || 0]); }
  }

  /* 새 55 AA 6바이트 프로토콜(전원/밝기 확정, 효과/CCT 미확보). 헤더 제외 본문 체크섬. */
  class Captured55aaProtocol extends BrandProtocol {
    checksum(body) { return sub8twos(body); }            // (0x100 - sum(body)) & 0xFF
    _pkt(body) { return [0x55, 0xAA, ...body, this.checksum(body)]; }
    power(on)       { return this._pkt([0x01, on ? 0x01 : 0x00, 0x00]); }
    brightness(pct) { return this._pkt([0x02, clampPct(pct), 0x00]); } // value = 퍼센트 그대로
    cct()    { return []; }   // 미분석
    rgb()    { return []; }   // 미분석
    effect() { return []; }   // 미분석
  }

  /* 4) 팩토리 — brandName 으로 어댑터 생성(캐시) ----------------------------- */
  const _impl = { godox: GodoxProtocol, nanlite: NanliteProtocol, aputure: AputureProtocol, captured55aa: Captured55aaProtocol };
  class BLEProtocolFactory {
    static create(brandName) {
      const b = String(brandName || '').toLowerCase();
      if (!this._cache) this._cache = {};
      if (this._cache[b]) return this._cache[b];
      const Cls = _impl[b] || AputureProtocol;          // 미지원 → 안전 기본값
      const spec = PROTO_SPEC[b] || PROTO_SPEC.aputure;
      return (this._cache[b] = new Cls(spec));
    }
    static spec(brandName) { return PROTO_SPEC[String(brandName || '').toLowerCase()] || null; }
  }

  /* 5) 기존 코드 호환 shim — 호출부 변경 없이 그대로 동작 --------------------- */
  global.pktBr   = (brand, pct)        => BLEProtocolFactory.create(brand).brightness(pct);
  global.pktCCT  = (brand, k, mn, mx)  => BLEProtocolFactory.create(brand).cct(k, mn, mx);
  global.pktRGB  = (brand, h, s, lum)  => BLEProtocolFactory.create(brand).rgb(h, s, lum);
  global.pktFX   = (brand, id, sp, cy, ad) => BLEProtocolFactory.create(brand).effect(id, sp, cy, ad);
  global.pktPower = (brand, on)        => BLEProtocolFactory.create(brand).power(on); // 신규(전원)

  /* 6) 연결부(connectDev) 분기 예시 — FDB[b].svc 대신 팩토리 사용 가능 -------
     const proto = BLEProtocolFactory.create(brand);
     const svc   = await server.getPrimaryService(proto.service);
     const tx    = await svc.getCharacteristic(proto.writeUUID);
     let rx; try { rx = await svc.getCharacteristic(proto.notifyUUID); } catch(_) {}
     ------------------------------------------------------------------------- */

  global.BLEProtocolFactory = BLEProtocolFactory;
  global.BrandProtocol = BrandProtocol;
  global.PROTO_SPEC = PROTO_SPEC;
  if (typeof module !== 'undefined' && module.exports) module.exports = { BLEProtocolFactory, BrandProtocol, PROTO_SPEC };
})(typeof window !== 'undefined' ? window : globalThis);
