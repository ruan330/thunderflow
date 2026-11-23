# 每秒一聲嗶：1 kHz、50 ms（前後 5 ms 淡入淡出），第一聲在 1.000 秒，共 N 聲。48 kHz、單聲道、16 位元。
import math, struct, sys, wave
out, count = sys.argv[1], int(sys.argv[2])
rate, freq, length, ramp, amp = 48000, 1000.0, 0.050, 0.005, 0.5
total = int(rate * (count + 1.5))
samples = [0.0] * total
for n in range(1, count + 1):
    start = n * rate
    for i in range(int(length * rate)):
        t = i / rate
        env = min(1.0, t / ramp, (length - t) / ramp)
        env = 0.5 - 0.5 * math.cos(math.pi * max(0.0, min(1.0, env)))
        samples[start + i] = amp * env * math.sin(2 * math.pi * freq * t)
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
    w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
print("wrote", out, total / rate, "s")
