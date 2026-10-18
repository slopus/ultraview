#if os(iOS) && canImport(XCTest)
import XCTest

/// Real synthesized drags against the demo, read back through the swipe probe.
final class SwipeInteractionTests: XCTestCase {
    private let engines = ["uiKit", "stepped", "keyframe"]

    @MainActor private func launch(_ screen: String, engine: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-screen", "lists", "-listScreen", screen, "-listEngine", engine, "-listSwipeProbe", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.staticTexts["swipeProbe"].waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, ((try? probe(app))?["rowFrames"] as? [String: [Double]])?.isEmpty ?? true { settle(0.2) }
        settle(1.6)
        return app
    }
    @MainActor private func probe(_ app: XCUIApplication) throws -> [String: Any] {
        let text = try XCTUnwrap(app.staticTexts["swipeProbe"].value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    @MainActor private func settle(_ seconds: Double = 0.8) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    @MainActor private func frame(_ app: XCUIApplication, _ identity: String) throws -> CGRect {
        let values = try XCTUnwrap((try probe(app)["rowFrames"] as? [String: [Double]])?[identity], "\(identity) is not on screen")
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
    @MainActor private func point(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    @MainActor private func drag(_ app: XCUIApplication, from: CGPoint, to: CGPoint, speed: Double, hold: Double = 0) {
        point(app, from.x, from.y).press(forDuration: 0.05, thenDragTo: point(app, to.x, to.y), withVelocity: XCUIGestureVelocity(rawValue: speed), thenHoldForDuration: hold)
    }
    @MainActor private func carousel(_ app: XCUIApplication) throws -> (frame: CGRect, position: Double) {
        let frame = try frame(app, "carousel-2")
        let position = try XCTUnwrap((try probe(app)["carousels"] as? [String: Double])?["carousel-2"])
        return (frame, position)
    }
    /// Waits until the carousel stops: a fling's tail can outlast a fixed pause.
    @MainActor private func carouselAtRest(_ app: XCUIApplication) throws -> (frame: CGRect, position: Double) {
        var last = try carousel(app)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            settle(0.3)
            let next = try carousel(app)
            if abs(next.position - last.position) < 0.01 { return next }
            last = next
        }
        return last
    }
    @MainActor private func feedAnchor(_ app: XCUIApplication) throws -> (String, Double) {
        let state = try probe(app)
        return (try XCTUnwrap(state["anchor"] as? String), try XCTUnwrap(state["anchorY"] as? Double))
    }
    @MainActor private func checkMainThread(_ app: XCUIApplication, _ label: String) throws {
        let state = try probe(app)
        let keys = ["turnP99", "rawTurnP99", "turnMax", "turns", "allTurns", "slowestTurns", "hostActions", "mainThreadWork", "seamError", "neighborDrift", "buttonDetach", "ghostButtonDetach", "ghostFrames", "deleteFrames", "performed"]
        let summary = state.filter { keys.contains($0.key) }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("Swipe probe \(label): \(String(decoding: data, as: UTF8.self))")
        XCTAssertEqual(state["mainThreadWork"] as? Int, 0, "\(label): layout, text or drawing ran on main")
        XCTAssertLessThan(state["turnP99"] as? Double ?? 1000, 2, "\(label): main-thread p99")
    }

    @MainActor func testHorizontalDragScrollsTheCarouselAndNeverTheFeed() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let before = try carousel(app), anchor = try feedAnchor(app)
            drag(app, from: .init(x: before.frame.maxX - 40, y: before.frame.midY), to: .init(x: before.frame.minX + 60, y: before.frame.midY), speed: 900)
            settle(2)
            let after = try carousel(app)
            XCTAssertGreaterThan(after.position - before.position, 150, "\(engine): the carousel moved \(after.position - before.position)")
            let anchorAfter = try feedAnchor(app)
            XCTAssertEqual(anchorAfter.0, anchor.0, engine)
            XCTAssertEqual(anchorAfter.1, anchor.1, accuracy: 0.5, "\(engine): the feed moved")
            XCTAssertEqual(after.frame.minY, before.frame.minY, accuracy: 0.5, engine)
            try checkMainThread(app, "carousel \(engine)")
            app.terminate()
        }
    }

    @MainActor func testVerticalDragStartingOnTheCarouselScrollsTheFeed() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let before = try carousel(app), anchor = try feedAnchor(app)
            drag(app, from: .init(x: before.frame.midX, y: before.frame.midY), to: .init(x: before.frame.midX, y: before.frame.midY - 160), speed: 300, hold: 0.3)
            settle(1)
            let after = try carousel(app)
            XCTAssertEqual(after.position, before.position, accuracy: 0.5, "\(engine): the carousel moved")
            XCTAssertLessThan(after.frame.minY - before.frame.minY, -120, "\(engine): the feed didn't follow")
            XCTAssertNotEqual(try feedAnchor(app).1, anchor.1, engine)
            app.terminate()
        }
    }

    @MainActor func testDiagonalDragsLockToTheDominantAxis() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            var state = try carousel(app)
            var anchor = try feedAnchor(app)
            // Mostly horizontal: the carousel takes all of it, including its fling.
            drag(app, from: .init(x: state.frame.maxX - 40, y: state.frame.midY + 20), to: .init(x: state.frame.maxX - 240, y: state.frame.midY - 50), speed: 800)
            var after = try carouselAtRest(app)
            XCTAssertGreaterThan(after.position - state.position, 100, "\(engine)")
            XCTAssertEqual(try feedAnchor(app).1, anchor.1, accuracy: 0.5, "\(engine): a horizontal diagonal moved the feed")
            XCTAssertEqual(after.frame.minY, state.frame.minY, accuracy: 0.5, engine)
            // Mostly vertical: the feed takes it and the carousel stays where it was.
            state = after; anchor = try feedAnchor(app)
            drag(app, from: .init(x: state.frame.midX + 40, y: state.frame.midY + 20), to: .init(x: state.frame.midX - 20, y: state.frame.midY - 150), speed: 300, hold: 0.3)
            settle(1)
            after = try carousel(app)
            XCTAssertEqual(after.position, state.position, accuracy: 0.5, "\(engine): a vertical diagonal moved the carousel")
            XCTAssertLessThan(after.frame.minY - state.frame.minY, -100, "\(engine)")
            app.terminate()
        }
    }

    @MainActor func testTapDuringCarouselDecelerationStopsItWithoutSelecting() throws {
        // UI automation waits for a UIScrollView to stop decelerating before it
        // taps, so the platform engine can't be tapped mid-fling from here.
        for engine in engines where engine != "uiKit" {
            let app = launch("feed", engine: engine)
            let before = try carousel(app)
            drag(app, from: .init(x: before.frame.maxX - 10, y: before.frame.midY), to: .init(x: before.frame.minX + 20, y: before.frame.midY), speed: 4000)
            point(app, before.frame.midX, before.frame.midY).tap()
            let caught = try carousel(app).position
            settle(1.2)
            let after = try carousel(app), state = try probe(app)
            XCTAssertGreaterThan(caught - before.position, 100, "\(engine): the fling didn't start")
            // The second touch on the carousel is the tap; it must have landed mid-flight.
            XCTAssertEqual((state["carouselTouches"] as? [Bool])?.dropFirst().first, true, "\(engine): the tap came after the fling ended: \(state["carouselTouches"] ?? "")")
            XCTAssertEqual(after.position, caught, accuracy: 2, "\(engine): the tap didn't stop the carousel")
            XCTAssertEqual((state["selections"] as? [String])?.count, 0, "\(engine): the stopping tap selected a card")
            // A tap at rest does select, so the check above is meaningful.
            let selected = (state["selections"] as? [String])?.count ?? 0
            point(app, after.frame.midX, after.frame.midY).tap()
            settle(0.3)
            XCTAssertEqual((try probe(app)["selections"] as? [String])?.count, selected + 1, engine)
            app.terminate()
        }
    }

    @MainActor func testRevealThenTapElsewhereClosesWithoutSelecting() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let row = try frame(app, "0")
            drag(app, from: .init(x: row.maxX - 30, y: row.midY), to: .init(x: row.maxX - 150, y: row.midY), speed: 300, hold: 0.15)
            settle()
            var state = try probe(app)
            XCTAssertEqual(state["revealed"] as? String, "0", engine)
            XCTAssertGreaterThanOrEqual(state["maximumRevealOffset"] as? Double ?? 0, 151, engine)
            XCTAssertLessThanOrEqual(state["buttonDetach"] as? Double ?? 1000, 0.5, "\(engine): \(state)")
            // A tap on a carousel card closes the row and doesn't select the card.
            let card = try carousel(app).frame
            point(app, card.midX, card.midY).tap()
            settle()
            state = try probe(app)
            XCTAssertEqual(state["revealed"] as? String, "", engine)
            XCTAssertEqual((state["selections"] as? [String])?.count, 0, "\(engine): the closing tap selected a card")
            XCTAssertEqual((state["performed"] as? [String])?.count, 0, engine)
            // Leading side: reveal Pin and tap it.
            drag(app, from: .init(x: row.minX + 30, y: row.midY), to: .init(x: row.minX + 140, y: row.midY), speed: 300, hold: 0.15)
            settle()
            XCTAssertEqual(try probe(app)["revealed"] as? String, "0", engine)
            point(app, row.minX + 30, row.midY).tap()
            settle()
            state = try probe(app)
            XCTAssertEqual(state["performed"] as? [String], ["pin:0"], engine)
            XCTAssertEqual(state["revealed"] as? String, "", engine)
            try checkMainThread(app, "reveal \(engine)")
            app.terminate()
        }
    }

    @MainActor func testRevealThenVerticalScrollClosesIt() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let row = try frame(app, "0"), anchor = try feedAnchor(app)
            drag(app, from: .init(x: row.maxX - 30, y: row.midY), to: .init(x: row.maxX - 170, y: row.midY), speed: 300, hold: 0.15)
            settle()
            XCTAssertEqual(try probe(app)["revealed"] as? String, "0", engine)
            let below = try frame(app, "1")
            drag(app, from: .init(x: below.midX, y: below.midY), to: .init(x: below.midX, y: below.midY - 120), speed: 300, hold: 0.2)
            settle()
            let state = try probe(app)
            XCTAssertEqual(state["revealed"] as? String, "", engine)
            XCTAssertNotEqual(try feedAnchor(app).1, anchor.1, "\(engine): the vertical drag didn't scroll")
            XCTAssertLessThanOrEqual(state["buttonDetach"] as? Double ?? 1000, 0.5, "\(engine): \(state)")
            app.terminate()
        }
    }

    @MainActor func testFullSwipeDeletesWithContiguousNeighbours() throws {
        for engine in engines {
            let app = launch("feed", engine: engine)
            let rowsBefore = try probe(app)["rows"] as? Int ?? 0
            let row = try frame(app, "1")
            drag(app, from: .init(x: row.maxX - 15, y: row.midY), to: .init(x: row.minX + 15, y: row.midY), speed: 1500)
            settle(1.2)
            let state = try probe(app)
            XCTAssertEqual(state["performed"] as? [String], ["delete:1"], "\(engine): \(state)")
            XCTAssertEqual(state["rows"] as? Int, rowsBefore - 1, engine)
            XCTAssertGreaterThan(state["deleteFrames"] as? Int ?? 0, 10, engine)
            XCTAssertGreaterThan(state["ghostFrames"] as? Int ?? 0, 5, engine)
            XCTAssertLessThanOrEqual(state["seamError"] as? Double ?? 1000, 0.5, "\(engine): \(state["worstSeam"] ?? "")")
            XCTAssertLessThanOrEqual(state["neighborDrift"] as? Double ?? 1000, 0.5, engine)
            XCTAssertLessThanOrEqual(state["ghostButtonDetach"] as? Double ?? 1000, 0.5, engine)
            XCTAssertNil((state["rowFrames"] as? [String: [Double]])?["1"], engine)
            try checkMainThread(app, "delete \(engine)")
            app.terminate()
        }
    }

    /// A touch catches a moving list, so a swipe never starts mid-fling; the
    /// demo applies the delete with momentum in flight, or while the row below resizes.
    @MainActor func testFullSwipeDeleteWhileTheListMoves() throws {
        for engine in engines {
            for stress in ["fling", "resize"] {
                let app = launch("feed", engine: engine, extra: ["-listSwipeStress", stress])
                let label = "\(stress) \(engine)"
                let row = try frame(app, "1"), anchor = try feedAnchor(app)
                drag(app, from: .init(x: row.maxX - 15, y: row.midY), to: .init(x: row.minX + 15, y: row.midY), speed: 1500)
                settle(1.5)
                let state = try probe(app)
                let keys = ["seamError", "neighborDrift", "offscreenDrift", "ghostFrames", "ghostButtonDetach", "turnP99", "turnMax", "mainThreadWork", "departureTrace"]
                let data = try JSONSerialization.data(withJSONObject: state.filter { keys.contains($0.key) }, options: [.sortedKeys])
                print("Swipe stress \(label): \(String(decoding: data, as: UTF8.self))")
                XCTAssertEqual(state["performed"] as? [String], ["delete:1"], label)
                XCTAssertGreaterThan(state["ghostFrames"] as? Int ?? 0, 5, label)
                XCTAssertLessThanOrEqual(state["seamError"] as? Double ?? 1000, 0.5, "\(label): \(state["worstSeam"] ?? "")")
                XCTAssertLessThanOrEqual(state["neighborDrift"] as? Double ?? 1000, 0.5, "\(label): \(state["worstDrift"] ?? "")")
                XCTAssertLessThanOrEqual(state["ghostButtonDetach"] as? Double ?? 1000, 0.5, label)
                XCTAssertEqual(state["mainThreadWork"] as? Int, 0, label)
                if stress == "fling" { XCTAssertNotEqual(try feedAnchor(app).0, anchor.0, "\(label): the fling didn't move the feed") }
                app.terminate()
            }
        }
    }

    @MainActor func testAcrossScreenMutationsKeepCardsContiguous() throws {
        for engine in engines {
            let app = XCUIApplication()
            app.launchArguments = ["-screen", "lists", "-listScreen", "horizontal", "-listEngine", engine, "-listSwipeProbe", "YES"]
            app.launch()
            let list = app.otherElements["horizontalList"]
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            settle(1.5)
            func cards() throws -> (count: Int, position: Double, frames: [(x: Double, width: Double)]) {
                let text = try XCTUnwrap(app.staticTexts["horizontalProbe"].value as? String)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let frames = ((json["frames"] as? [[String: Double]]) ?? []).map { (x: $0["x"] ?? 0, width: $0["width"] ?? 0) }.sorted { $0.x < $1.x }
                return (json["cards"] as? Int ?? 0, json["position"] as? Double ?? 0, frames)
            }
            func checkContiguous(_ label: String) throws {
                let state = try cards()
                XCTAssertGreaterThan(state.frames.count, 2, label)
                for (a, b) in zip(state.frames, state.frames.dropFirst()) {
                    XCTAssertEqual(b.x, a.x + a.width, accuracy: 0.5, "\(engine) \(label): cards don't touch")
                }
            }
            let f = list.frame
            // A fling to the left moves the list along x and lands at rest.
            drag(app, from: .init(x: f.maxX - 20, y: f.midY), to: .init(x: f.minX + 40, y: f.midY), speed: 1200)
            settle(2)
            let flung = try cards()
            XCTAssertGreaterThan(flung.position, 200, engine)
            try checkContiguous("fling")
            for (button, change) in [("horizontalInsert", 1), ("horizontalDelete", -1), ("horizontalMove", 0), ("horizontalResize", 0)] {
                let before = try cards().count
                app.buttons[button].tap()
                settle(0.8)
                XCTAssertEqual(try cards().count, before + change, "\(engine) \(button)")
                try checkContiguous(button)
            }
            app.buttons["horizontalStart"].tap()
            settle(2)
            XCTAssertEqual(try cards().position, 0, accuracy: 0.5, "\(engine): Start")
            app.terminate()
        }
    }

    @MainActor func testChatSwipesWorkWithTheKeyboardUp() throws {
        for engine in engines {
            let app = launch("chat", engine: engine)
            let composer = app.textViews["composer"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            settle(1)
            let top = composer.frame.minY - 12
            func visible() throws -> [(String, CGRect)] {
                try ((probe(app)["rowFrames"] as? [String: [Double]]) ?? [:]).map { ($0.key, CGRect(x: $0.value[0], y: $0.value[1], width: $0.value[2], height: $0.value[3])) }
                    .filter { $0.1.maxY < top && $0.1.minY > 0 && $0.1.height > 30 }.sorted { $0.1.minY > $1.1.minY }
            }
            // Reply from the leading edge; the row is flipped in the list but not on screen.
            let first = try XCTUnwrap(try visible().first)
            drag(app, from: .init(x: first.1.minX + 30, y: first.1.midY), to: .init(x: first.1.minX + 150, y: first.1.midY), speed: 300, hold: 0.15)
            settle()
            XCTAssertEqual(try probe(app)["revealed"] as? String, first.0, engine)
            point(app, first.1.minX + 30, first.1.midY).tap()
            settle()
            XCTAssertTrue((composer.value as? String ?? "").hasPrefix("Reply to"), "\(engine): \(composer.value ?? "")")
            XCTAssertTrue(app.keyboards.firstMatch.exists, engine)
            // Delete the next one with a full swipe.
            let second = try XCTUnwrap(try visible().dropFirst().first)
            drag(app, from: .init(x: second.1.maxX - 15, y: second.1.midY), to: .init(x: second.1.minX + 15, y: second.1.midY), speed: 1500)
            settle(1.2)
            let state = try probe(app)
            XCTAssertEqual(state["performed"] as? [String], ["reply:\(first.0)", "delete:\(second.0)"], "\(engine): \(state)")
            XCTAssertLessThanOrEqual(state["seamError"] as? Double ?? 1000, 0.5, "\(engine): \(state["worstSeam"] ?? "")")
            XCTAssertLessThanOrEqual(state["neighborDrift"] as? Double ?? 1000, 0.5, engine)
            XCTAssertGreaterThan(state["ghostFrames"] as? Int ?? 0, 5, engine)
            XCTAssertTrue(app.keyboards.firstMatch.exists, engine)
            // The budget covers swiping and deleting; the keyboard's own dismissal follows.
            try checkMainThread(app, "chat \(engine)")
            // The interactive keyboard dismissal still owns vertical drags.
            let start = point(app, app.frame.midX, composer.frame.minY - 90), end = point(app, app.frame.midX, app.frame.maxY - 70)
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, engine)
            app.terminate()
        }
    }
}
#endif
