#!/usr/bin/env python3
"""Exercise production location-manager modes and session policy without GPS hardware."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
def declaration(path,start):
 s=(repo/path).read_text();a=s.index(start);b=s.index('{',a)+1;depth=1
 while depth:depth+=(s[b]=='{')-(s[b]=='}');b+=1
 return s[a:b]+"\n"
session='Aether/Views/Spoofing/Engine/SpoofSession.swift'
keeper=(repo/'Aether/Views/Spoofing/Engine/BackgroundKeepAlive.swift').read_text().replace('import CoreLocation','')
source=r'''
import Foundation
struct CLLocationCoordinate2D {}
struct CLLocation { let coordinate=CLLocationCoordinate2D() }
let kCLLocationAccuracyThreeKilometers=3000.0
protocol CLLocationManagerDelegate: AnyObject {}
enum Authorization {case notDetermined,authorizedWhenInUse,authorizedAlways}
final class CLLocationManager {
 static var latest:CLLocationManager?
 weak var delegate:CLLocationManagerDelegate?
 var desiredAccuracy=0.0;var pausesLocationUpdatesAutomatically=true
 var allowsBackgroundLocationUpdates=false;var showsBackgroundLocationIndicator=false
 var authorizationStatus=Authorization.notDetermined
 var whenRequests=0;var alwaysRequests=0;var starts=0;var stops=0;var running=false
 init(){Self.latest=self}
 func requestWhenInUseAuthorization(){whenRequests+=1;authorizationStatus = .authorizedWhenInUse}
 func requestAlwaysAuthorization(){alwaysRequests+=1;authorizationStatus = .authorizedAlways}
 func startUpdatingLocation(){starts+=1;running=true}
 func stopUpdatingLocation(){stops+=1;running=false}
}
func check(_ condition:@autoclosure ()->Bool,_ message:String){if !condition(){fatalError(message)}}
'''+keeper+declaration(session,'enum SpoofStatus')+r'''
enum UIApplicationState {case active,background}
final class UIApplication {static let shared=UIApplication();var applicationState=UIApplicationState.active}
final class DeviceConnectionManager {static let shared=DeviceConnectionManager();var releases=0;func handleAppBackground(){releases+=1}}
final class Session {
 var status:SpoofStatus = .idle {didSet{handleStatusChange()}}
 let locationKeeper=BackgroundKeepAlive()
 private var mapIsVisible=false;private var appIsForeground=true
 var routeGeneration=0;var routeTask:Task<Void,Never>?
 var audioRunning=false;var retryRunning=false
 func stopJoystick(){};func stopResend(){retryRunning=false};func endBackground(){audioRunning=false}
'''+declaration(session,'func setMapVisible(')+declaration(session,'func setAppForeground(')+declaration(session,'var requiresBackgroundExecution:')+declaration(session,'private func handleStatusChange(')+declaration(session,'private func updateLocationTracking(')+r'''
}
let s=Session();let manager=CLLocationManager.latest!
check(!manager.running && !manager.allowsBackgroundLocationUpdates,"Cold session started background GPS")
s.setMapVisible(true,isForeground:true)
check(manager.running && !manager.allowsBackgroundLocationUpdates,"Visible idle map should use foreground location")
check(manager.whenRequests==1 && manager.alwaysRequests==0,"Opening map requested Always permission")
let starts=manager.starts
s.setMapVisible(true,isForeground:true)
check(manager.starts==starts,"Repeated appearance restarted location updates")
s.setAppForeground(false)
check(!manager.running && !manager.allowsBackgroundLocationUpdates,"Idle map leaked GPS into background")
s.setAppForeground(true)
check(manager.running && !manager.allowsBackgroundLocationUpdates,"Foreground map failed to restore tracking")
s.status = .connecting
check(manager.running && manager.allowsBackgroundLocationUpdates && manager.alwaysRequests==1,"User-requested spoof setup lost background tracking")
s.status = .active
s.setMapVisible(false);s.setAppForeground(false)
check(manager.running && manager.allowsBackgroundLocationUpdates,"Closing map/backgrounding killed active spoof tracking")
s.status = .stopping
check(manager.running,"Pending Stop lost background support before clear finished")
s.status = .idle
check(!manager.running && !manager.allowsBackgroundLocationUpdates,"Successful Stop restarted hidden GPS")
s.setMapVisible(true,isForeground:true)
s.status = .active;s.status = .idle
check(manager.running && !manager.allowsBackgroundLocationUpdates,"Stop should restore foreground-only map location")
s.setMapVisible(false)
check(!manager.running,"Closing idle map failed to stop GPS")
s.status = .active;s.audioRunning=true;s.retryRunning=true;s.status = .dropped("connection lost")
check(!s.audioRunning && !s.retryRunning,"Dropped session retained audio or retry timer")
check(!manager.running,"Unverified location marker kept GPS running without a live session")
do {
 let keeper=BackgroundKeepAlive();let owned=CLLocationManager.latest!
 keeper.setMode(.background)
 check(owned.running,"Fixture must run before destruction")
}
check(!CLLocationManager.latest!.running && CLLocationManager.latest!.delegate == nil,"Location manager not cleaned up on destruction")
print("Spoof location checks passed: idle/map/active/background/stop/drop/destruction")
'''
with tempfile.TemporaryDirectory(prefix='aether-location-') as d:
 p=pathlib.Path(d);(p/'main.swift').write_text(source)
 subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
