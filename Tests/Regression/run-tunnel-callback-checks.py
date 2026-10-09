#!/usr/bin/env python3
"""Exercise production packet-provider callbacks with delayed NetworkExtension replies."""
import pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[2]
stubs=r'''
import Foundation
import Darwin
class NEVPNProtocol {}
class NETunnelProviderProtocol: NEVPNProtocol { var providerConfiguration:[String:Any]? }
class NEIPv4Settings { var includedRoutes:[NEIPv4Route]=[];var excludedRoutes:[NEIPv4Route]=[];init(addresses:[String],subnetMasks:[String]) {} }
class NEIPv4Route {init(destinationAddress:String,subnetMask:String) {};static func `default`() -> NEIPv4Route { .init(destinationAddress:"",subnetMask:"") } }
class NEPacketTunnelNetworkSettings {var ipv4Settings:NEIPv4Settings?;init(tunnelRemoteAddress:String) {} }
enum NEProviderStopReason {case userInitiated}
final class PacketFlow: @unchecked Sendable {
 var reads:[([Data],[NSNumber])->Void]=[];var writes:[[Data]]=[]
 func readPackets(completionHandler:@escaping ([Data],[NSNumber])->Void) {reads.append(completionHandler)}
 func writePackets(_ packets:[Data],withProtocols:[NSNumber]) {writes.append(packets)}
}
class NEPacketTunnelProvider: @unchecked Sendable {
 var protocolConfiguration:NEVPNProtocol?;let packetFlow=PacketFlow()
 var settingsReplies:[(Error?)->Void]=[]
 func setTunnelNetworkSettings(_ settings:NEPacketTunnelNetworkSettings?,completionHandler:@escaping (Error?)->Void) {settingsReplies.append(completionHandler)}
 func startTunnel(options:[String:NSObject]?,completionHandler:@escaping (Error?)->Void) {}
 func stopTunnel(with reason:NEProviderStopReason,completionHandler:@escaping ()->Void) {}
 func handleAppMessage(_ messageData:Data,completionHandler:((Data?)->Void)?=nil) {}
}
'''
checks=r'''
let provider=PacketTunnelProvider()
var firstReplies=0, cancelled=false, stops=0
provider.startTunnel(options:nil) { error in firstReplies += 1;cancelled=error is CancellationError }
provider.stopTunnel(with:.userInitiated) {stops += 1}
provider.settingsReplies[0](nil)
provider.settingsReplies[0](nil)
provider.settingsReplies[1](nil)
provider.settingsReplies[1](nil)
precondition(firstReplies == 1 && cancelled && stops == 1)
precondition(provider.packetFlow.reads.isEmpty,"Stopped start must not activate packet reading")
var starts=0
provider.startTunnel(options:nil) {error in precondition(error == nil);starts += 1}
provider.settingsReplies[2](nil)
precondition(starts == 1 && provider.packetFlow.reads.count == 1)
var packet=Data(0..<20)
provider.packetFlow.reads[0]([packet],[NSNumber(value:AF_INET)])
precondition(provider.packetFlow.writes.count == 1)
precondition(Array(provider.packetFlow.writes[0][0][12..<16]) == [16,17,18,19])
precondition(Array(provider.packetFlow.writes[0][0][16..<20]) == [12,13,14,15])
provider.stopTunnel(with:.userInitiated) {}
provider.startTunnel(options:nil) {_ in}
provider.settingsReplies[4](nil)
let reads=provider.packetFlow.reads.count,writes=provider.packetFlow.writes.count
provider.packetFlow.reads[1]([packet],[NSNumber(value:AF_INET)])
precondition(provider.packetFlow.reads.count == reads && provider.packetFlow.writes.count == writes,"Old packet callback must not affect restarted tunnel")
print("Tunnel callback cancellation, completion and generation checks passed")
'''
source=(repo/'AetherTunnel/PacketTunnelProvider.swift').read_text().replace('import Network\n','').replace('import NetworkExtension\n','')
with tempfile.TemporaryDirectory(prefix='aether-tunnel-callbacks-') as d:
 path=pathlib.Path(d)/'main.swift';path.write_text(stubs+'\n'+source+'\n'+checks)
 binary=pathlib.Path(d)/'checks'
 subprocess.run(['swiftc',str(path),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
