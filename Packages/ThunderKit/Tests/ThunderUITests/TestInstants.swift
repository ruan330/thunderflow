/// 測試用的時間點：固定的起點之後幾毫秒。
///
/// 這些元件只比較時間的先後與相差多久，所以用「起點＋毫秒」就能精確地測到邊界（剛好 0.5 秒、差 1 毫秒），
/// 結果固定，測試也不用真的等。
func ms(_ milliseconds: Int) -> ContinuousClock.Instant {
    origin + .milliseconds(milliseconds)
}

private let origin = ContinuousClock.now
