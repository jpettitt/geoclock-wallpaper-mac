import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` — registers /
/// unregisters this app as a macOS Login Item so it launches
/// automatically when the user signs in.
///
/// macOS 13+ API. `SMAppService.mainApp` is the modern
/// replacement for the deprecated `SMLoginItemSetEnabled` and
/// LaunchAgent property-list approaches. The system maintains
/// the registration across reboots, and the user can revoke it
/// from System Settings → General → Login Items at any time
/// (in which case our `isEnabled` reads back false and the
/// Settings toggle reflects that).
///
/// All work is best-effort: a failure to register/unregister
/// is logged via `Diagnostics` but never raised to the caller —
/// a wallpaper utility that refuses to start because login-item
/// plumbing failed would be more annoying than the feature is
/// worth.
enum LaunchAtLogin {

  /// Reflects the system's current opinion of our Login Item
  /// status. Reads `SMAppService.mainApp.status`. Returns false
  /// for any state other than `.enabled` (notFound, notRegistered,
  /// requiresApproval) so the UI shows an honest "off" until the
  /// user explicitly turns it on or approves a pending request.
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Apply the user's desired state. Idempotent — re-registering
  /// an already-enabled service or unregistering an already-off
  /// service is a no-op (other than re-touching ServiceManagement
  /// state, which is harmless).
  ///
  /// Returns the post-call value of `isEnabled` so the caller can
  /// sync the config toggle back to reality (e.g. if the system
  /// silently rejected the request because the app is unsigned or
  /// approval is required).
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    let service = SMAppService.mainApp
    do {
      if enabled {
        if service.status != .enabled {
          try service.register()
        }
      } else {
        if service.status == .enabled {
          try service.unregister()
        }
      }
    } catch {
      // Common failure modes:
      //   - ad-hoc-signed local Debug builds (status .notFound)
      //   - the user revoked approval in System Settings
      //   - the .app isn't in a stable location (Downloads etc.)
      // None of these block the app from running; we just log
      // and let the Settings UI show whatever state the system
      // ended up in.
      Diagnostics.log(
        "LaunchAtLogin: \(enabled ? "register" : "unregister") failed — \(error)")
    }
    return isEnabled
  }
}
