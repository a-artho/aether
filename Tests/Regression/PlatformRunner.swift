import UIKit
import ObjectiveC
@main final class Delegate: UIResponder, UIApplicationDelegate {
 var window:UIWindow?
 func application(_ application:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?)->Bool {
  let own=UIApplication.installedApplicationState(for: "com.aether.audit.platformcheck")
  let missing=UIApplication.installedApplicationState(for: "com.aether.audit.doesnotexist")
  print("PLATFORM own=\(String(describing:own)) missing=\(String(describing:missing))")
  precondition(own?.installed==true && own?.version=="1.0")
  precondition(missing?.installed==false)
  let started=ProcessInfo.processInfo.systemUptime
  print("PLATFORM progress=\(String(describing:UIApplication.installProgress(for:"com.aether.audit.doesnotexist",makeSynchronous:false))) elapsed=\(ProcessInfo.processInfo.systemUptime-started)")
  UIAlertController.showAlertWithOk(title:"No window control",message:"Must not crash")
  window=UIWindow(frame:UIScreen.main.bounds);window?.rootViewController=UIViewController();window?.makeKeyAndVisible()
  DispatchQueue.main.asyncAfter(deadline:.now()+1) {
   UIAlertController.showAlertWithOk(title:"Visible control",message:"Must present")
   DispatchQueue.main.asyncAfter(deadline:.now()+1) { [self] in
    precondition(window?.rootViewController?.presentedViewController is UIAlertController)
    print("PLATFORM CHECKS PASSED"); fflush(stdout); exit(0)
   }
  }
  return true
 }
}
