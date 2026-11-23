# 只看 1000 Hz 的能量找嗶聲（不受房間裡說話與雜音影響）：
# 1. 以 1000 Hz 做 I/Q 解調，4 ms 移動平均 → 平滑的振幅包絡
# 2. 取包絡最高、彼此相隔至少 0.5 秒的 N 個峰
# 3. 每一聲的起點 = 峰之前包絡第一次超過該聲一半高度的位置（線性內插，次樣本精度）
# 4. 音高：在每一聲穩定的部分，用 Goertzel 掃 900–1100 Hz 找能量最大的頻率
import array, math, sys, wave
path, expected = sys.argv[1], int(sys.argv[2])
with wave.open(path) as w:
    rate = w.getframerate(); raw = w.readframes(w.getnframes())
x = array.array("h", raw)
n = len(x)
f0, L = 1000.0, int(rate * 0.004)
w0 = 2 * math.pi * f0 / rate
ci = array.array("d", [0.0]) * (n + 1); cq = array.array("d", [0.0]) * (n + 1)
si = sq = 0.0
for k in range(n):
    v = x[k] / 32768.0
    si += v * math.cos(w0 * k); sq += v * math.sin(w0 * k)
    ci[k + 1] = si; cq[k + 1] = sq
env = array.array("d", [0.0]) * n
for k in range(L, n):
    i = (ci[k] - ci[k - L]) / L; q = (cq[k] - cq[k - L]) / L
    env[k] = 2 * math.sqrt(i * i + q * q)
# 以 1 ms 為單位找峰
block = rate // 1000
peaks = []
for b in range(n // block):
    seg = env[b * block:(b + 1) * block]
    peaks.append((max(seg), b))
peaks.sort(reverse=True)
chosen = []
for value, b in peaks:
    if len(chosen) >= expected: break
    if all(abs(b - c) >= 500 for _, c in chosen):
        chosen.append((value, b))
chosen.sort(key=lambda t: t[1])
onsets = []
for value, b in chosen:
    top = max(range(b * block, (b + 1) * block), key=lambda k: env[k])
    half = env[top] / 2
    k = top
    while k > top - int(0.08 * rate) and env[k] > half: k -= 1
    frac = (half - env[k]) / (env[k + 1] - env[k]) if env[k + 1] != env[k] else 0
    onsets.append((k + frac, env[top]))
def goertzel(start, count, f):
    coeff = 2 * math.cos(2 * math.pi * f / rate); s1 = s2 = 0.0
    for k in range(start, start + count):
        s0 = x[k] / 32768.0 + coeff * s1 - s2; s2, s1 = s1, s0
    return s1 * s1 + s2 * s2 - coeff * s1 * s2
pitches = []
for onset, _ in onsets:
    start, count = int(onset + 0.008 * rate), int(0.034 * rate)
    coarse = max(range(900, 1101, 5), key=lambda f: goertzel(start, count, f))
    fine = max([coarse + d * 0.5 for d in range(-10, 11)], key=lambda f: goertzel(start, count, f))
    pitches.append(fine)
heights = [h for _, h in onsets]
noise = sorted(env)[n // 2]
print("檔案 %.3f 秒；找到 %d 聲（預期 %d）；1 kHz 振幅：最低 %.4f、最高 %.4f，中位數底噪 %.5f" % (n / rate, len(onsets), expected, min(heights), max(heights), noise))
times = [o / rate for o, _ in onsets]
intervals = [b - a for a, b in zip(times, times[1:])]
print("第一聲 %.4f 秒，最後一聲 %.4f 秒" % (times[0], times[-1]))
worst = max(abs(v - 1.0) for v in intervals)
print("間隔：最短 %.5f、最長 %.5f 秒；和 1.000 秒最大差 %.3f 毫秒；平均 %.6f" % (min(intervals), max(intervals), worst * 1000, sum(intervals) / len(intervals)))
odd = [(i + 1, round(v, 4)) for i, v in enumerate(intervals) if abs(v - 1.0) > 0.001]
print("超過 1 毫秒的間隔：", odd if odd else "沒有")
print("音高：平均 %.1f Hz（最低 %.1f、最高 %.1f）" % (sum(pitches) / len(pitches), min(pitches), max(pitches)))
