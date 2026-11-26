import XCTest

/// 悬浮按钮 menu, 笔记 list, first-recording intro and recording against the `-demo` backend, where recording,
/// transcription and diarization are faked (every recording becomes the 京都 conversation).
/// Screenshots are attached to the test results.
final class NotesUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-skip-splash", "-demo"]
    }

    private func launch(theme: String? = nil) {
        if let theme { app.launchArguments += ["-theme", theme] }
        app.launch()
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 5))
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Waits out a push / pop before tapping.
    private func tapWhenHittable(_ e: XCUIElement) {
        let ready = NSPredicate { _, _ in e.exists && e.isHittable }
        wait(for: [expectation(for: ready, evaluatedWith: nil)], timeout: 5)
        e.tap()
    }

    private func openMenu() {
        tapWhenHittable(el("fab.menu"))
        XCTAssertTrue(el("menu.new").waitForExistence(timeout: 2))
    }

    /// 录音 from the home menu; the intro the first time.
    private func recordFromMenu(intro: Bool = true, autoOff: Bool = false) {
        openMenu()
        el("menu.record").tap()
        if intro {
            XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
            if autoOff {
                el("intro.auto").tap()
                XCTAssertEqual(el("intro.auto").value as? String, "0")
            }
            el("intro.start").tap()
        }
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
    }

    /// Stops; the notes list is underneath with the new note on top.
    private func stop() -> XCUIElement {
        tapWhenHittable(el("recording.stop"))
        XCTAssertTrue(el("recording.stop").waitForNonExistence(timeout: 3))
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))
        let row = newNote
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertLessThan(row.frame.minY, app.buttons["note.京都讨论"].frame.minY, "newest first")
        return row
    }

    /// The note recorded in this test (the demo seed is 京都讨论).
    private var newNote: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'note.' AND identifier != 'note.京都讨论'")).firstMatch
    }

    func testMenuOpensAndCloses() {
        launch()
        XCTAssertFalse(el("menu.search").exists, "closed menu is not in the hierarchy")
        openMenu()
        for id in ["menu.search", "menu.notes", "menu.record", "menu.new"] {
            XCTAssertTrue(el(id).exists, id)
        }
        XCTAssertLessThan(el("menu.search").frame.minY, el("menu.new").frame.minY, "查找 on top, 新建 Project last")
        sleep(1)
        snap("menu open")
        el("fab.menu").tap()
        XCTAssertTrue(el("menu.search").waitForNonExistence(timeout: 2))

        // The backdrop closes it too.
        openMenu()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(el("menu.new").waitForNonExistence(timeout: 2))

        // 查找 and 笔记 push their screens; 返回 comes back.
        openMenu()
        el("menu.search").tap()
        XCTAssertTrue(app.textFields["查找"].waitForExistence(timeout: 3))
        // The simulator's first keyboard may show its swipe-typing intro over everything.
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 1) { intro.tap() }
        tapWhenHittable(app.buttons["返回"])
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
        openMenu()
        el("menu.notes").tap()
        XCTAssertTrue(app.buttons["note.京都讨论"].waitForExistence(timeout: 3))
        app.buttons["返回"].tap()
        XCTAssertTrue(app.buttons["project.日本旅行"].waitForExistence(timeout: 3))
    }

    func testFirstRecordShowsIntroThenRecords() {
        launch()
        openMenu()
        el("menu.record").tap()
        XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["录完自动整理成任务"].exists)
        XCTAssertEqual(el("intro.auto").value as? String, "1", "自动生成任务 starts on")
        sleep(1)
        snap("intro")
        el("intro.start").tap()
        XCTAssertTrue(el("intro.start").waitForNonExistence(timeout: 2), "closed sheet leaves the hierarchy")
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        XCTAssertEqual(el("recording.locale").value as? String, "中")
        sleep(2)
        snap("recording")
        _ = stop()
        snap("notes after recording")
    }

    func testSecondRecordSkipsIntro() {
        launch()
        recordFromMenu()
        _ = stop()
        el("notes.record").tap()
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        XCTAssertFalse(el("intro.start").exists, "the intro shows only once")
        el("recording.stop").tap()
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))

        // From the home menu too.
        app.buttons["返回"].tap()
        recordFromMenu(intro: false)
        el("recording.stop").tap()
        XCTAssertTrue(el("notes.record").waitForExistence(timeout: 3))
    }

    func testAutoExtractProducesChains() {
        launch()
        recordFromMenu()
        sleep(1)
        let row = stop()
        let counted = NSPredicate { _, _ in Int(row.value as? String ?? "") ?? 0 > 0 }
        wait(for: [expectation(for: counted, evaluatedWith: nil)], timeout: 10)
        sleep(1)
        snap("chain badge")
    }

    func testAutoOffLeavesExtractButton() {
        launch()
        recordFromMenu(autoOff: true)
        let row = stop()
        XCTAssertEqual(el("notes.auto").value as? String, "0", "the list's switch follows the intro")
        // Processed and on the server: the row's value goes from 处理中 to "" (no chains without 自动生成任务).
        let settled = NSPredicate { _, _ in (row.value as? String ?? "") == "" }
        wait(for: [expectation(for: settled, evaluatedWith: nil)], timeout: 10)
        row.tap()
        tapWhenHittable(el("note.tab.chains"))
        XCTAssertTrue(app.buttons["提取"].waitForExistence(timeout: 5))
        snap("note without draft")
    }

    func testSwipeDeleteNote() {
        launch()
        openMenu()
        el("menu.notes").tap()
        let row = app.buttons["note.京都讨论"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let delete = app.buttons["delete：京都讨论"]
        XCTAssertTrue(delete.waitForExistence(timeout: 2))
        sleep(1)
        snap("swiped")
        delete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        sleep(1)
        snap("empty notes")
    }

    func testLocaleChipRemembersChoice() {
        launch()
        recordFromMenu()
        el("recording.locale").tap()
        let ja = el("locale.ja_JP")
        XCTAssertTrue(ja.waitForExistence(timeout: 2))
        sleep(1)
        snap("language sheet")
        ja.tap()
        XCTAssertTrue(ja.waitForNonExistence(timeout: 2))
        XCTAssertEqual(el("recording.locale").value as? String, "日")
        _ = stop()
        el("notes.record").tap()
        XCTAssertTrue(el("recording.locale").waitForExistence(timeout: 3))
        XCTAssertEqual(el("recording.locale").value as? String, "日", "the last language is the default")
        el("recording.stop").tap()
    }

    // MARK: Note detail and drag import

    /// 笔记 › 京都讨论 › 任务链 › 提取: the four chains of the 京都 conversation.
    private func openKyotoChains(theme: String? = nil) {
        launch(theme: theme)
        openMenu()
        el("menu.notes").tap()
        tapWhenHittable(app.buttons["note.京都讨论"])
        XCTAssertTrue(app.staticTexts["下周去京都的行程我们定一下吧，我想第一天先去伏见稻荷大社。"].waitForExistence(timeout: 5))
        tapWhenHittable(el("note.tab.chains"))
        tapWhenHittable(el("note.extract"))
        XCTAssertTrue(el("chain.京都第一天").waitForExistence(timeout: 5))
        sleep(1)
    }

    /// The open dock's geometry (canvas: 12 pt in, 20 pt up, 440 pt tall; rows of 52 + 8 under a 64 pt header).
    private struct Dock {
        let screen: CGRect
        var top: CGFloat { screen.maxY - 20 - 440 }
        var peek: CGPoint { CGPoint(x: screen.midX, y: screen.maxY - 56) }
        /// Row `i` of the list (Project rows, or the opened level's tasks); `at` 0…1 from its top.
        func row(_ i: Int, at: CGFloat = 0.5) -> CGPoint {
            CGPoint(x: screen.midX, y: top + 64 + CGFloat(i) * 60 + 52 * at)
        }
    }

    private var dock: Dock { Dock(screen: app.windows.firstMatch.frame) }

    /// Long press `element`, into the dock, hold on 日本旅行 until it opens, then on to `target`; lift.
    private func dragIntoTrip(_ element: XCUIElement, to target: CGPoint) {
        let start = CGPoint(x: element.frame.midX, y: element.frame.midY)
        let d = dock
        Touch.path(from: start, [
            (CGPoint(x: start.x + 1, y: start.y), 0.7),   // lifted at 420 ms
            (d.peek, 1.1), (d.peek, 1.4),                  // the dock opens
            (d.row(0), 1.7), (d.row(0), 2.6),             // 日本旅行: 520 ms dwell, then its first level
            (CGPoint(x: target.x, y: target.y - 4), 3.0), (target, 3.2), (target, 3.5),
        ], liftAt: 3.6)
    }

    /// `step` moved to 已导入, pointing at `target` (the 「✓ 名」 in the dock is gone again after a second).
    private func waitForImported(_ step: String, into target: String) {
        let row = el("imported.\(step)")
        let ok = NSPredicate { _, _ in row.exists && row.label.hasSuffix("→ \(target)") }
        wait(for: [expectation(for: ok, evaluatedWith: nil)], timeout: 5)
    }

    /// Note detail › 笔记 › home.
    private func backHome() {
        tapWhenHittable(el("note.back"))
        XCTAssertTrue(el("note.back").waitForNonExistence(timeout: 3))
        tapWhenHittable(app.buttons["返回"])
    }

    func testDragChainIntoTask() {
        openKyotoChains()
        snap("chains")
        dragIntoTrip(el("chain.京都第一天"), to: dock.row(1)) // 东京, middle = into
        let ok = el("confirm.nest")
        XCTAssertTrue(ok.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["放入「东京」？"].exists)
        snap("confirm into")
        ok.tap()
        XCTAssertTrue(ok.waitForNonExistence(timeout: 2), "closed confirm leaves the hierarchy")
        sleep(1)
        snap("done")
        waitForImported("伏见稻荷大社", into: "东京")
        XCTAssertTrue(el("dock").waitForNonExistence(timeout: 3), "the dock goes after about a second")
        XCTAssertFalse(el("chain.京都第一天").exists)
        XCTAssertTrue(el("imported.伏见稻荷大社").waitForExistence(timeout: 3))
        snap("imported")

        // 东京 now holds the chain as one task with its three steps.
        backHome()
        openTrip(app)
        tapWhenHittable(app.buttons["进入 东京，6 项"])
        XCTAssertTrue(app.buttons["进入 京都第一天，3 项"].waitForExistence(timeout: 5))
    }

    func testDragStepBeforeTask() {
        openKyotoChains()
        dragIntoTrip(el("step.竹林"), to: dock.row(1, at: 0.1)) // top edge of 东京 = before it
        XCTAssertFalse(el("confirm.nest").waitForExistence(timeout: 1), "before / after don't ask")
        waitForImported("竹林", into: "日本旅行")
        XCTAssertFalse(el("step.竹林").exists)
        XCTAssertTrue(el("step.天龙寺").exists, "the rest of the chain stays")

        backHome()
        openTrip(app)
        let row = { (n: String) in self.app.descendants(matching: .any)["row.\(n)"] }
        XCTAssertTrue(row("竹林").waitForExistence(timeout: 3))
        let ys = ["大阪", "竹林", "东京", "北海道"].map { row($0).frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "竹林 sits between 大阪 and 东京")
    }

    func testDragCancelFliesBack() {
        openKyotoChains()
        let chain = el("chain.京都第一天")
        let before = chain.frame
        // Released over the header: nothing there takes a drop.
        chain.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.6, thenDragTo: el("note.tab.text").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(el("dock").waitForNonExistence(timeout: 3))
        XCTAssertFalse(el("confirm.nest").exists)
        XCTAssertEqual(chain.frame, before)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'imported.'")).firstMatch.exists)
        XCTAssertTrue(app.buttons["note.tab.chains"].isSelected, "the drag didn't tap the tab it ended on")
        snap("after cancel")
    }

    /// The VoiceOver path: a chain's / step's 「加入到项目」 action opens `ImportPicker`. XCUITest can't perform
    /// custom accessibility actions, so `-uitest-pick` opens the picker for these names in turn.
    func testVoiceOverImportPicker() {
        app.launchArguments += ["-uitest-pick", "订京都站附近的酒店,京都第二天"]
        openKyotoChains()
        // A step: 日本旅行 › 放这里 = the end of its first level.
        tapWhenHittable(el("picker.project.日本旅行"))
        sleep(1)
        snap("picker level")
        tapWhenHittable(el("picker.here"))
        waitForImported("订京都站附近的酒店", into: "日本旅行")

        // A whole chain into a task asks first.
        tapWhenHittable(el("picker.project.日本旅行"))
        tapWhenHittable(el("picker.task.北海道"))
        XCTAssertTrue(app.staticTexts["放入「北海道」？"].waitForExistence(timeout: 3))
        tapWhenHittable(el("confirm.nest"))
        waitForImported("岚山小火车", into: "北海道")
        XCTAssertFalse(el("chain.京都第二天").exists)
    }

    func testNoteDetailScreens() {
        openKyotoChains()
        snap("light · chains")
        tapWhenHittable(el("note.tab.text"))
        app.staticTexts["好啊，那我来订酒店，最好住在京都站附近，交通方便一点。"].tap()
        sleep(1)
        snap("light · transcript playing")
    }

    func testNoteDetailScreensDark() {
        openKyotoChains(theme: "dark")
        snap("dark · chains")
        tapWhenHittable(el("note.tab.text"))
        app.staticTexts["好啊，那我来订酒店，最好住在京都站附近，交通方便一点。"].tap()
        sleep(1)
        snap("dark · transcript playing")
    }

    /// Screens for comparing with the canvas (Phone / PhoneDark).
    func testScreensDark() {
        launch(theme: "dark")
        openMenu()
        sleep(1)
        snap("dark · menu")
        el("menu.notes").tap()
        XCTAssertTrue(app.buttons["note.京都讨论"].waitForExistence(timeout: 3))
        sleep(1)
        snap("dark · notes")
        el("notes.record").tap()
        XCTAssertTrue(el("intro.start").waitForExistence(timeout: 3))
        sleep(1)
        snap("dark · intro")
        el("intro.start").tap()
        XCTAssertTrue(el("recording.stop").waitForExistence(timeout: 3))
        sleep(2)
        snap("dark · recording")
        el("recording.locale").tap()
        sleep(1)
        snap("dark · language sheet")
        el("locale.zh_CN").tap()
        XCTAssertTrue(el("locale.zh_CN").waitForNonExistence(timeout: 2))
        _ = stop()
        sleep(2)
        snap("dark · notes after recording")
    }
}

/// One finger along a path, for drags XCUICoordinate can't do (press, then several stops). Uses XCTest's own
/// event synthesis (XCPointerEventPath / XCSynthesizedEventRecord, as WebDriverAgent does); test-only.
enum Touch {
    /// Down at `start`, then to each point by its time (seconds from the press), up at `liftAt`.
    static func path(from start: CGPoint, _ stops: [(CGPoint, TimeInterval)], liftAt: TimeInterval) {
        let path = make("XCPointerEventPath", "initForTouchAtPoint:offset:") { obj, sel, imp in
            typealias Init = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Unmanaged<AnyObject>
            return unsafeBitCast(imp, to: Init.self)(obj, sel, start, 0).takeRetainedValue()
        }
        let move = NSSelectorFromString("moveToPoint:atOffset:")
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        let moveImp = unsafeBitCast(path.method(for: move), to: Move.self)
        for (p, t) in stops { moveImp(path, move, p, t) }
        let lift = NSSelectorFromString("liftUpAtOffset:")
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        unsafeBitCast(path.method(for: lift), to: Lift.self)(path, lift, liftAt)

        let record = make("XCSynthesizedEventRecord", "initWithName:interfaceOrientation:") { obj, sel, imp in
            typealias Init = @convention(c) (AnyObject, Selector, NSString, Int) -> Unmanaged<AnyObject>
            return unsafeBitCast(imp, to: Init.self)(obj, sel, "drag" as NSString, 1).takeRetainedValue()
        }
        _ = record.perform(NSSelectorFromString("addPointerEventPath:"), with: path)

        let synth = XCUIDevice.shared.value(forKey: "eventSynthesizer") as AnyObject
        let sel = NSSelectorFromString("synthesizeEvent:completion:")
        typealias Synth = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (Bool, NSError?) -> Void) -> Void
        let finished = XCTestExpectation(description: "touch path")
        unsafeBitCast(synth.method(for: sel), to: Synth.self)(synth, sel, record) { ok, error in
            XCTAssertTrue(ok, "event synthesis: \(String(describing: error))")
            finished.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: liftAt + 10), .completed)
    }

    /// alloc + an init that takes arguments (which `perform` can't pass).
    private static func make(
        _ className: String, _ initName: String, _ call: (AnyObject, Selector, IMP) -> AnyObject
    ) -> NSObject {
        let cls = NSClassFromString(className) as! NSObject.Type
        let allocated = cls.perform(NSSelectorFromString("alloc"))!.takeRetainedValue()
        let sel = NSSelectorFromString(initName)
        let imp = (allocated as! NSObject).method(for: sel)!
        // init consumes the allocated object.
        _ = Unmanaged.passUnretained(allocated).retain()
        return call(allocated, sel, imp) as! NSObject
    }
}
