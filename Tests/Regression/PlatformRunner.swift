import UIKit
import ObjectiveC
@main final class Delegate: UIResponder, UIApplicationDelegate {
 var window:UIWindow?
 func application(_ application:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?)->Bool {
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
