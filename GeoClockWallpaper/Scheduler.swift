import AppKit

/// Tiny scheduler around a `Timer`, with extras for the wallpaper
/// use case:
///
///   - Wakes the timer immediately when the Mac comes out of
///     sleep, so the wallpaper isn't stuck on a stale frame from
///     hours ago.
///   - Pause / resume preserves the configured interval — when
///     you resume, the next tick happens after a full interval
///     so we don't immediately fire if the user paused 4 minutes
///     into a 5-minute cycle.
final class Scheduler {
  private var timer: Timer?
  private var interval: TimeInterval
  private let onFire: () -> Void
  private var wakeObserver: NSObjectProtocol?

  init(interval: TimeInterval, onFire: @escaping () -> Void) {
    self.interval = max(60, min(interval, 3600))
    self.onFire = onFire
  }

  func start() {
    scheduleTimer()
    registerWakeObserver()
  }

  func pause() {
    timer?.invalidate()
    timer = nil
  }

  func resume() {
    guard timer == nil else { return }
    scheduleTimer()
  }

  func setInterval(_ seconds: TimeInterval) {
    interval = max(60, min(seconds, 3600))
    if timer != nil {
      // Re-schedule with the new interval. Don't fire immediately
      // — that's a user-confusing side-effect; let the next cycle
      // tick at the new cadence.
      scheduleTimer()
    }
  }

  deinit {
    timer?.invalidate()
    if let obs = wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(obs)
    }
  }

  // MARK: – Internal

  private func scheduleTimer() {
    timer?.invalidate()
    let t = Timer(
      timeInterval: interval,
      target: BlockTimerTarget(onFire),
      selector: #selector(BlockTimerTarget.fire),
      userInfo: nil,
      repeats: true)
    // .common mode keeps the timer firing while a menu is open —
    // the user shouldn't be punished for browsing the status menu.
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func registerWakeObserver() {
    let center = NSWorkspace.shared.notificationCenter
    wakeObserver = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Fire immediately on wake, then let the regular timer
      // schedule pick up from here. Stale-frame avoidance is the
      // whole point of registering this observer.
      self?.onFire()
    }
  }
}

/// Tiny shim for using a closure as a Timer target. Block-based
/// `Timer.scheduledTimer(withTimeInterval:repeats:_:)` exists but
/// retains the closure for the timer's lifetime — we want to
/// replace the closure if the user changes the interval without
/// re-wiring the closure-capturing graph, so this stays explicit.
private final class BlockTimerTarget: NSObject {
  private let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func fire() { action() }
}
