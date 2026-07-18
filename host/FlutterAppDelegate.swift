// The FlutterWatchOS application delegate — remote-notification plumbing for
// plugins. watchOS delivers the APNs device token (and remote-notification
// payloads) only through the app-level WKApplicationDelegate, and
// UNUserNotificationCenter has a single process-global delegate slot; both
// must be owned at the app level, not by any one plugin. The app template
// adopts this delegate:
//
//     @WKApplicationDelegateAdaptor(FlutterWatchOSAppDelegate.self)
//     private var flutterAppDelegate
//
// and the delegate rebroadcasts each callback as a NSNotification. Plugins
// (compiled separately, linked only at the final app link) observe the
// notifications by name — no compile-time coupling in either direction.
//
// Callbacks that arrive before any plugin has installed its observers (the
// APNs token from an at-launch registration, a background push that woke the
// process, the notification response for the tap that launched the app) are
// buffered; a plugin posts `observersReady` once its observers are in place
// and the buffered events are replayed.
#if !arch(arm64_32)
import Foundation
import UserNotifications
import WatchKit

/// Notification names used between [FlutterWatchOSAppDelegate] and plugins.
/// Plugins observe these on `NotificationCenter.default` (by literal name
/// from Objective-C).
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
    /// Posted (synchronously, on the main thread) when a notification is
    /// about to be presented while the app is foreground.
    /// userInfo: ["payload": [AnyHashable: Any],
    ///            "options": NSMutableDictionary]
    /// An observer may set `options["options"]` to a NSNumber wrapping a
    /// `UNNotificationPresentationOptions.rawValue`; the delegate passes it
    /// to the system's completion handler after the post returns.
    public static let willPresent =
        Notification.Name("FlutterWatchOSNotificationWillPresent")
    /// Posted when the user acts on a notification (tap or action).
    /// userInfo: ["payload": [AnyHashable: Any],
    ///            "actionIdentifier": String]
    public static let didReceiveResponse =
        Notification.Name("FlutterWatchOSNotificationDidReceiveResponse")
    /// Posted BY a plugin once its observers for the notifications above are
    /// installed; the delegate then replays any buffered events.
    public static let observersReady =
        Notification.Name("FlutterWatchOSRemoteNotificationObserversReady")
}

/// The application delegate the template installs. Forwards the
/// remote-notification and user-notification callbacks to plugins via
/// NotificationCenter and otherwise stays out of the way (the engine
/// observes the WKApplication lifecycle notifications itself).
public class FlutterWatchOSAppDelegate: NSObject, WKApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    // Buffered events from before any plugin observer existed. Main-thread
    // confined (WKApplicationDelegate callbacks arrive on the main thread;
    // the UN delegate callbacks and observersReady hop to it).
    private var observersReady = false
    private var bufferedToken: Data?
    private var bufferedError: Error?
    private var bufferedPayloads: [[AnyHashable: Any]] = []
    private static let maxBufferedPayloads = 16

    override public required init() {
        super.init()
        // The notification-center delegate must be in place before the app
        // finishes launching, or the response for the tap that launched the
        // app is dropped. @WKApplicationDelegateAdaptor instantiates the
        // delegate together with the App struct, which is early enough.
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onObserversReady),
            name: FlutterWatchOSRemoteNotification.observersReady,
            object: nil
        )
    }

    @objc private func onObserversReady() {
        DispatchQueue.main.async { [self] in
            observersReady = true
            if let token = bufferedToken {
                post(FlutterWatchOSRemoteNotification.didRegister,
                     userInfo: ["deviceToken": token])
            }
            if let error = bufferedError {
                post(FlutterWatchOSRemoteNotification.didFail,
                     userInfo: ["error": error])
            }
            for payload in bufferedPayloads {
                post(FlutterWatchOSRemoteNotification.didReceive,
                     userInfo: payload)
            }
            bufferedToken = nil
            bufferedError = nil
            bufferedPayloads = []
        }
    }

    private func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]) {
        NotificationCenter.default.post(name: name, object: nil,
                                        userInfo: userInfo)
    }

    // WKApplicationDelegate ------------------------------------------------

    public func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        if !observersReady {
            bufferedToken = deviceToken
            bufferedError = nil
        }
        post(FlutterWatchOSRemoteNotification.didRegister,
             userInfo: ["deviceToken": deviceToken])
    }

    public func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        if !observersReady {
            bufferedError = error
            bufferedToken = nil
        }
        post(FlutterWatchOSRemoteNotification.didFail,
             userInfo: ["error": error])
    }

    public func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler:
            @escaping (WKBackgroundFetchResult) -> Void
    ) {
        if !observersReady,
            bufferedPayloads.count < Self.maxBufferedPayloads
        {
            bufferedPayloads.append(userInfo)
        }
        post(FlutterWatchOSRemoteNotification.didReceive, userInfo: userInfo)
        completionHandler(.newData)
    }

    // UNUserNotificationCenterDelegate ------------------------------------

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        DispatchQueue.main.async { [self] in
            let options = NSMutableDictionary()
            post(FlutterWatchOSRemoteNotification.willPresent, userInfo: [
                "payload": notification.request.content.userInfo,
                "options": options,
            ])
            let raw = (options["options"] as? NSNumber)?.uintValue ?? 0
            completionHandler(UNNotificationPresentationOptions(rawValue: raw))
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [self] in
            post(FlutterWatchOSRemoteNotification.didReceiveResponse, userInfo: [
                "payload": response.notification.request.content.userInfo,
                "actionIdentifier": response.actionIdentifier,
            ])
            completionHandler()
        }
    }
}
#endif  // !arch(arm64_32)
