// `sooogood-mcp`: stdio MCP server that forwards tool calls to the running
// Sooogood Video Catch app. Register with an agent, e.g.
//   claude mcp add sooogood -- "/Applications/Sooogood Video Catch.app/Contents/MacOS/sooogood-mcp"
import Foundation
import MediaFetchCore
#if !MEDIAFETCH_STORE_PROFILE
import MediaFetchControl

setvbuf(stdout, nil, _IOLBF, 0)
var client: ControlClient?
// Tests point the helper at their own socket and never launch the real app.
let socketOverride = ProcessInfo.processInfo.environment["MF_CONTROL_SOCKET"].map { URL(fileURLWithPath: $0) }

let session = MCPSession { tool, arguments in
    // Connect lazily so `initialize` / `tools/list` work even before the app starts.
    for attempt in 0..<2 {
        do {
            if client == nil {
                client = try socketOverride.map { try ControlClient(socketURL: $0) } ?? AppConnector.connect()
            }
            return try client!.call(tool, arguments)
        } catch let error as ControlError where error.message == "应用断开了连接" && attempt == 0 {
            client = nil // app restarted: reconnect once
        }
    }
    throw ControlError.failed("应用断开了连接")
}

while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    if let response = session.handle(line: line) {
        print(response)
    }
}
#else
FileHandle.standardError.write(Data("sooogood-mcp is not available in the App Store build\n".utf8))
exit(1)
#endif
