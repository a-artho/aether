#!/usr/bin/env python3
"""Verify both heterogeneous Codable containers preserve values across worker boundaries."""
import pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[2]
checks = r'''
func requiresSendable<T: Sendable>(_ value: T) {}
let nested = NSMutableDictionary(dictionary: ["name":"before", "items":NSMutableArray(array:["first"])])
let snapshot = AnyCodable(nested)
requiresSendable(snapshot)
nested["name"] = "after"
(nested["items"] as! NSMutableArray).add("second")
let dictionary = snapshot.value as! [String:Any]
precondition(dictionary["name"] as? String == "before")
precondition((dictionary["items"] as? [String]) == ["first"])
let encoded = try JSONEncoder().encode(snapshot)
let decoded = try JSONDecoder().decode(AnyCodable.self, from:encoded)
precondition((decoded.value as! [String:Any])["name"] as? String == "before")
for raw in ["null", "true", "42", "3.25", "\"hello\"", "[1,false,null]", "{\"key\":[2,\"three\"]}"] {
 let value = try JSONDecoder().decode(AnyCodable.self, from:Data(raw.utf8))
 let restored = try JSONDecoder().decode(AnyCodable.self, from:JSONEncoder().encode(value))
 precondition(String(describing:value.value) == String(describing:restored.value))
}
do { _ = try JSONEncoder().encode(AnyCodable(Date())); preconditionFailure("Unsupported values must fail") } catch {}
print("Sendable Codable snapshots and round trips passed")
'''
with tempfile.TemporaryDirectory(prefix='aether-sendable-values-') as d:
 for path in ['Aether/Utilities/AnyCodable.swift','IDeviceKitten/Sources/IDeviceSwift/Utilties/AnyCodable.swift']:
  source=pathlib.Path(d)/'main.swift'; source.write_text((repo/path).read_text()+'\n'+checks)
  executable=pathlib.Path(d)/'checks'
  subprocess.run(['swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors',str(source),'-o',str(executable)],check=True)
  subprocess.run([str(executable)],check=True)
