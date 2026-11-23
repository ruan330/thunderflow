# 分析錄下來的嗶聲：找出每一聲的起點，算相鄰兩聲的間隔（應該是 1.000 秒）與音高（應該是 1000 Hz）。
import array, sys, wave
path = sys.argv[1]
with wave.open(path) as w:
    rate, width, channels = w.getframerate(), w.getsampwidth(), w.getnchannels()
    raw = w.readframes(w.getnframes())
assert width == 2 and channels == 1, (width, channels)
x = array.array("h", raw)
peak = max(abs(v) for v in x) or 1
threshold = 0.3 * peak
onsets, i, n = [], 0, len(x)
while i < n:
    if abs(x[i]) > threshold:
        onsets.append(i)
        i += int(0.5 * rate)   # 跳過這一聲
    else:
        i += 1
intervals = [(b - a) / rate for a, b in zip(onsets, onsets[1:])]
freqs = []
for o in onsets:
    seg = x[o + int(0.005 * rate): o + int(0.040 * rate)]
    crossings = sum(1 for a, b in zip(seg, seg[1:]) if (a < 0) != (b < 0))
    freqs.append(crossings / 2 / (len(seg) / rate))
print("檔案長度 %.3f 秒，取樣率 %d，峰值 %.3f" % (n / rate, rate, peak / 32768))
print("找到 %d 聲；第一聲在 %.3f 秒" % (len(onsets), onsets[0] / rate if onsets else -1))
if intervals:
    worst = max(abs(v - 1.0) for v in intervals)
    print("間隔：最短 %.5f、最長 %.5f、平均 %.6f 秒；和 1.000 秒最大差 %.3f 毫秒" % (min(intervals), max(intervals), sum(intervals) / len(intervals), worst * 1000))
    odd = [(k + 1, round(v, 4)) for k, v in enumerate(intervals) if abs(v - 1.0) > 0.001]
    print("超過 1 毫秒的間隔：", odd if odd else "沒有")
if freqs:
    print("音高：平均 %.1f Hz（最低 %.1f、最高 %.1f）" % (sum(freqs) / len(freqs), min(freqs), max(freqs)))
