# 已知嗶聲每 1.000 秒一聲：先找出最可信的一聲，往前後每隔 1 秒預測位置，在預測位置 ±60 ms 內量每一聲。
# 一聲不見（振幅接近底噪）或位置偏掉，都代表那裡掉了聲音或時間不對。
import array, math, sys, wave
path, expected = sys.argv[1], int(sys.argv[2])
with wave.open(path) as w:
    rate = w.getframerate(); raw = w.readframes(w.getnframes())
x = array.array("h", raw); n = len(x)
L = int(rate * 0.004); w0 = 2 * math.pi * 1000.0 / rate
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
noise = sorted(env[::97])[len(env[::97]) // 2]
# 用「每隔 1 秒都有峰」的程度找相位：試 0–1 秒內每 1 ms 的起點，累加每一秒那個位置附近 ±3 ms 的最大振幅
step = rate // 1000
best = None
for phase in range(0, rate, step):
    total = 0.0
    for t in range(phase, n, rate):
        total += max(env[max(0, t - 3 * step):t + 3 * step] or [0])
    if best is None or total > best[0]: best = (total, phase)
phase = best[1]
# 取振幅最大的連續 expected 聲（嗶聲之外的位置振幅接近底噪）
slots = list(range(phase, n - int(0.06 * rate), rate))
amps = [max(env[max(0, t - int(0.06 * rate)):t + int(0.06 * rate)]) for t in slots]
start = max(range(len(slots) - expected + 1), key=lambda s: sum(amps[s:s + expected]))
results = []
for t in slots[start:start + expected]:
    lo, hi = max(0, t - int(0.06 * rate)), t + int(0.06 * rate)
    top = max(range(lo, hi), key=lambda k: env[k])
    half = env[top] / 2; k = top
    while k > lo and env[k] > half: k -= 1
    frac = (half - env[k]) / (env[k + 1] - env[k]) if env[k + 1] != env[k] else 0
    results.append(((k + frac) / rate, env[top]))
amps = [a for _, a in results]
times = [t for t, _ in results]
intervals = [b - a for a, b in zip(times, times[1:])]
weak = [(i + 1, round(a, 4)) for i, (_, a) in enumerate(results) if a < 10 * noise]
print("檔案 %.3f 秒；底噪 %.5f；%d 聲的 1 kHz 振幅：最低 %.4f、最高 %.4f；太弱（低於底噪 10 倍）的：%s" % (n / rate, noise, expected, min(amps), max(amps), weak if weak else "沒有"))
print("第一聲 %.4f 秒，最後一聲 %.4f 秒" % (times[0], times[-1]))
print("間隔：最短 %.5f、最長 %.5f 秒；和 1.000 秒最大差 %.3f 毫秒" % (min(intervals), max(intervals), max(abs(v - 1) for v in intervals) * 1000))
odd = [(i + 1, round(v, 5)) for i, v in enumerate(intervals) if abs(v - 1.0) > 0.001]
print("超過 1 毫秒的間隔：", odd if odd else "沒有")
