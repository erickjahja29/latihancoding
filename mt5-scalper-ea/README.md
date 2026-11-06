# ScalperEA – Expert Advisor Scalping untuk MetaTrader 5

## Strategi
Sinyal dicek **sekali per bar baru** pada timeframe `InpTF` (default M5), memakai bar yang sudah tertutup (tanpa repaint).

| | BUY | SELL |
|---|---|---|
| Trigger | EMA 9 memotong ke atas EMA 21 | EMA 9 memotong ke bawah EMA 21 |
| Filter tren | Close & EMA 9 di atas EMA 200 | Close & EMA 9 di bawah EMA 200 |
| Filter RSI(14) | 50 < RSI < 70 | 30 < RSI < 50 |

- **SL** = ATR(14) × 1.0, **TP** = ATR(14) × 1.5 (otomatis menyesuaikan volatilitas).
- **Lot** dihitung dari % risiko balance (default 1% per trade), atau lot tetap.
- **Breakeven**: saat profit ≥ ATR × 0.7, SL dipindah ke harga entry + 10 points.
- **Trailing stop**: saat profit ≥ ATR × 1.0, SL mengikuti harga dengan jarak ATR × 0.8.
- **Filter**: spread maksimum, jam trading (jam server broker), stop entry Jumat malam.
- **Batas loss harian**: jika equity turun ≥ 3% dari equity awal hari, semua posisi EA ditutup dan EA berhenti entry sampai hari berikutnya.
- Magic number sendiri, jadi aman dipakai bersama trading manual / EA lain.

## Cara Pasang
1. Buka MT5 → **File → Open Data Folder**.
2. Salin `ScalperEA.mq5` ke `MQL5/Experts/`.
3. Buka **MetaEditor** (F4), buka file tersebut, tekan **Compile** (F7).
4. Di MT5, refresh Navigator → seret **ScalperEA** ke chart.
5. Centang **Allow Algo Trading** dan pastikan tombol **Algo Trading** di toolbar aktif (hijau).

## Rekomendasi Awal
- Pair: EURUSD, GBPUSD, USDJPY (spread rendah). Untuk XAUUSD, naikkan `InpMaxSpreadPts` (mis. 40–60) karena spread emas dalam points lebih besar.
- Akun: ECN / Raw spread lebih cocok untuk scalping.
- `InpSlippagePts` dan `InpMaxSpreadPts` dalam **points** (broker 5 digit: 10 points = 1 pip).
- Jam trading default 08–20 jam server (umumnya mencakup sesi London & New York). Sesuaikan dengan zona waktu server broker kamu.

## Wajib Sebelum Live
1. **Backtest** di Strategy Tester (Ctrl+R) dengan model *Every tick based on real ticks*, minimal 6–12 bulan data.
2. Optimasi parameter seperlunya (hindari over-fitting).
3. Jalankan di **akun demo** minimal 2–4 minggu.
4. Baru live dengan risiko kecil (0.5–1% per trade).

> ⚠️ Disclaimer: Trading forex/CFD berisiko tinggi. EA ini adalah alat bantu/edukasi, bukan jaminan profit. Hasil masa lalu tidak menjamin hasil di masa depan.
