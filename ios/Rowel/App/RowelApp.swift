/// The app's entry point.

import SwiftUI

@main
struct RowelApp: App {
    @State private var model = AppModel()
    @State private var lock = AppLock()
    @State private var health = Health()
    // The one thing SwiftUI cannot see: `didRegisterForRemoteNotifications` is
    // an UIApplicationDelegate callback with no SwiftUI equivalent, and it is
    // how iOS hands back the token that lets a machine reach this phone when
    // the app is not running.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(lock)
                .environment(health)
                .tint(Palette.accent)
                .onOpenURL { url in
                    // A pairing link opened from Messages, Mail, or the Mac's
                    // own terminal. Handling it here means the QR and the link
                    // are the same path, so there is one thing to get right.
                    model.open(url: url)
                }
                .task {
                    #if DEBUG
                    // A seam for the UI tests, and only for them.
                    //
                    // Pairing is the first thing every flow depends on and the
                    // one thing a test cannot perform: the real paths are a
                    // camera pointed at a QR code and a link tapped in another
                    // app. Handing the link in through the launch environment
                    // exercises exactly the same `open(url:)` the two real paths
                    // end at, so nothing downstream is faked — only the delivery.
                    if let link = ProcessInfo.processInfo.environment["ROWEL_UITEST_PAIR_LINK"],
                       let url = URL(string: link) {
                        model.open(url: url)
                    }
                    #endif
                    model.restoreLastConnection()
                    model.refreshPush()
                    health.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.enteredForeground()
                // Notifications can be switched off in Settings while the app
                // is away, and the only way to find out is to look on the way
                // back in.
                model.refreshPush()
                lock.didBecomeActive()
            case .background, .inactive:
                model.enteredBackground()
                // `.inactive` and not only `.background`: iOS photographs the
                // window for the app switcher while the scene is merely
                // inactive, so a cover raised on `.background` is raised after
                // the picture has already been taken.
                lock.willResignActive()
            @unknown default:
                break
            }
        }
    }
}
