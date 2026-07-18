// The FlutterWatchOS application delegate — remote-notification plumbing for
// plugins. watchOS delivers the APNs device token (and remote-notification
// payloads) only through the app-level WKApplicationDelegate; there is no
// notification-center equivalent a plugin could observe on its own. The app
// template adopts this delegate:
//
//     @WKApplicationDelegateAdaptor(FlutterWatchOSAppDelegate.self)
//     private var flutterAppDelegate
//
// and the delegate rebroadcasts each callback as a NSNotification. Plugins
// (compiled separately, linked only at the final app link) observe the
// notifications by name — no compile-time coupling in either direction.
#if !arch(arm64_32)
import Foundation
import WatchKit

/// Notification names posted by [FlutterWatchOSAppDelegate]. Plugins observe
/// these on `NotificationCenter.default` (by literal name from Objective-C).
public enum FlutterWatchOSRemoteNotification {
    /// Posted when APNs registration succeeds.
    /// userInfo: ["deviceToken": Data]
    public static let didRegister =
        Notification.Name("FlutterWatchOSRemoteNotificationsDidRegister")
    /// Posted when APNs registration fails.
    /// userInfo: ["error": Error]
    public static let didFail =
        Notification.Name("FlutterWatchOSRemoteNotificationsDidFail")
    /// Posted when a remote notification arrives while the app is running.
    /// userInfo: the raw APNs payload.
    public static let didReceive =
        Notification.Name("FlutterWatchOSRemoteNotificationDidReceive")
}

/// The application delegate the template installs. Forwards the
/// remote-notification callbacks to plugins via NotificationCenter and
/// otherwise stays out of the way (the engine observes the WKApplication
/// lifecycle notifications itself).
public class FlutterWatchOSAppDelegate: NSObject, WKApplicationDelegate {
    override public required init() {
        super.init()
    }

    public func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(
            name: FlutterWatchOSRemoteNotification.didRegister,
            object: nil,
            userInfo: ["deviceToken": deviceToken]
        )
    }

    public func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        NotificationCenter.default.post(
            name: FlutterWatchOSRemoteNotification.didFail,
            object: nil,
            userInfo: ["error": error]
        )
    }

    public func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (WKBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(
            name: FlutterWatchOSRemoteNotification.didReceive,
            object: nil,
            userInfo: userInfo
        )
        completionHandler(.newData)
    }
}
#endif  // !arch(arm64_32)
