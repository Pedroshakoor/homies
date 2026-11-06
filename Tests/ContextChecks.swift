import AppKit

@main
struct ContextChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = ContextController(root: root)
        let first = try controller.importData(Data("one".utf8), filename: "../test.txt", agentID: "agent")
        let second = try controller.importData(Data("two".utf8), filename: "test.txt", agentID: "agent")
        precondition(first.lastPathComponent == "test.txt" && second.lastPathComponent == "test-1.txt")
        let firstData = try Data(contentsOf: first)
        precondition(firstData == Data("one".utf8))
        do {
            _ = try controller.importData(Data(), filename: "x", agentID: "../escape")
            preconditionFailure("invalid agent accepted")
        } catch ContextController.ContextError.invalidAgent { }
        do {
            _ = try controller.importData(Data(count: 25 * 1024 * 1024 + 1), filename: "x", agentID: "agent")
            preconditionFailure("oversize attachment accepted")
        } catch ContextController.ContextError.tooLarge { }
        let source = root.appendingPathComponent("source.txt")
        try Data("file".utf8).write(to: source)
        let imported = try controller.importFiles([source], agentID: "agent")
        precondition(imported.count == 1)
        let importedData = try Data(contentsOf: imported[0])
        precondition(importedData == Data("file".utf8))
        let promise = NSFilePromiseProvider(fileType: "public.data", delegate: controller)
        promise.userInfo = imported[0]
        let promised = root.appendingPathComponent("promised.txt")
        var promiseError: Error?
        controller.filePromiseProvider(promise, writePromiseTo: promised) { promiseError = $0 }
        precondition(promiseError == nil)
        let promisedData = try Data(contentsOf: promised)
        precondition(promisedData == Data("file".utf8))
        promise.userInfo = source
        controller.filePromiseProvider(promise, writePromiseTo: root.appendingPathComponent("rejected.txt")) { promiseError = $0 }
        precondition(promiseError != nil)
        print("Context checks passed")
    }
}
