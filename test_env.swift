import Foundation
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
let pipe = Pipe()
task.standardOutput = pipe
try! task.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
print(String(data: data, encoding: .utf8)!)
