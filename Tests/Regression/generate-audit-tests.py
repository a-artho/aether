"""Test production route, log retention, and audio lifecycle with platform doubles."""
import pathlib, sys
repo = pathlib.Path(__file__).resolve().parents[2]
out = pathlib.Path(sys.argv[1])
def declaration(path, start):
    text = (repo / path).read_text()
    p = text.index(start); b = text.index('{', p); e = b + 1; depth = 1
    while depth:
        depth += (text[e] == '{') - (text[e] == '}'); e += 1
    return text[p:e]
locator = declaration('Aether/Backend/Observable/SourcesRouter.swift', 'struct AppLocator:')
publish = declaration('Aether/Backend/Observable/DebugLogManager.swift', 'private func _publish(').replace('private func', 'func', 1)
focus = declaration('Aether/Views/Installed/InstalledAppsView.swift', '.task(id: installationFocusState)').replace('.task(id: installationFocusState)', 'func focus()', 1)
audio = declaration('Aether/Utilities/BackgroundAudioManager.swift', 'class BackgroundAudioManager')
fixture = r'''
import Foundation
import XCTest
struct ASRepository {
 struct App: Hashable {
  let uuid: UUID, id: String?, version: String, downloadURL: URL, description: String
 }
}
struct DebugLogItem { let id: UUID }
final class LogFixture {
 var entries = [DebugLogItem]()
 var _publishedEntryIDs = Set<UUID>()
 let _maxPublishedCount = 1000
 PUBLISH
}
typealias OSStatus = Int32
let noErr: OSStatus = 0
struct AudioBufferList {}
struct AudioBuffer { let mData: UnsafeMutableRawPointer?; let mDataByteSize: UInt32 }
func UnsafeMutableAudioBufferListPointer(_ list: UnsafeMutablePointer<AudioBufferList>) -> [AudioBuffer] { [] }
final class AVAudioSourceNode {
 init(_ render: @escaping (Int, Int, Int, UnsafeMutablePointer<AudioBufferList>) -> OSStatus) {}
}
final class AVAudioSession {
 struct Options: OptionSet { let rawValue: Int; static let mixWithOthers = Options(rawValue:1); static let notifyOthersOnDeactivation = Options(rawValue:2) }
 enum Category { case playback }
 static let instance = AVAudioSession()
 static func sharedInstance() -> AVAudioSession { instance }
 var isActive = false
 var failActivation = false
 var failDeactivation = false
 func setCategory(_ category: Category, options: Options) throws {}
 func setActive(_ active: Bool, options: Options = []) throws {
  if active && failActivation { throw NSError(domain:"activation",code:1) }
  if !active && failDeactivation { throw NSError(domain:"deactivation",code:1) }
  isActive = active
 }
}
final class AVAudioEngine {
 static var failStart = false
 static var nodeCount = 0
 var isRunning = false
 let mainMixerNode = 0
 func attach(_ node: AVAudioSourceNode) { Self.nodeCount += 1 }
 func connect(_ node: AVAudioSourceNode, to mixer: Int, format: Int?) {}
 func start() throws { if Self.failStart { throw NSError(domain:"engine",code:1) }; isRunning = true }
 func stop() { isRunning = false }
 func disconnectNodeOutput(_ node: AVAudioSourceNode) {}
 func detach(_ node: AVAudioSourceNode) { Self.nodeCount -= 1 }
}
struct Transaction { var disablesAnimations = false }
func withTransaction(_ transaction: Transaction, _ body: () -> Void) { body() }
final class FocusTab {
 enum Tab { case installed, library }
 var selectedTab = Tab.installed
 var installationFocusRequest: UUID? = UUID()
 func consumeInstallationFocusRequest(_ request: UUID) {
  if installationFocusRequest == request { installationFocusRequest = nil }
 }
}
final class FocusProxy {
 enum Anchor { case top }
 var targets = [UUID]()
 func scrollTo(_ target: UUID, anchor: Anchor) { targets.append(target) }
}
final class FocusFixture {
 struct Card { let id: UUID }
 let tabManager = FocusTab()
 let scrollProxy = FocusProxy()
 var cards = [Card(id:UUID())]
 var selectedAppBundleId: String?
 var isSpoofingPresented = false
 var isRootListVisible = false
 var visibleInstallRows = Set<UUID>()
 FOCUS
}
final class AuditFixTests: XCTestCase {
 override func setUp() {
  BackgroundAudioManager.shared.stopAll()
  AVAudioEngine.failStart = false
  AVAudioSession.instance.failActivation = false
  AVAudioSession.instance.failDeactivation = false
 }
 override func tearDown() { BackgroundAudioManager.shared.stopAll() }
 func testVariantWithSharedBundleAndVersionKeepsExactSelectedEntry() {
  let url = URL(string:"https://example.com/app.ipa")!
  let first = ASRepository.App(uuid:UUID(),id:"com.example.app",version:"1.0",downloadURL:url,description:"Variant A")
  let second = ASRepository.App(uuid:UUID(),id:first.id,version:first.version,downloadURL:url,description:"Variant B")
  let route = AppLocator.locator(for:second)
  XCTAssertEqual(route.app, second)
  XCTAssertNotEqual(route.app, first)
  XCTAssertNotEqual(route, AppLocator.locator(for:first))
 }
 func testMissingBundleIDStillPreservesSelectedVariant() {
  let app = ASRepository.App(uuid:UUID(),id:nil,version:"2.0",downloadURL:URL(string:"https://example.com/b.ipa")!,description:"Variant")
  XCTAssertEqual(AppLocator.locator(for:app).app,app)
 }
 func testPublishedLogsStayBoundedAndNewestFirst() {
  let logs = LogFixture()
  let items = (0..<1500).map { _ in DebugLogItem(id:UUID()) }
  for item in items { logs._publish(item) }
  XCTAssertEqual(logs.entries.count,1000)
  XCTAssertEqual(logs._publishedEntryIDs.count,1000)
  XCTAssertEqual(logs.entries.map(\.id),items.suffix(1000).reversed().map(\.id))
  logs._publish(items.last!)
  XCTAssertEqual(logs.entries.count,1000)
  XCTAssertEqual(logs.entries.first?.id,items.last!.id)
 }
 func testFailedAudioStartupDetachesNodeAndDeactivatesSession() {
  AVAudioEngine.failStart = true
  BackgroundAudioManager.shared.start("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
  AVAudioEngine.failStart = false
  BackgroundAudioManager.shared.start("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,1)
  XCTAssertTrue(AVAudioSession.instance.isActive)
  BackgroundAudioManager.shared.stop("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testAudioActivationFailureAndRepeatedStopAreClean() {
  AVAudioSession.instance.failActivation = true
  BackgroundAudioManager.shared.start("server")
  BackgroundAudioManager.shared.stop("server")
  BackgroundAudioManager.shared.stopAll()
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testAudioDeactivationFailureCanBeRetriedWithoutLeakingNode() {
  BackgroundAudioManager.shared.start("server")
  AVAudioSession.instance.failDeactivation = true
  BackgroundAudioManager.shared.stop("server")
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
  XCTAssertTrue(AVAudioSession.instance.isActive)
  AVAudioSession.instance.failDeactivation = false
  BackgroundAudioManager.shared.stopAll()
  XCTAssertFalse(AVAudioSession.instance.isActive)
 }
 func testInstallFocusWaitsForRootAndTargetAppearance() {
  let view = FocusFixture()
  view.selectedAppBundleId = "app.details"
  view.focus()
  XCTAssertNil(view.selectedAppBundleId)
  XCTAssertTrue(view.scrollProxy.targets.isEmpty)
  XCTAssertNotNil(view.tabManager.installationFocusRequest)
  view.focus()
  XCTAssertTrue(view.scrollProxy.targets.isEmpty)
  view.isRootListVisible = true
  view.focus()
  XCTAssertEqual(view.scrollProxy.targets.last,view.cards.first!.id)
  XCTAssertNotNil(view.tabManager.installationFocusRequest)
  view.visibleInstallRows.insert(view.cards.first!.id)
  view.focus()
  XCTAssertNil(view.tabManager.installationFocusRequest)
 }
 func testManualTabNavigationPreservesDetailAndScroll() {
  let view = FocusFixture()
  view.tabManager.installationFocusRequest = nil
  view.selectedAppBundleId = "app.details"
  view.isRootListVisible = true
  view.focus()
  XCTAssertEqual(view.selectedAppBundleId,"app.details")
  XCTAssertTrue(view.scrollProxy.targets.isEmpty)
 }
 func testInstallFocusDoesNotActInAnotherTabOrWithoutJobs() {
  let view = FocusFixture()
  view.tabManager.selectedTab = .library
  view.selectedAppBundleId = "app.details"
  view.focus()
  XCTAssertEqual(view.selectedAppBundleId,"app.details")
  view.tabManager.selectedTab = .installed
  view.cards = []
  view.focus()
  XCTAssertEqual(view.selectedAppBundleId,"app.details")
  XCTAssertNotNil(view.tabManager.installationFocusRequest)
 }
 func testAudioStaysActiveUntilLastRequesterStops() {
  BackgroundAudioManager.shared.start("first")
  BackgroundAudioManager.shared.start("second")
  XCTAssertEqual(AVAudioEngine.nodeCount,1)
  BackgroundAudioManager.shared.stop("first")
  XCTAssertTrue(AVAudioSession.instance.isActive)
  BackgroundAudioManager.shared.stop("second")
  XCTAssertFalse(AVAudioSession.instance.isActive)
  XCTAssertEqual(AVAudioEngine.nodeCount,0)
 }
}
'''.replace(' PUBLISH',publish).replace(' FOCUS',focus)
(out/'AuditFixTests.swift').write_text(fixture+'\n'+locator+'\n'+audio+'\n')
