# Transcription Model Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a native macOS model-management window for Parakeet v3 and v2, make downloads explicit, resume pending transcripts after activation, and show a native stop-square while recording.

**Architecture:** Keep the existing AppKit menu-bar shell and host a focused SwiftUI Settings view in one reusable `NSWindow`. A small typed model catalog and main-actor manager own model metadata, cache state, download progress, and activation; the existing coordinator consumes the active cached model and waits without downloading when none is available.

**Tech Stack:** Swift 6, AppKit, SwiftUI, Swift Package Manager, FluidAudio/Core ML, XCTest, GitHub Actions/CLI for publishing.

---

### Task 1: Add a typed transcription model catalog

**Files:**
- Create: `Sources/quill/Transcription/TranscriptionModel.swift`
- Modify: `Package.swift`
- Create: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Add the test target**

Add this target after the executable target in `Package.swift`:

```swift
.testTarget(
    name: "quillTests",
    dependencies: ["quill"]
),
```

**Step 2: Write the failing catalog tests**

Create `Tests/quillTests/TranscriptionModelSettingsTests.swift`:

```swift
import XCTest
@testable import quill

final class TranscriptionModelSettingsTests: XCTestCase {
    func testV3IsTheRecommendedDefault() {
        XCTAssertEqual(TranscriptionModel.default, .parakeetV3)
        XCTAssertTrue(TranscriptionModel.parakeetV3.isRecommended)
        XCTAssertFalse(TranscriptionModel.parakeetV2.isRecommended)
    }

    func testCatalogExplainsLanguageFit() {
        XCTAssertTrue(TranscriptionModel.parakeetV3.recommendation.contains("Italian"))
        XCTAssertTrue(TranscriptionModel.parakeetV2.recommendation.contains("English"))
    }

    func testModelIdentifiersAreStable() {
        XCTAssertEqual(TranscriptionModel.parakeetV3.rawValue, "parakeet-v3")
        XCTAssertEqual(TranscriptionModel.parakeetV2.rawValue, "parakeet-v2")
        XCTAssertNotEqual(
            TranscriptionModel.parakeetV3.provenance,
            TranscriptionModel.parakeetV2.provenance
        )
    }
}
```

**Step 3: Run the tests to verify they fail**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: compilation fails because `TranscriptionModel` does not exist.

**Step 4: Implement the minimal catalog**

Create `Sources/quill/Transcription/TranscriptionModel.swift`:

```swift
import FluidAudio
import Foundation

enum TranscriptionModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetV3 = "parakeet-v3"
    case parakeetV2 = "parakeet-v2"

    static let `default`: Self = .parakeetV3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT 0.6B v3"
        case .parakeetV2: "Parakeet TDT 0.6B v2"
        }
    }

    var recommendation: String {
        switch self {
        case .parakeetV3: "Best for Italian and multilingual meetings"
        case .parakeetV2: "Best for English-only meetings"
        }
    }

    var languageSummary: String {
        switch self {
        case .parakeetV3: "25 European languages · automatic detection"
        case .parakeetV2: "English only · higher English recall"
        }
    }

    var approximateSize: String { "About 600 MB" }
    var isRecommended: Bool { self == .parakeetV3 }

    var fluidVersion: AsrModelVersion {
        switch self {
        case .parakeetV3: .v3
        case .parakeetV2: .v2
        }
    }

    var provenance: String {
        switch self {
        case .parakeetV3: "parakeet-tdt-0.6b-v3-coreml"
        case .parakeetV2: "parakeet-tdt-0.6b-v2-coreml"
        }
    }
}
```

**Step 5: Run the tests**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: the three catalog tests pass.

**Step 6: Commit**

```bash
git add Package.swift Sources/quill/Transcription/TranscriptionModel.swift Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "feat: add transcription model catalog"
```

### Task 2: Persist model selection without losing configuration

**Files:**
- Modify: `Sources/quill/Config.swift`
- Modify: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Write failing configuration tests**

Add tests which create a temporary `config.json`, then verify:

```swift
func testMissingModelDefaultsToV3() throws {
    let url = try temporaryConfig(["recordings_dir": "/tmp/example"])
    XCTAssertEqual(Config.transcriptionModel(at: url), .parakeetV3)
}

func testSetModelPreservesUnknownKeys() throws {
    let url = try temporaryConfig([
        "recordings_dir": "/tmp/example",
        "custom": ["keep": true],
        "transcription": ["enabled": false, "engine": "parakeet"],
    ])

    try Config.setTranscriptionModel(.parakeetV2, at: url)

    let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    XCTAssertEqual(json["recordings_dir"] as? String, "/tmp/example")
    XCTAssertNotNil(json["custom"])
    let transcription = try XCTUnwrap(json["transcription"] as? [String: Any])
    XCTAssertEqual(transcription["enabled"] as? Bool, false)
    XCTAssertEqual(transcription["engine"] as? String, "parakeet")
    XCTAssertEqual(transcription["model"] as? String, "parakeet-v2")
}
```

Add one private helper in the test class that creates a unique temporary
directory, writes the supplied JSON, and registers teardown removal.

**Step 2: Run the tests to verify they fail**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: compilation fails because the new `Config` APIs do not exist.

**Step 3: Implement read/write APIs**

In `Config.swift`:

- Replace `transcriptionEngine()` with `transcriptionModel(at:)`.
- Make `load(at:)` accept a URL defaulting to `Config.path`.
- Add `setTranscriptionModel(_:at:) throws`.
- Read the existing root dictionary, mutate only
  `root["transcription"]["model"]`, create the parent directory, and write
  `.prettyPrinted`, `.sortedKeys`, and `.atomic`.
- Resolve missing or invalid model identifiers to `.default`.
- Keep the existing `engine` key for backward compatibility but stop using it
  for model selection.

Core implementation:

```swift
static func transcriptionModel(at url: URL = path) -> TranscriptionModel {
    guard
        let raw = (load(at: url)?["transcription"] as? [String: Any])?["model"] as? String,
        let model = TranscriptionModel(rawValue: raw)
    else { return .default }
    return model
}

static func setTranscriptionModel(
    _ model: TranscriptionModel,
    at url: URL = path
) throws {
    var root = load(at: url) ?? [:]
    var transcription = root["transcription"] as? [String: Any] ?? [:]
    transcription["model"] = model.rawValue
    root["transcription"] = transcription
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONSerialization.data(
        withJSONObject: root,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: url, options: .atomic)
}
```

**Step 4: Run the focused tests**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: catalog and configuration tests pass.

**Step 5: Commit**

```bash
git add Sources/quill/Config.swift Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "feat: persist transcription model"
```

### Task 3: Load the selected cached model without downloading

**Files:**
- Modify: `Sources/quill/Transcription/ParakeetEngine.swift`
- Modify: `Sources/quill/Transcription/TranscriptionCoordinator.swift`
- Modify: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Write failing engine-selection tests**

Add tests for the pure model mapping and coordinator factory seam:

```swift
func testSelectedModelControlsProvenance() {
    XCTAssertEqual(
        ParakeetEngine(model: .parakeetV3).model,
        "parakeet-tdt-0.6b-v3-coreml"
    )
    XCTAssertEqual(
        ParakeetEngine(model: .parakeetV2).model,
        "parakeet-tdt-0.6b-v2-coreml"
    )
}
```

**Step 2: Run the test to verify it fails**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests/testSelectedModelControlsProvenance
```

Expected: compilation fails because `ParakeetEngine` has no model initializer.

**Step 3: Make `ParakeetEngine` model-aware**

Change the engine to store `TranscriptionModel`:

```swift
private let selection: TranscriptionModel
nonisolated var model: String { selection.provenance }

init(model: TranscriptionModel) {
    selection = model
}
```

Replace `downloadAndLoad(version: .v2)` in `prepare()` with:

```swift
let version = selection.fluidVersion
let cache = AsrModels.defaultCacheDirectory(for: version)
guard AsrModels.modelsExist(at: cache, version: version) else {
    throw EngineError.modelNotInstalled(selection)
}
let models = try await AsrModels.load(
    from: cache,
    version: version
)
```

Add a user-facing `modelNotInstalled` engine error. The transcription path must
never call `downloadAndLoad`.

Update `TranscriptionCoordinator.preparedEngine()` to construct:

```swift
let engine = ParakeetEngine(model: Config.transcriptionModel())
```

Delete the unknown-engine warning and fallback.

**Step 4: Run focused tests and build**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
swift build -c release
```

Expected: tests pass and the release build completes.

**Step 5: Commit**

```bash
git add Sources/quill/Transcription/ParakeetEngine.swift Sources/quill/Transcription/TranscriptionCoordinator.swift Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "feat: load selected cached model"
```

### Task 4: Add model download and activation state

**Files:**
- Create: `Sources/quill/Transcription/ModelManager.swift`
- Modify: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Write failing state-transition tests**

Use injected async operations so tests do not download models. Cover:

- Initial installed state comes from the cache probe.
- Progress moves the selected row into downloading state.
- Success persists and activates the model.
- Cancellation restores the previous state.
- Failure exposes retry state and does not change the active selection.
- `actionsLocked` prevents download, activation, and deletion.

Representative test:

```swift
@MainActor
func testSuccessfulDownloadActivatesOnlyAfterVerification() async throws {
    let harness = ModelManagerHarness(active: .parakeetV2)
    let manager = harness.makeManager()

    await manager.downloadAndUse(.parakeetV3)

    XCTAssertEqual(manager.activeModel, .parakeetV3)
    XCTAssertEqual(manager.state(for: .parakeetV3), .active)
    XCTAssertEqual(harness.persistedModels, [.parakeetV3])
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: compilation fails because `ModelManager` and its state do not exist.

**Step 3: Implement the minimal manager**

Create a `@MainActor final class ModelManager: ObservableObject` with:

```swift
enum ModelState: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case active
    case failed(String)
}
```

The manager owns:

- `@Published private(set) var states`
- `@Published private(set) var activeModel`
- `@Published var actionsLocked`
- One download `Task` at a time
- A callback invoked after successful activation

Inject only the side effects required for deterministic tests:

```swift
struct Operations {
    var isInstalled: @Sendable (TranscriptionModel) -> Bool
    var downloadAndVerify:
        @Sendable (TranscriptionModel, @escaping @Sendable (Double) -> Void) async throws -> Void
    var persist: @Sendable (TranscriptionModel) throws -> Void
    var delete: @Sendable (TranscriptionModel) throws -> Void
}
```

The production download operation calls
`AsrModels.downloadAndLoad(version:progressHandler:)`, forwards
`progress.fractionCompleted` to the main actor, loads the returned models into
an `AsrManager`, calls `cleanup()`, and then allows persistence. The production
delete operation removes only `AsrModels.defaultCacheDirectory(for:)` for the
inactive model.

**Step 4: Run tests**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: all manager state tests pass.

**Step 5: Commit**

```bash
git add Sources/quill/Transcription/ModelManager.swift Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "feat: manage local transcription models"
```

### Task 5: Wait safely when no model is installed

**Files:**
- Modify: `Sources/quill/Transcription/TranscriptionCoordinator.swift`
- Modify: `Sources/quill/Quill.swift`
- Modify: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Write failing queue-state tests**

Extract a small pure decision that is testable without audio:

```swift
func testMissingModelWaitsWithoutCompletingSession() {
    XCTAssertEqual(
        TranscriptionCoordinator.queueDecision(modelInstalled: false),
        .waitForModel
    )
}
```

Also test that an installed model returns `.transcribe`, and that activation
causes the pending-resume callback to run exactly once.

**Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter TranscriptionModelSettingsTests
```

Expected: compilation fails because the queue decision and waiting status do
not exist.

**Step 3: Implement waiting behavior**

Add:

```swift
case waitingForModel(pending: Int)
```

to coordinator `Status`. Before draining, resolve the selected model and check
its FluidAudio cache. If absent:

- Leave session folders without `transcript.json`.
- Stop the drain instead of repeatedly requeueing.
- Publish `.waitingForModel`.
- Send one notification per transition into waiting.

Add `modelDidActivate(root:)` to call `resumePending(root:)`. Wire the model
manager's activation callback in `AppController` to that method. Update
`showTranscription` to display “transcription waiting for a model”.

Set `modelManager.actionsLocked` whenever recording is active or coordinator
status is `.transcribing`. Keep it locked for the complete transcription job,
not merely model loading.

**Step 4: Run tests and release build**

Run:

```bash
swift test
swift build -c release
```

Expected: all tests and the release build pass.

**Step 5: Commit**

```bash
git add Sources/quill/Transcription/TranscriptionCoordinator.swift Sources/quill/Quill.swift Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "feat: wait for an installed model"
```

### Task 6: Build the native Settings window

**Files:**
- Create: `Sources/quill/UI/SettingsView.swift`
- Create: `Sources/quill/UI/SettingsWindowController.swift`
- Modify: `Sources/quill/UI/MenuBarController.swift`
- Modify: `Sources/quill/Quill.swift`

**Step 1: Add the reusable window controller**

Create `SettingsWindowController` using `NSHostingController` and one retained
`NSWindow`. Configure a standard titled, closable window, autosave its frame,
and reuse it on subsequent **Settings…** actions.

Use a system settings-style title and native toolbar/window materials. Do not
hard-code background, text, accent, light, or dark colors.

**Step 2: Add the focused SwiftUI view**

Create `SettingsView` with one `Transcription Model` section and a card for
each `TranscriptionModel.allCases`. Use semantic SwiftUI styling:

```swift
Form {
    Section("Transcription Model") {
        ForEach(TranscriptionModel.allCases) { model in
            ModelRow(model: model, manager: modelManager)
        }
    }
}
.formStyle(.grouped)
```

Each row contains:

- Model name and a v3 **Recommended** badge.
- Recommendation, language summary, size, and `lock.shield` local-only label.
- `arrow.down.circle`, determinate `ProgressView`, `checkmark.circle`,
  `checkmark.circle.fill`, or `exclamationmark.triangle` according to state.
- **Download & Use**, **Use Model**, **Retry**, cancel, and inactive-model
  deletion actions.

Every icon-only control receives `.accessibilityLabel(...)` and `.help(...)`.
Use a native confirmation dialog before deletion. Show a compact waiting banner
when coordinator status is `.waitingForModel`.

**Step 3: Add the menu entry and app wiring**

Add a **Settings…** item with the standard comma shortcut to
`MenuBarController`, expose `onOpenSettings`, and have `AppController` show the
retained controller. Ensure reopening brings the existing window forward.

**Step 4: Build and manually inspect**

Run:

```bash
swift build -c release
.build/release/quill
```

Expected: the menu contains **Settings…**; one reusable window opens; both
models show the correct states and controls.

Do not start a recording during this inspection. Quit with the menu item or
Control-C.

**Step 5: Commit**

```bash
git add Sources/quill/UI/SettingsView.swift Sources/quill/UI/SettingsWindowController.swift Sources/quill/UI/MenuBarController.swift Sources/quill/Quill.swift
git commit -m "feat: add transcription model settings"
```

### Task 7: Replace the recording tint with a native stop-square

**Files:**
- Modify: `Sources/quill/UI/MenuBarController.swift`

**Step 1: Implement template icon switching**

Keep the feather as the idle template image. Add:

```swift
private static func recordingImage() -> NSImage? {
    NSImage(
        systemSymbolName: "stop.fill",
        accessibilityDescription: "Quill is recording"
    )
}
```

In `update(recording:elapsed:)`, assign the stop image while recording and the
feather while idle. Remove `contentTintColor = .systemRed`; never assign fixed
white or black.

**Step 2: Build and inspect appearance**

Run the release build and inspect:

- Light appearance
- Dark appearance
- Auto appearance
- Clear and Tinted Liquid Glass where available
- Reduce Transparency

Expected: the feather and stop square remain visible using the menu bar's
native template color.

**Step 3: Commit**

```bash
git add Sources/quill/UI/MenuBarController.swift
git commit -m "fix: show native recording state icon"
```

### Task 8: Update diagnostics and documentation

**Files:**
- Modify: `Sources/quill/Doctor.swift`
- Modify: `README.md`
- Modify: `Tests/quillTests/TranscriptionModelSettingsTests.swift`

**Step 1: Write a failing doctor-selection test**

Extract or inject the selected model/cache probe so a focused test verifies
that Doctor reports the selected model name and checks the correct FluidAudio
version.

**Step 2: Implement selected-model diagnostics**

Update `checkTranscription()` to:

- Read `Config.transcriptionModel()`.
- Check the matching cache and version.
- Include the concrete model display name.
- Tell the user to open Settings rather than promising an automatic download.

**Step 3: Update README**

Document:

- Settings-based v2/v3 selection.
- v3 as the Italian/multilingual default.
- v2 as the English-focused option.
- Explicit download behavior.
- Pending-session resumption.
- Native feather/stop-square states.
- `transcription.model` values in the JSON example.

Remove claims that a model automatically downloads on first transcription.

**Step 4: Run checks**

Run:

```bash
swift test
swift build -c release
.build/release/quill doctor
git diff --check
```

Expected: tests and build pass; Doctor either identifies the installed selected
model or directs the user to Settings; the diff has no whitespace errors.

**Step 5: Commit**

```bash
git add Sources/quill/Doctor.swift README.md Tests/quillTests/TranscriptionModelSettingsTests.swift
git commit -m "docs: explain local model selection"
```

### Task 9: Perform end-to-end macOS validation

**Files:**
- No source changes expected

**Step 1: Preserve the baseline binary**

Copy the currently installed baseline binary to a temporary rollback location
outside the repository before replacing it.

**Step 2: Install the branch build per-user**

Run:

```bash
install -m 755 .build/release/quill "$HOME/Library/Application Support/quill/bin/quill"
"$HOME/Library/Application Support/quill/bin/quill" install --launch-at-login
```

Expected: LaunchAgent bootstrap succeeds and the new process remains running.

**Step 3: Verify native UI with Computer Use**

Use the computer-use skill to verify:

- Settings opens once and reuses its window.
- Native materials and semantic colors follow current macOS appearance.
- Model state icons include accessibility labels.
- Actions disable while recording and transcribing.
- The idle feather changes to a native stop square during recording.

Do not accept unexpected privacy prompts without the user's authorization.

**Step 4: Verify model workflows**

With user-approved network and storage use:

1. Download and activate v3.
2. Confirm progress, installed tick, and active state.
3. Record a short Italian sample and verify v3 provenance and intelligible text.
4. Confirm a session made before model installation resumes afterward.
5. Download and activate v2.
6. Record a short English sample and verify v2 provenance.
7. Switch to v3 and delete inactive v2 after confirmation.

Expected: audio stays local, pending sessions remain intact, and each transcript
records the selected concrete model.

**Step 5: Run final checks**

Run:

```bash
swift test
swift build -c release
git diff --check
git status -sb
```

Expected: tests and build pass, no diff errors, and only intentional committed
changes remain.

### Task 10: Push, review, and merge

**Files:**
- No source changes expected

**Step 1: Push the feature branch**

Run:

```bash
git push origin work
```

Expected: `origin/work` advances to the validated implementation.

**Step 2: Open a draft pull request**

Use the GitHub publishing workflow to open a draft PR from `work` to `main`.
The PR body must summarize the model picker, explicit download semantics,
pending-session behavior, native appearance, tests, and manual verification.

**Step 3: Review the complete diff**

Run:

```bash
git diff --stat main...work
git diff --check main...work
gh pr checks --watch
```

Expected: the diff contains only the approved feature, no whitespace errors,
and all repository checks pass.

**Step 4: Mark ready and merge**

After the implementation review confirms the definition of done, mark the PR
ready and squash-merge it:

```bash
gh pr ready
gh pr merge --squash --delete-branch
```

Expected: GitHub reports the PR merged into `main`.

**Step 5: Synchronize and reinstall the merged baseline**

Run:

```bash
git switch main
git pull --ff-only origin main
swift test
swift build -c release
install -m 755 .build/release/quill "$HOME/Library/Application Support/quill/bin/quill"
"$HOME/Library/Application Support/quill/bin/quill" install --launch-at-login
```

Expected: local `main`, GitHub `main`, and the installed Quill binary all
represent the merged release.
