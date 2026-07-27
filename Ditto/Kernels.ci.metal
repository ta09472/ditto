#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

extern "C" {

static float3 rgb2ycbcr(float3 c) {
    float y  = dot(c, float3(0.299, 0.587, 0.114));
    return float3(y, (c.b - y) * 0.565, (c.r - y) * 0.713);
}

static float3 ycbcr2rgb(float3 v) {
    float y = v.x, cb = v.y, cr = v.z;
    return float3(y + 1.403 * cr,
                  y - 0.344 * cb - 0.714 * cr,
                  y + 1.770 * cb);
}

// 2000년대 CCD 캠코더/디지캠 룩. 입력은 이미 저해상도로 다운샘플된 상태.
// 리서치 기반 패스: 색수차 → 크로마 서브샘플링 블리딩 → 톤커브(하이라이트 클립,
// 들뜬 블랙) → WB 색캐스트 → 블룸 → 루마 가중 CCD 노이즈 → 비네트
coreimage::float4 dittoLook(coreimage::sampler src, float grainSeed,
                            coreimage::destination dest) {
    float2 coord = dest.coord();
    float2 size = src.size();
    float2 uv = coord / size;
    float2 center = size * 0.5;

    // 색수차: R/B를 중심 기준 방사형 반대방향 오프셋, 가장자리로 갈수록 증가
    float2 dir = coord - center;
    float dist2 = dot(dir / size, dir / size);
    float2 caOff = dir * dist2 * 0.02;
    float r = src.sample(src.transform(coord + caOff)).r;
    float3 gb = src.sample(src.transform(coord - caOff * 0.5)).rgb;
    float3 c = float3(r, gb.g, gb.b);

    // 크로마 서브샘플링(4:1:1) 색번짐: Cb/Cr만 가로 box blur, 루마는 유지
    float3 ycc = rgb2ycbcr(c);
    float2 chroma = float2(0.0);
    for (int i = -2; i <= 2; i++) {
        float3 s = src.sample(src.transform(coord + float2(i * 2.0, 0.0))).rgb;
        chroma += rgb2ycbcr(s).yz;
    }
    ycc.yz = chroma / 5.0;

    // 채도 살짝 낮춤 (CCD 특유의 물빠진 색)
    ycc.yz *= 0.82;
    c = ycbcr2rgb(ycc);

    // 하이라이트 블룸: 밝은 부분이 부드럽게 번짐 (저가 렌즈 + CCD glow)
    float3 bloom = float3(0.0);
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float3 s = src.sample(src.transform(coord + float2(i, j) * 2.5)).rgb;
            bloom += max(s - 0.7, 0.0);
        }
    }
    c += bloom / 25.0 * 1.1;

    // 톤커브: 좁은 DR — 0.88부터 하이라이트 소프트클립, 블랙 리프트(뭉개진 섀도우)
    float3 hi = smoothstep(0.88, 1.0, c);
    c = mix(c, float3(1.0), hi * hi);
    c = c * 0.93 + 0.045;

    // WB 편향 색캐스트: 섀도우에 시안/틸, 하이라이트에 웜옐로
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    float3 shadowTint = float3(0.94, 1.0, 1.03);
    float3 hiTint = float3(1.03, 1.01, 0.95);
    c *= mix(shadowTint, hiTint, smoothstep(0.2, 0.8, luma));
    c = pow(clamp(c, 0.0, 1.0), float3(0.96));

    // CCD 노이즈: 고정 패턴, 약하게 (시간축으로 지글거리지 않게 시드 미사용)
    float lumaNoise = hash21(coord) - 0.5;
    c += lumaNoise * 0.02 * (1.0 - luma * 0.7);

    // 비네트
    float2 d = uv - 0.5;
    c *= 1.0 - dot(d, d) * 0.5;

    return coreimage::float4(clamp(c, 0.0, 1.0), 1.0);
}

// 삼성 케녹스(Cyber-410급) CCD 디카 신호 경로 재현. 입력은 이미 센서 해상도(640급)로
// 다운샘플된 상태. 실기기 처리 순서: 렌즈(CA/비네팅) → 크로마 4:2:0 → 노이즈 →
// 언샤프마스크 헤일로(삼성은 과샤프닝 성향, 노이즈 뒤에 적용) → 색튜닝(채도↑, 쿨톤) →
// DR 압축(하이라이트 소프트클립 + 블랙 리프트)
// 기종별 파라미터: saturation(1=원본), rGain/bGain(WB), sharpen(언샤프 강도),
// noise(진폭), bloom(블루밍 배율)
coreimage::float4 digicamLook(coreimage::sampler src,
                              float saturation, float rGain, float bGain,
                              float sharpen, float noise, float bloomAmt,
                              coreimage::destination dest) {
    float2 coord = dest.coord();
    float2 size = src.size();
    float2 uv = coord / size;
    float2 center = size * 0.5;

    // 렌즈: 색수차 (가장자리로 갈수록 R/B 어긋남, 저해상도 기준 1~2px)
    float2 dir = coord - center;
    float dist2 = dot(dir / size, dir / size);
    float2 caOff = dir * dist2 * 0.012;
    float r = src.sample(src.transform(coord + caOff)).r;
    float3 gb = src.sample(src.transform(coord - caOff * 0.5)).rgb;
    float3 c = float3(r, gb.g, gb.b);

    // JPEG 4:2:0 크로마 서브샘플링: 색만 뭉개고 루마 유지
    float3 ycc = rgb2ycbcr(c);
    float2 chroma = float2(0.0);
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            float3 s = src.sample(src.transform(coord + float2(i, j) * 2.0)).rgb;
            chroma += rgb2ycbcr(s).yz;
        }
    }
    ycc.yz = chroma / 9.0;
    c = ycbcr2rgb(ycc);

    // 센서 노이즈: 고정 패턴, 베이스 ISO에서도 은은하게 (삼성 성향), 어두울수록 강함
    float luma0 = dot(c, float3(0.299, 0.587, 0.114));
    c += (hash21(coord) - 0.5) * noise * (1.0 - luma0 * 0.6);

    // 언샤프마스크: 3x3 블러와의 차이를 더해 엣지 헤일로 생성 (노이즈도 같이 강조됨)
    float3 blurred = float3(0.0);
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            blurred += src.sample(src.transform(coord + float2(i, j) * 1.5)).rgb;
        }
    }
    blurred /= 9.0;
    c += (c - blurred) * sharpen;

    // CCD 블루밍: 클리핑 하이라이트 주변 글로우
    float3 bloom = float3(0.0);
    for (int i = -2; i <= 2; i++) {
        for (int j = -2; j <= 2; j++) {
            float3 s = src.sample(src.transform(coord + float2(i, j) * 2.5)).rgb;
            bloom += max(s - 0.8, 0.0);
        }
    }
    c += bloom / 25.0 * bloomAmt;

    // 기종별 색튜닝
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    c = mix(float3(luma), c, saturation);
    c *= float3(rGain, 1.0, bGain);

    // DR 압축: 0.85부터 하이라이트 소프트클립, 블랙은 살짝 들뜸
    float3 hi = smoothstep(0.85, 1.0, c);
    c = mix(c, float3(1.0), hi * hi);
    c = c * 0.96 + 0.025;

    // 비네팅 (광각단, 코너 위주)
    float2 d = uv - 0.5;
    c *= 1.0 - dot(d, d) * dot(d, d) * 1.4;

    return coreimage::float4(clamp(c, 0.0, 1.0), 1.0);
}

// 레시피 프리셋용 범용 그레이딩 커널.
// tone: (exposure곱, contrast, highlights±, shadows±)
// color: (saturation, vibrance, rGain, bGain)
// fx: (fade, sharpen, grain, vignette)
// shTint/hiTint: 스플릿 토닝 (섀도우/하이라이트 RGB 게인)
coreimage::float4 recipeLook(coreimage::sampler src,
                             float4 tone, float4 color, float4 fx,
                             float4 shTint, float4 hiTint,
                             coreimage::destination dest) {
    float2 coord = dest.coord();
    float2 size = src.size();
    float2 uv = coord / size;

    float3 c = src.sample(src.transform(coord)).rgb;

    // 노출 + 화이트밸런스
    c *= tone.x;
    c.r *= color.z;
    c.b *= color.w;

    // 하이라이트/섀도우 (루마 마스크 커브)
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    c += tone.z * smoothstep(0.55, 1.0, luma) * (1.0 - c);
    c += tone.w * smoothstep(0.5, 0.0, luma) * 0.3;

    // 콘트라스트 (0.5 중심)
    c = (c - 0.5) * tone.y + 0.5;

    // 페이드: 블랙 리프트 + 화이트 살짝 죽임
    c = c * (1.0 - 0.22 * fx.x) + 0.16 * fx.x;

    // 채도 + vibrance (저채도 픽셀만 추가로 올림)
    luma = dot(c, float3(0.299, 0.587, 0.114));
    float satNow = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b));
    float satAmt = color.x + color.y * (1.0 - clamp(satNow * 2.0, 0.0, 1.0));
    c = mix(float3(luma), c, satAmt);

    // 스플릿 토닝
    c *= mix(shTint.rgb, hiTint.rgb, smoothstep(0.25, 0.8, luma));

    // 언샤프마스크
    float3 blurred = float3(0.0);
    for (int i = -1; i <= 1; i++) {
        for (int j = -1; j <= 1; j++) {
            blurred += src.sample(src.transform(coord + float2(i, j) * 1.5)).rgb;
        }
    }
    blurred /= 9.0;
    c += (c - blurred) * fx.y;

    // 그레인 (시간축 고정)
    c += (hash21(coord) - 0.5) * fx.z;

    // 비네트
    float2 d = uv - 0.5;
    c *= 1.0 - dot(d, d) * fx.w;

    return coreimage::float4(clamp(c, 0.0, 1.0), 1.0);
}

// E-ink 전자잉크 룩: 그레이스케일 → Bayer 1비트 디더링, 종이 화이트/잉크 블랙
coreimage::float4 einkLook(coreimage::sampler src, float block,
                           coreimage::destination dest) {
    const float bayer[64] = {
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21
    };

    float2 coord = dest.coord();
    float2 blocked = floor(coord / block) * block + block * 0.5;
    float3 c = src.sample(src.transform(blocked)).rgb;
    float luma = dot(c, float3(0.299, 0.587, 0.114));

    // 대비 살짝 올려 중간톤이 디더 패턴으로 살아나게
    luma = clamp((luma - 0.5) * 1.25 + 0.52, 0.0, 1.0);

    int2 b = int2(fmod(floor(coord / block), 8.0));
    float threshold = (bayer[b.y * 8 + b.x] + 0.5) / 64.0;

    const float3 paper = float3(0.93, 0.92, 0.88);
    const float3 ink = float3(0.10, 0.10, 0.11);
    float3 outc = luma > threshold ? paper : ink;

    return coreimage::float4(outc, 1.0);
}

// Bayer 8x8 ordered dithering + 픽셀레이트
// block: 픽셀 블록 크기, levels: 채널당 양자화 레벨 수
coreimage::float4 ditherLook(coreimage::sampler src, float block, float levels,
                             coreimage::destination dest) {
    const float bayer[64] = {
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21
    };

    float2 coord = dest.coord();
    float2 blocked = floor(coord / block) * block + block * 0.5;
    float3 c = src.sample(src.transform(blocked)).rgb;

    int2 b = int2(fmod(floor(coord / block), 8.0));
    float threshold = (bayer[b.y * 8 + b.x] + 0.5) / 64.0 - 0.5;

    float n = levels - 1.0;
    c = round((c + threshold / n) * n) / n;

    return coreimage::float4(clamp(c, 0.0, 1.0), 1.0);
}

}
