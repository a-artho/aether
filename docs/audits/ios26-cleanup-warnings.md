# iOS 26 cleanup: remaining build warnings

Verified commit: `646f59c`. [Successful validation run](https://github.com/a-artho/aether/actions/runs/37863138508).

The fresh Release iPhone build, 83 Swift regression tests, additional native/flow checks, and unsigned IPA validation passed. Publishing was disabled. This report lists unique warning locations/messages, with duplicate compiler emissions removed.

## App warnings

| Category | Count |
| --- | ---: |
| Deprecated APIs | 38 |
| Concurrency and actor isolation | 197 |
| Unnecessary await | 2 |
| Other | 3 |

Strict concurrency checking is now enabled while the app retains Swift 5 language mode. These diagnostics include non-Sendable values crossing tasks, shared mutable state, nested weak captures, and locks used directly in async contexts. They need targeted ownership review; a compiler warning alone does not establish a runtime race. Deprecated APIs include old onChange closures, MapKit placemarks, list styling, and URL launch-option logging.

### Full app warning list

```text
Aether/AetherApp.swift:353:222: warning: 'url' was deprecated in iOS 26.0: Use UIScene lifecycle and UIScene.ConnectionOptions.URLContexts instead.
Aether/AetherApp.swift:375:7: warning: non-Sendable parameter type 'UNNotificationResponse' cannot be sent from caller of protocol requirement 'userNotificationCenter(_:didReceive:)' into main actor-isolated implementation; this is an error in the Swift 6 language mode
Aether/AetherApp.swift:375:7: warning: non-Sendable parameter type 'UNUserNotificationCenter' cannot be sent from caller of protocol requirement 'userNotificationCenter(_:didReceive:)' into main actor-isolated implementation; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:420:10: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:420:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:426:10: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:426:29: warning: capture of 'handler' with non-Sendable type 'ArchiveHandler' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:426:29: warning: sending 'handler' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:426:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:446:11: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:446:7: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:452:11: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:452:7: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:458:18: warning: no 'async' operations occur within 'await' expression
Aether/Backend/Observable/AppInstallationManager.swift:460:11: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:460:7: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:474:10: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:474:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:478:10: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:478:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:479:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:480:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:482:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:484:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/AppInstallationManager.swift:486:6: warning: reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:262:9: warning: instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:264:9: warning: instance method 'unlock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:266:23: warning: non-Sendable type 'Task<[DebugLogItem], Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:266:23: warning: type 'DebugLogItem' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:266:28: warning: type 'DebugLogItem' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:295:5: warning: non-Sendable type '[DebugLogItem]' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DebugLogManager.swift:295:5: warning: type 'DebugLogItem' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:10:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'IDeviceSwift'
Aether/Backend/Observable/DeviceConnectionManager.swift:178:3: warning: cannot access property 'didBecomeActiveObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:181:3: warning: cannot access property 'didEnterBackgroundObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:569:27: warning: non-Sendable type 'Task<DeviceConnectionCheck, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:569:27: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:569:32: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:571:5: warning: non-Sendable type 'DeviceConnectionCheck' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:571:5: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:715:52: warning: capture of 'checkedRecord' with non-Sendable type 'PairingRecordIdentity?' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:719:22: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:719:27: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:719:7: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:723:49: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:723:62: warning: non-Sendable type 'Task<DeviceConnectionCheck, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:723:75: warning: non-Sendable type 'DeviceConnectionCheck' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:723:75: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:726:10: warning: non-Sendable type 'Task<DeviceConnectionCheck, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:726:23: warning: non-Sendable type 'DeviceConnectionCheck' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:726:23: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:727:17: warning: capture of 'verification' with non-Sendable type 'Task<DeviceConnectionCheck, Never>' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DeviceConnectionManager.swift:727:30: warning: type 'DeviceConnectionCheck' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DownloadManager.swift:348:10: warning: reference to captured var 'self' in concurrently-executing code
Aether/Backend/Observable/DownloadManager.swift:349:10: warning: reference to captured var 'download' in concurrently-executing code
Aether/Backend/Observable/DownloadManager.swift:425:15: warning: reference to captured var 'self' in concurrently-executing code
Aether/Backend/Observable/DownloadManager.swift:738:4: warning: no 'async' operations occur within 'await' expression
Aether/Backend/Observable/DownloadManager.swift:88:3: warning: cannot access property '_backgroundObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/DownloadManager.swift:89:3: warning: cannot access property '_foregroundObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:115:21: warning: sending 'connection' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:11:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'NetworkExtension'
Aether/Backend/Observable/EmbeddedTunnelManager.swift:131:3: warning: cannot access property 'statusObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:134:3: warning: cannot access property 'configurationObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:472:82: warning: capture of 'observer' with non-Sendable type 'any NSObjectProtocol' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:498:42: warning: non-Sendable type 'Task<[NETunnelProviderManager], any Error>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:498:60: warning: non-Sendable type '[NETunnelProviderManager]' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:498:60: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:501:14: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:501:51: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:501:7: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:505:26: warning: sending value of non-Sendable type '[NETunnelProviderManager]' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:511:28: warning: non-Sendable type 'Task<[NETunnelProviderManager], any Error>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:511:33: warning: non-Sendable type '[NETunnelProviderManager]' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:511:33: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/EmbeddedTunnelManager.swift:91:14: warning: type 'NETunnelProviderManager' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Backend/Observable/ExportManager.swift:100:40: warning: sending 'handler' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/ExportManager.swift:96:23: warning: sending 'handler' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/ExportManager.swift:98:40: warning: sending 'handler' risks causing data races; this is an error in the Swift 6 language mode
Aether/Backend/Observable/OptionsManager.swift:13:13: warning: static property 'shared' is not concurrency-safe because non-'Sendable' type 'OptionsManager' may have shared mutable state; this is an error in the Swift 6 language mode
Aether/Backend/Server/ServerInstaller.swift:56:3: warning: call to main actor-isolated instance method '_shutdownServer()' in a synchronous nonisolated context
Aether/Backend/Server/ServerInstaller.swift:72:10: warning: call to main actor-isolated instance method '_updateStatus' in a synchronous nonisolated context
Aether/Backend/Server/ServerInstaller.swift:75:26: warning: main actor-isolated property 'installManifestData' can not be referenced from a Sendable closure
Aether/Backend/Server/ServerInstaller.swift:79:26: warning: main actor-isolated property 'displayImageSmallData' can not be referenced from a Sendable closure
Aether/Backend/Server/ServerInstaller.swift:83:26: warning: main actor-isolated property 'displayImageLargeData' can not be referenced from a Sendable closure
Aether/Backend/Server/ServerInstaller.swift:85:28: warning: main actor-isolated property 'packageUrl' can not be referenced from a Sendable closure
Aether/Backend/Server/ServerInstaller.swift:89:17: warning: call to main actor-isolated instance method '_streamPayload(at:for:)' in a synchronous nonisolated context
Aether/Backend/Server/ServerInstaller.swift:94:77: warning: main actor-isolated property 'html' can not be referenced from a Sendable closure
Aether/Backend/Storage/Storage+Certificate.swift:75:13: warning: capture of 'cert' with non-Sendable type 'CertificatePair' in a '@Sendable' closure
Aether/Backend/Storage/Storage+Certificate.swift:75:59: warning: capture of 'self' with non-Sendable type 'Storage' in a '@Sendable' closure
Aether/Backend/Storage/Storage+Certificate.swift:76:23: warning: main actor-isolated static property 'shared' can not be referenced from a Sendable closure
Aether/Backend/Storage/Storage+Certificate.swift:76:30: warning: call to main actor-isolated instance method 'log(_:category:level:)' in a synchronous nonisolated context
Aether/Backend/Storage/Storage+Certificate.swift:99:21: warning: static property '_provisionCache' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Backend/Storage/Storage.swift:13:13: warning: static property 'shared' is not concurrency-safe because non-'Sendable' type 'Storage' may have shared mutable state; this is an error in the Swift 6 language mode
Aether/Backend/Storage/Storage.swift:31:39: warning: reference to var 'NSMergeByPropertyObjectTrumpMergePolicy' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
Aether/Backend/Storage/Storage.swift:45:10: warning: capture of 'self' with non-Sendable type 'Storage' in a '@Sendable' closure
Aether/Backend/Storage/Storage.swift:49:5: warning: mutation of captured var 'saveError' in concurrently-executing code
Aether/Backend/Storage/Storage.swift:58:59: warning: capture of 'fetchRequest' with non-Sendable type 'NSFetchRequest<any NSFetchRequestResult>' in a '@Sendable' closure
Aether/Backend/Storage/Storage.swift:61:22: warning: capture of 'self' with non-Sendable type 'Storage' in a '@Sendable' closure
Aether/Backend/Storage/Storage.swift:68:21: warning: main actor-isolated static property 'shared' can not be referenced from a Sendable closure
Aether/Backend/Storage/Storage.swift:68:28: warning: call to main actor-isolated instance method 'log(_:category:level:)' in a synchronous nonisolated context
Aether/Backend/Storage/Storage.swift:8:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreData'
Aether/Extensions/UTType++.swift:11:13: warning: static property 'dylib' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:12:13: warning: static property 'deb' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:13:13: warning: static property 'ipa' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:14:13: warning: static property 'tipa' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:15:13: warning: static property 'entitlements' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:16:13: warning: static property 'p12' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Extensions/UTType++.swift:17:13: warning: static property 'mobileProvision' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Resources/Assets.xcassets:./AppStore.imageset/(null)[2d][AppStore.png]: warning: The image set "AppStore" has an unassigned child.
Aether/Utilities/FR.swift:100:27: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:100:43: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:120:21: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:120:7: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:142:20: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:142:6: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:151:22: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:151:6: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:169:63: warning: passing non-Sendable parameter 'progress' to function expecting a '@Sendable' closure
Aether/Utilities/FR.swift:170:15: warning: passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:181:19: warning: sending 'progress' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:189:17: warning: sending 'progress' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:191:35: warning: sending 'handler' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:191:46: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:197:54: warning: capture of 'handler' with non-Sendable type 'SigningHandler' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:203:33: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:218:8: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:231:20: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:231:6: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:235:22: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:235:6: warning: capture of 'completion' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:298:22: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:298:7: warning: capture of 'completion' with non-Sendable type '(Bool) -> Void' in a '@Sendable' closure
Aether/Utilities/FR.swift:302:23: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:302:7: warning: capture of 'completion' with non-Sendable type '(Bool) -> Void' in a '@Sendable' closure
Aether/Utilities/FR.swift:307:22: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:307:6: warning: capture of 'completion' with non-Sendable type '(Bool) -> Void' in a '@Sendable' closure
Aether/Utilities/FR.swift:330:15: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:330:5: warning: capture of 'completion' with non-Sendable type '((Bool) -> Void)?' in a '@Sendable' closure
Aether/Utilities/FR.swift:335:3: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:346:19: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:346:9: warning: capture of 'completion' with non-Sendable type '((Bool) -> Void)?' in a '@Sendable' closure
Aether/Utilities/FR.swift:346:9: warning: capture of 'completion' with non-Sendable type '((Bool) -> Void)?' in an isolated closure
Aether/Utilities/FR.swift:350:10: warning: capture of 'completion' with non-Sendable type '((Bool) -> Void)?' in an isolated closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:362:16: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:362:6: warning: capture of 'completion' with non-Sendable type '((Bool) -> Void)?' in a '@Sendable' closure
Aether/Utilities/FR.swift:370:8: warning: concurrently-executed local function 'performExport(for:)' must be marked as '@Sendable'
Aether/Utilities/FR.swift:395:18: warning: main actor-isolated class property 'shared' can not be referenced from a nonisolated context
Aether/Utilities/FR.swift:395:25: warning: call to main actor-isolated instance method 'open(_:options:completionHandler:)' in a synchronous nonisolated context
Aether/Utilities/FR.swift:404:16: warning: capture of 'certificates' with non-Sendable type '[CertificatePair]' in a '@Sendable' closure
Aether/Utilities/FR.swift:415:6: warning: capture of 'performExport(for:)' with non-Sendable type '(CertificatePair) -> ()' in a '@Sendable' closure
Aether/Utilities/FR.swift:415:6: warning: capture of 'performExport(for:)' with non-Sendable type '(CertificatePair) -> ()' in an isolated closure
Aether/Utilities/FR.swift:57:8: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:66:36: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:66:6: warning: capture of 'completion' with non-Sendable type '(Result<Bool, any Error>) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:70:32: warning: sending 'completion' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:70:6: warning: capture of 'completion' with non-Sendable type '(Result<Bool, any Error>) -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:84:8: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:92:199: warning: capture of 'level' with non-Sendable type 'DebugLogItem.Level' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/FR.swift:92:29: warning: sending 'level' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/ArchiveHandler.swift:108:31: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/ArchiveHandler.swift:49:21: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/ArchiveHandler.swift:78:21: warning: passing closure as a 'sending' parameter risks causing data races between code in the current task and concurrent execution of the closure; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/SigningHandler.swift:212:11: warning: capture of 'self' with non-Sendable type 'SigningHandler' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/SigningHandler.swift:212:11: warning: sending 'self' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/SigningHandler.swift:226:16: warning: sending 'onCommitted' risks causing data races; this is an error in the Swift 6 language mode
Aether/Utilities/Handlers/SigningHandler.swift:226:4: warning: capture of 'onCommitted' with non-Sendable type '@MainActor () -> Void' in a '@Sendable' closure; this is an error in the Swift 6 language mode
Aether/Utilities/HapticManager.swift:33:20: warning: static property 'shared' is not concurrency-safe because non-'Sendable' type 'HapticManager' may have shared mutable state; this is an error in the Swift 6 language mode
Aether/Utilities/HapticManager.swift:45:19: warning: call to main actor-isolated initializer 'init(style:)' in a synchronous nonisolated context
Aether/Utilities/HapticManager.swift:46:13: warning: call to main actor-isolated instance method 'prepare()' in a synchronous nonisolated context
Aether/Utilities/HapticManager.swift:47:13: warning: call to main actor-isolated instance method 'impactOccurred()' in a synchronous nonisolated context
Aether/Utilities/HapticManager.swift:56:19: warning: call to main actor-isolated initializer 'init()' in a synchronous nonisolated context
Aether/Utilities/HapticManager.swift:57:13: warning: call to main actor-isolated instance method 'prepare()' in a synchronous nonisolated context
Aether/Utilities/HapticManager.swift:58:13: warning: call to main actor-isolated instance method 'notificationOccurred' in a synchronous nonisolated context
Aether/Utilities/iconPoc.m:204:33: warning: 'mainScreen' is deprecated: first deprecated in iOS 26.0 - Use a UIScreen instance found through context instead (i.e, view.window.windowScene.screen), or for properties like UIScreen.scale with trait equivalents, use a traitCollection found through context. [-Wdeprecated-declarations]
Aether/Utilities/iconPoc.m:221:20: warning: 'mainScreen' is deprecated: first deprecated in iOS 26.0 - Use a UIScreen instance found through context instead (i.e, view.window.windowScene.screen), or for properties like UIScreen.scale with trait equivalents, use a traitCollection found through context. [-Wdeprecated-declarations]
Aether/Views/Common/FRAppIconView.swift:45:13: warning: static property 'shared' is not concurrency-safe because non-'Sendable' type 'FRIconCache' may have shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Installed/Detail/InstalledAppDetailView.swift:149:9: warning: main actor-isolated property 'storeCellAppearance' can not be referenced from a Sendable closure
Aether/Views/Installed/InstalledAppsStore.swift:129:14: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:208:7: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:209:18: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:220:18: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:288:8: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:290:42: warning: non-Sendable type 'Task<[AppInfo]?, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:290:51: warning: non-Sendable type '[AppInfo]?' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:290:51: warning: type 'AppInfo' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
Aether/Views/Installed/InstalledAppsStore.swift:8:1: warning: add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'IDeviceSwift'
Aether/Views/Installed/InstalledAppsView.swift:101:10: warning: 'init(destination:isActive:label:)' was deprecated in iOS 16.0: use NavigationLink(value:label:), or navigationDestination(isPresented:destination:), inside a NavigationStack or NavigationSplitView
Aether/Views/Installed/InstalledAppsView.swift:723:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Library/Info/LibraryInfoView.swift:67:9: warning: immutable value 'name' was never used; consider replacing with '_' or removing it
Aether/Views/Library/LibraryView.swift:218:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Library/LibraryView.swift:268:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Library/LibraryView.swift:272:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/App Icon/AppIconView.swift:24:68: warning: call to main actor-isolated static method 'altImage' in a synchronous nonisolated context
Aether/Views/Settings/Appearance/AppearanceTintColorView.swift:60:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Appearance/AppearanceView.swift:169:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/OnDevicePairingView.swift:57:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/PairingFileView.swift:115:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/PairingFileView.swift:118:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/PairingFileView.swift:89:46: warning: reference to static property 'plist' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Settings/Installation/Tunnel & Pairing/PairingFileView.swift:89:54: warning: reference to static property 'mobiledevicepairing' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift:102:7: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift:109:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Installation/Tunnel & Pairing/TunnelView.swift:90:7: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/SettingsView.swift:143:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Settings/Signing Options/ConfigurationView.swift:52:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Shared/ToolbarSearchField.swift:263:52: warning: sending 'notification' risks causing data races; this is an error in the Swift 6 language mode
Aether/Views/Shared/ToolbarSearchField.swift:267:11: warning: cannot access property 'keyboardObserver' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Views/Shared/ToolbarSearchField.swift:91:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Signing/SigningEntitlementsView.swift:37:47: warning: reference to static property 'plist' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Signing/SigningView.swift:103:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Signing/SigningView.swift:114:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Signing/SigningView.swift:115:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Signing/SigningView.swift:116:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/Detail/ExpandableText.swift:23:21: warning: static property 'cache' is not concurrency-safe because non-'Sendable' type 'NSCache<NSString, SourceAppBodyText.DisplayText>' may have shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Sources/Apps/SourceAppsView.swift:115:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/SourceAppsView.swift:134:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/SourceAppsView.swift:137:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/SourceAppsView.swift:140:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/SourceAppsView.swift:143:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift:146:19: warning: cannot access property '_dateObservers' with a non-Sendable type '[any NSObjectProtocol]' from nonisolated deinit; this is an error in the Swift 6 language mode
Aether/Views/Sources/Apps/UIKit/SourceAppsTableRepresentableView.swift:173:35: warning: 'listPlainCell()' was deprecated in iOS 18.0: renamed to 'listCell'
Aether/Views/Sources/SourcesView.swift:122:5: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/SourcesView.swift:185:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Sources/SourcesView.swift:188:4: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
Aether/Views/Spoofing/Engine/LocationEngine.swift:57:24: warning: static property 'adapter' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Spoofing/Engine/LocationEngine.swift:58:24: warning: static property 'handshake' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Spoofing/Engine/LocationEngine.swift:59:24: warning: static property 'remoteServer' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Spoofing/Engine/LocationEngine.swift:60:24: warning: static property 'locationSimulation' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode
Aether/Views/Spoofing/Engine/RouteBuilder.swift:12:26: warning: 'init(placemark:)' was deprecated in iOS 26.0: Use init(location:address:)
Aether/Views/Spoofing/Engine/RouteBuilder.swift:12:47: warning: 'MKPlacemark' was deprecated in iOS 26.0: Use MKMapItem's location, address and addressRepresentations properties instead. Use MKAddressRepresentations for formatted address strings for MapKit provided MKMapItems
Aether/Views/Spoofing/Engine/RouteBuilder.swift:13:31: warning: 'init(placemark:)' was deprecated in iOS 26.0: Use init(location:address:)
Aether/Views/Spoofing/Engine/RouteBuilder.swift:13:52: warning: 'MKPlacemark' was deprecated in iOS 26.0: Use MKMapItem's location, address and addressRepresentations properties instead. Use MKAddressRepresentations for formatted address strings for MapKit provided MKMapItems
Aether/Views/Spoofing/Map/MapHomeView.swift:345:34: warning: 'placemark' was deprecated in iOS 26.0: Use location, address and addressRepresentations instead
Aether/Views/Spoofing/Map/MapHomeView.swift:456:43: warning: sending 'items' risks causing data races; this is an error in the Swift 6 language mode
Aether/Views/Spoofing/SpoofingRootView.swift:32:10: warning: 'onChange(of:perform:)' was deprecated in iOS 17.0: Use `onChange` with a two or zero parameter action closure instead.
AetherTunnel/PacketTunnelProvider.swift:39:14: warning: capture of 'self' with non-Sendable type 'PacketTunnelProvider?' in a '@Sendable' closure
AetherTunnel/PacketTunnelProvider.swift:41:5: warning: capture of 'completionHandler' with non-Sendable type '((any Error)?) -> Void' in a '@Sendable' closure
AetherTunnel/PacketTunnelProvider.swift:53:4: warning: capture of 'completionHandler' with non-Sendable type '() -> Void' in a '@Sendable' closure
AetherTunnel/PacketTunnelProvider.swift:64:14: warning: capture of 'self' with non-Sendable type 'PacketTunnelProvider?' in a '@Sendable' closure
ld: warning: search path 'Aether/Resources/idevice' not found
```

## Dependency and build-tool warnings

These include unused Rust code/imports and build metadata notices. Summary notices may refer to several underlying warnings.

```text
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
warning: Metadata extraction skipped. No AppIntents.framework dependency found.
warning: `idevice` (lib test) generated 1 warning (run `cargo fix --lib -p idevice --tests` to apply 1 suggestion)
warning: `idevice` (lib test) generated 2 warnings (run `cargo fix --lib -p idevice --tests` to apply 1 suggestion)
warning: `idevice` (lib) generated 12 warnings
warning: field `0` is never read
warning: fields `code`, `identifier`, and `remote` are never read
warning: function `extract_ns_error_message` is never used
warning: function `parse_u64_value` is never used
warning: function `remote_timeout_error` is never used
warning: method `detach` is never used
warning: method `launch_with_options` is never used
warning: method `send_raw_profiled` is never used
warning: methods `read_message_timeout`, `call_method_with_reply`, `set_incoming_handler`, `clear_incoming_handler`, and `send_raw_reply_for` are never used
warning: multiple associated items are never used
warning: unused import: `RsdProvider`
warning: variant `Skipped` is never constructed
warning: variants `Unhandled`, `HandledNoReply`, and `Reply` are never constructed
```
