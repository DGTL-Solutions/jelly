import XCTest

/// Drives the iPhone/iPad app from a small script, so flows can be tried in the simulator without touching it:
///   TEST_RUNNER_JELLY_ENV="JELLY_SERVER=…;JELLY_USER=…"  launch environment of the app
///   TEST_RUNNER_JELLY_STEPS="waitfor:Start;tap:Filme;shot:filme;wait:2"
///   TEST_RUNNER_JELLY_OUT=/tmp/jelly-ui   where screenshots (`shot:`) and element dumps (`dump:`) go
/// Steps: tap:<label> · tapxy:<x>,<y> (0…1) · longpress:<label> · type:<text> · swipe:up|down|left|right · wait:<s> ·
/// waitfor:<label> · shot:<name> · dump:<name> · home · activate · relaunch
final class ScriptedUITest: XCTestCase {
    func testScript() throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: env["JELLY_OUT"] ?? "/tmp/jelly-ui")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = XCUIApplication()
        for pair in (env["JELLY_ENV"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { app.launchEnvironment[parts[0]] = parts[1] }
        }
        app.launch()
        var log = ""
        func find(_ label: String) -> XCUIElement? {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@ OR identifier == %@", label, label)
            let matches = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            return matches.first { $0.exists && $0.isHittable } ?? matches.first { $0.exists }
        }
        for step in (env["JELLY_STEPS"] ?? "wait:3;shot:launch").split(separator: ";").map(String.init) {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tap", "longpress":
                var element: XCUIElement?
                for _ in 0..<20 where element == nil { element = find(argument); if element == nil { sleep(1) } }
                guard let element else { log += "MISSING \(step)\n"; continue }
                if parts[0] == "tap" { element.tap() } else { element.press(forDuration: 1.2) }
                log += "ok \(step)\n"
            case "tapxy":
                let xy = argument.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap()
            case "type": app.typeText(argument)
            case "swipe":
                switch argument { case "up": app.swipeUp(); case "down": app.swipeDown(); case "left": app.swipeLeft(); default: app.swipeRight() }
            case "wait": Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "waitfor":
                var found = false
                for _ in 0..<30 where !found { found = find(argument) != nil; if !found { sleep(1) } }
                log += (found ? "ok " : "MISSING ") + step + "\n"
            case "shot": try? XCUIScreen.main.screenshot().pngRepresentation.write(to: out.appendingPathComponent(argument + ".png"))
            case "dump": try? app.debugDescription.write(to: out.appendingPathComponent(argument + ".txt"), atomically: true, encoding: .utf8)
            case "home": XCUIDevice.shared.press(.home)
            case "activate": app.activate()
            case "relaunch": app.terminate(); app.launch()
            default: log += "UNKNOWN \(step)\n"
            }
        }
        try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
    }
}
