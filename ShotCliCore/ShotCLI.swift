import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private let screenRecordingGrantHint = "Open ShotCli.app, click Request Permission, then enable Screen Recording in System Settings > Privacy & Security."

enum ShotExitCode: Int32 {
    case ok = 0
    case invalidArguments = 2
    case serviceUnavailable = 10
    case missingScreenRecordingPermission = 11
    case missingAccessibilityPermission = 12
    case targetNotFound = 13
    case captureFailed = 14
    case outputFailed = 15
    case cancelled = 130
}

struct ShotRect {
    let x: Int
    let y: Int
    let w: Int
    let h: Int

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }
}

struct ShotError: Error {
    let code: ShotExitCode
    let name: String
    let message: String
    let hint: String?
}

private extension String {
    func expandingTildeInPathIfNeeded() -> String {
        (self as NSString).expandingTildeInPath
    }

    func sanitizedForFilename() -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = components(separatedBy: disallowed).filter { !$0.isEmpty }
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? "unknown" : joined
    }

    func sanitizedForFilenameDotsAllowed() -> String {
        let disallowed = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let parts = components(separatedBy: disallowed).filter { !$0.isEmpty }
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? "capture" : joined
    }
}

private extension CGRect {
    var isEmptyOrNull: Bool {
        isNull || isInfinite || width <= 0 || height <= 0
    }

    var toIntMap: [String: Int] {
        [
            "x": Int(minX.rounded()),
            "y": Int(minY.rounded()),
            "w": Int(width.rounded()),
            "h": Int(height.rounded())
        ]
    }
}

private struct CaptureSource {
    let type: String
    let identifier: UInt32
    let appName: String?
    let title: String?
    let scale: Double?
}

private struct CapturePayload {
    let image: CGImage
    let source: CaptureSource
}

private struct CLIOutput {
    static func writeJSON(_ payload: Any, pretty: Bool, toStdErr: Bool = false) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: pretty ? [.prettyPrinted] : [])
        else {
            writeText("{\"ok\":false,\"error\":{\"code\":14,\"name\":\"ERR_INTERNAL\",\"message\":\"Failed to encode JSON output.\"}}", toStdErr: toStdErr)
            return
        }

        if var text = String(data: data, encoding: .utf8) {
            if !text.hasSuffix("\n") {
                text += "\n"
            }
            writeText(text, toStdErr: toStdErr)
        }
    }

    static func writeText(_ text: String, toStdErr: Bool = false) {
        guard let data = text.data(using: .utf8) else { return }
        if toStdErr {
            FileHandle.standardError.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }

    static func writeData(_ data: Data, toStdErr: Bool = false) {
        if toStdErr {
            FileHandle.standardError.write(data)
        } else {
            FileHandle.standardOutput.write(data)
        }
    }
}

final class ShotCLI {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    func run(arguments: [String]) -> Int32 {
        if arguments.isEmpty {
            printHelp()
            return ShotExitCode.ok.rawValue
        }

        let first = arguments[0]
        if first == "--help" || first == "-h" || first == "help" {
            printHelp()
            return ShotExitCode.ok.rawValue
        }

        do {
            switch first {
            case "version":
                return handleVersion(arguments: Array(arguments.dropFirst()))
            case "doctor":
                return try handleDoctor(arguments: Array(arguments.dropFirst()))
            case "displays":
                return try handleDisplays(arguments: Array(arguments.dropFirst()))
            case "windows":
                return try handleWindows(arguments: Array(arguments.dropFirst()))
            case "capture":
                return try handleCapture(arguments: Array(arguments.dropFirst()))
            default:
                throw ShotError(
                    code: .invalidArguments,
                    name: "ERR_INVALID_ARGUMENTS",
                    message: "Unknown command '\(first)'.",
                    hint: "Run 'shot --help' to list supported commands."
                )
            }
        } catch let error as ShotError {
            emitError(error, pretty: arguments.contains("--pretty"))
            return error.code.rawValue
        } catch {
            let wrapped = ShotError(
                code: .captureFailed,
                name: "ERR_INTERNAL",
                message: "Unexpected failure: \(error.localizedDescription)",
                hint: nil
            )
            emitError(wrapped, pretty: arguments.contains("--pretty"))
            return wrapped.code.rawValue
        }
    }

    private func printHelp() {
        CLIOutput.writeText(
            """
            shot --help
            shot version
            shot doctor [--json] [--pretty]
            shot displays [--json] [--pretty]
            shot windows [--json] [--pretty] [--onscreen|--all] [--app <bundleId|name>] [--frontmost]
            shot capture ( --display <displayId> | --window <windowId> )
                         [--rect <x,y,w,h>] [--crop <x,y,w,h>]
                         [--format png|jpg|heic] [--quality 0-100]
                         [--out <path>|--out-dir <dir>] [--name <template>]
                         [--stdout base64|raw] [--meta]
            """
        )
    }

    private func handleVersion(arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            CLIOutput.writeText("shot version\n")
            return ShotExitCode.ok.rawValue
        }

        let versionInfo = resolveVersionInfo()
        let payload: [String: Any] = [
            "ok": true,
            "version": versionInfo.version,
            "build": versionInfo.build
        ]

        CLIOutput.writeJSON(payload, pretty: arguments.contains("--pretty"))
        return ShotExitCode.ok.rawValue
    }

    private func handleDoctor(arguments: [String]) throws -> Int32 {
        try ensureNoUnknownFlags(arguments, allowed: ["--json", "--pretty"])
        let pretty = arguments.contains("--pretty")

        let hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        let accessibilityTrusted = AXIsProcessTrusted()

        var hints: [String] = []
        if !hasScreenRecordingPermission {
            hints.append(screenRecordingGrantHint)
        }

        let payload: [String: Any] = [
            "ok": hasScreenRecordingPermission,
            "service": [
                "running": true,
                "endpoint": "xpc",
                "name": ShotCLIXPCConstants.serviceName
            ],
            "permissions": [
                "screenRecording": hasScreenRecordingPermission ? "granted" : "missing",
                "accessibility": accessibilityTrusted ? "granted" : "notRequested"
            ],
            "hints": hints
        ]

        CLIOutput.writeJSON(payload, pretty: pretty)
        return hasScreenRecordingPermission ? ShotExitCode.ok.rawValue : ShotExitCode.missingScreenRecordingPermission.rawValue
    }

    private func handleDisplays(arguments: [String]) throws -> Int32 {
        try ensureNoUnknownFlags(arguments, allowed: ["--json", "--pretty"])
        let pretty = arguments.contains("--pretty")
        let screenMap = nsscreenMapByDisplayID()

        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(activeIDs.count), &activeIDs, &displayCount) == .success else {
            throw ShotError(
                code: .captureFailed,
                name: "ERR_DISPLAY_ENUM_FAILED",
                message: "Failed to enumerate active displays.",
                hint: nil
            )
        }

        let displays: [[String: Any]] = activeIDs.prefix(Int(displayCount)).map { displayID in
            let bounds = CGDisplayBounds(displayID)
            let name = screenMap[displayID]?.localizedName ?? "Display \(displayID)"
            let scale = Double(screenMap[displayID]?.backingScaleFactor ?? 1)

            return [
                "displayId": Int(displayID),
                "name": name,
                "isMain": CGDisplayIsMain(displayID) != 0,
                "framePx": bounds.toIntMap,
                "scale": scale,
                "rotation": Int(CGDisplayRotation(displayID).rounded())
            ]
        }

        CLIOutput.writeJSON(["displays": displays], pretty: pretty)
        return ShotExitCode.ok.rawValue
    }

    private func handleWindows(arguments: [String]) throws -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            throw ShotError(
                code: .missingScreenRecordingPermission,
                name: "ERR_PERMISSION_SCREEN_RECORDING",
                message: "Screen Recording permission is required.",
                hint: screenRecordingGrantHint
            )
        }

        var includeAll = false
        var appFilter: String?
        var frontmostOnly = false
        var pretty = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--json":
                break
            case "--pretty":
                pretty = true
            case "--onscreen":
                includeAll = false
            case "--all":
                includeAll = true
            case "--frontmost":
                frontmostOnly = true
            case "--app":
                index += 1
                appFilter = try parseStringValue(arguments, index: index, flag: "--app")
            default:
                throw ShotError(
                    code: .invalidArguments,
                    name: "ERR_INVALID_ARGUMENTS",
                    message: "Unknown option '\(arg)' for windows.",
                    hint: "Run 'shot --help' for command usage."
                )
            }
            index += 1
        }

        let options: CGWindowListOption = includeAll ? [.optionAll] : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw ShotError(
                code: .captureFailed,
                name: "ERR_WINDOW_ENUM_FAILED",
                message: "Failed to enumerate windows.",
                hint: nil
            )
        }

        let displayBounds = activeDisplayBounds()
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let normalizedFilter = appFilter?.lowercased()

        var windows: [[String: Any]] = []
        for info in infos {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pidValue = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let appName = info[kCGWindowOwnerName as String] as? String,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else {
                continue
            }

            let pid = pid_t(pidValue)
            if frontmostOnly, let frontmostPID, frontmostPID != pid {
                continue
            }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleID = runningApp?.bundleIdentifier ?? ""

            if let normalizedFilter {
                let nameMatched = appName.lowercased().contains(normalizedFilter)
                let bundleMatched = bundleID.lowercased().contains(normalizedFilter)
                if !nameMatched && !bundleMatched {
                    continue
                }
            }

            let title = (info[kCGWindowName as String] as? String) ?? ""
            let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let displayHint = displayIDContaining(rect: rect, in: displayBounds)

            windows.append([
                "windowId": Int(windowID),
                "appName": appName,
                "bundleId": bundleID,
                "title": title,
                "isOnScreen": isOnScreen,
                "framePx": rect.toIntMap,
                "displayHint": displayHint as Any
            ])
        }

        CLIOutput.writeJSON(["windows": windows], pretty: pretty)
        return ShotExitCode.ok.rawValue
    }

    private func handleCapture(arguments: [String]) throws -> Int32 {
        var displayID: UInt32?
        var windowID: UInt32?
        var rect: ShotRect?
        var crop: ShotRect?
        var format = "png"
        var quality = 90
        var outPath: String?
        var outDir: String?
        var template: String?
        var stdoutMode: String?
        var pretty = false
        var includeMeta = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--json":
                break
            case "--pretty":
                pretty = true
            case "--meta":
                includeMeta = true
            case "--display":
                index += 1
                displayID = try parseUInt32Value(arguments, index: index, flag: "--display")
            case "--window":
                index += 1
                windowID = try parseUInt32Value(arguments, index: index, flag: "--window")
            case "--rect":
                index += 1
                rect = try parseRectValue(arguments, index: index, flag: "--rect")
            case "--crop":
                index += 1
                crop = try parseRectValue(arguments, index: index, flag: "--crop")
            case "--format":
                index += 1
                format = try parseStringValue(arguments, index: index, flag: "--format")
            case "--quality":
                index += 1
                quality = try parseIntValue(arguments, index: index, flag: "--quality")
            case "--out":
                index += 1
                outPath = try parseStringValue(arguments, index: index, flag: "--out")
            case "--out-dir":
                index += 1
                outDir = try parseStringValue(arguments, index: index, flag: "--out-dir")
            case "--name":
                index += 1
                template = try parseStringValue(arguments, index: index, flag: "--name")
            case "--stdout":
                index += 1
                stdoutMode = try parseStringValue(arguments, index: index, flag: "--stdout")
            default:
                throw ShotError(
                    code: .invalidArguments,
                    name: "ERR_INVALID_ARGUMENTS",
                    message: "Unknown option '\(arg)' for capture.",
                    hint: "Run 'shot --help' for command usage."
                )
            }
            index += 1
        }

        guard (displayID == nil) != (windowID == nil) else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "Exactly one of --display or --window is required.",
                hint: nil
            )
        }

        guard (0 ... 100).contains(quality) else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "--quality must be in range 0...100.",
                hint: nil
            )
        }

        format = format.lowercased()
        guard ["png", "jpg", "heic"].contains(format) else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "--format must be one of png|jpg|heic.",
                hint: nil
            )
        }

        if stdoutMode != nil, outPath != nil || outDir != nil {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "--stdout cannot be combined with --out or --out-dir.",
                hint: nil
            )
        }

        if outPath != nil, outDir != nil {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "--out and --out-dir cannot be used together.",
                hint: nil
            )
        }

        if let stdoutMode {
            let normalized = stdoutMode.lowercased()
            guard normalized == "base64" || normalized == "raw" else {
                throw ShotError(
                    code: .invalidArguments,
                    name: "ERR_INVALID_ARGUMENTS",
                    message: "--stdout must be one of base64|raw.",
                    hint: nil
                )
            }
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw ShotError(
                code: .missingScreenRecordingPermission,
                name: "ERR_PERMISSION_SCREEN_RECORDING",
                message: "Screen Recording permission is required.",
                hint: screenRecordingGrantHint
            )
        }

        let started = Date()

        let captured: CapturePayload
        if let displayID {
            captured = try captureDisplay(displayID: displayID, rect: rect?.cgRect)
        } else if let windowID {
            captured = try captureWindow(windowID: windowID, rect: rect?.cgRect)
        } else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "Missing capture target.",
                hint: nil
            )
        }

        let finalImage = try applyOptionalCrop(crop, to: captured.image)
        let encodedData = try encodeImage(finalImage, format: format, quality: quality)

        if let stdoutMode {
            if stdoutMode.lowercased() == "base64" {
                CLIOutput.writeText(encodedData.base64EncodedString() + "\n")
            } else {
                CLIOutput.writeData(encodedData)
            }
            return ShotExitCode.ok.rawValue
        }

        let outputPath = try resolveOutputPath(
            explicitOutPath: outPath,
            outDir: outDir,
            template: template,
            format: format,
            source: captured.source
        )

        do {
            let outputURL = URL(fileURLWithPath: outputPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try encodedData.write(to: outputURL, options: .atomic)
        } catch {
            throw ShotError(
                code: .outputFailed,
                name: "ERR_OUTPUT_FAILED",
                message: "Failed to write output file: \(error.localizedDescription)",
                hint: nil
            )
        }

        var sourceJSON: [String: Any] = ["type": captured.source.type]
        if captured.source.type == "window" {
            sourceJSON["windowId"] = Int(captured.source.identifier)
            if let appName = captured.source.appName {
                sourceJSON["appName"] = appName
            }
            if let title = captured.source.title {
                sourceJSON["title"] = title
            }
        } else {
            sourceJSON["displayId"] = Int(captured.source.identifier)
        }

        var payload: [String: Any] = [
            "ok": true,
            "output": [
                "path": outputPath,
                "format": format,
                "bytes": encodedData.count
            ],
            "source": sourceJSON,
            "image": [
                "width": finalImage.width,
                "height": finalImage.height,
                "scale": captured.source.scale ?? 1
            ],
            "timingMs": Int(Date().timeIntervalSince(started) * 1000)
        ]

        if includeMeta {
            payload["meta"] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "rectApplied": rect != nil,
                "cropApplied": crop != nil
            ]
        }

        CLIOutput.writeJSON(payload, pretty: pretty)
        return ShotExitCode.ok.rawValue
    }

    private func parseRectValue(_ arguments: [String], index: Int, flag: String) throws -> ShotRect {
        let raw = try parseStringValue(arguments, index: index, flag: flag)
        let components = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 4,
              let x = Int(components[0]),
              let y = Int(components[1]),
              let w = Int(components[2]),
              let h = Int(components[3]),
              w > 0,
              h > 0
        else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "\(flag) expects x,y,w,h with integer values and positive width/height.",
                hint: nil
            )
        }

        return ShotRect(x: x, y: y, w: w, h: h)
    }

    private func parseUInt32Value(_ arguments: [String], index: Int, flag: String) throws -> UInt32 {
        let raw = try parseStringValue(arguments, index: index, flag: flag)
        guard let value = UInt32(raw) else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "\(flag) expects an unsigned integer.",
                hint: nil
            )
        }
        return value
    }

    private func parseIntValue(_ arguments: [String], index: Int, flag: String) throws -> Int {
        let raw = try parseStringValue(arguments, index: index, flag: flag)
        guard let value = Int(raw) else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "\(flag) expects an integer.",
                hint: nil
            )
        }
        return value
    }

    private func parseStringValue(_ arguments: [String], index: Int, flag: String) throws -> String {
        guard index < arguments.count else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "Missing value for \(flag).",
                hint: nil
            )
        }
        return arguments[index]
    }

    private func ensureNoUnknownFlags(_ arguments: [String], allowed: Set<String>) throws {
        for arg in arguments where arg.hasPrefix("-") {
            if !allowed.contains(arg) {
                throw ShotError(
                    code: .invalidArguments,
                    name: "ERR_INVALID_ARGUMENTS",
                    message: "Unknown option '\(arg)'.",
                    hint: "Run 'shot --help' for command usage."
                )
            }
        }
    }

    private func emitError(_ error: ShotError, pretty: Bool) {
        var errorJSON: [String: Any] = [
            "code": Int(error.code.rawValue),
            "name": error.name,
            "message": error.message
        ]
        if let hint = error.hint {
            errorJSON["hint"] = hint
        }

        CLIOutput.writeJSON([
            "ok": false,
            "error": errorJSON
        ], pretty: pretty, toStdErr: true)
    }

    private func nsscreenMapByDisplayID() -> [CGDirectDisplayID: NSScreen] {
        var map: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                map[CGDirectDisplayID(number.uint32Value)] = screen
            }
        }
        return map
    }

    private func activeDisplayBounds() -> [(id: UInt32, rect: CGRect)] {
        var activeIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(activeIDs.count), &activeIDs, &displayCount) == .success else {
            return []
        }

        return activeIDs.prefix(Int(displayCount)).map { id in
            (id: id, rect: CGDisplayBounds(id))
        }
    }

    private func displayIDContaining(rect: CGRect, in displays: [(id: UInt32, rect: CGRect)]) -> Int? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let exact = displays.first(where: { $0.rect.contains(center) }) {
            return Int(exact.id)
        }

        let best = displays
            .map { display -> (id: UInt32, area: CGFloat) in
                let intersection = rect.intersection(display.rect)
                return (id: display.id, area: intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            .max { $0.area < $1.area }

        guard let best, best.area > 0 else { return nil }
        return Int(best.id)
    }

    private func captureDisplay(displayID: UInt32, rect: CGRect?) throws -> CapturePayload {
        let shareable = try fetchShareableContent(onScreenWindowsOnly: false)
        guard let display = shareable.displays.first(where: { $0.displayID == displayID }) else {
            throw ShotError(
                code: .targetNotFound,
                name: "ERR_TARGET_NOT_FOUND",
                message: "displayId \(displayID) not found.",
                hint: nil
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let info = SCShareableContent.info(for: filter)
        let scale = Double(info.pointPixelScale)

        let widthPx = max(1, Int((info.contentRect.width * CGFloat(scale)).rounded()))
        let heightPx = max(1, Int((info.contentRect.height * CGFloat(scale)).rounded()))
        var image = try captureImage(filter: filter, width: widthPx, height: heightPx)

        if let rect {
            let displayBounds = CGDisplayBounds(displayID)
            let intersection = displayBounds.intersection(rect)
            guard !intersection.isEmptyOrNull else {
                throw ShotError(
                    code: .targetNotFound,
                    name: "ERR_TARGET_NOT_FOUND",
                    message: "Requested --rect does not intersect display \(displayID).",
                    hint: nil
                )
            }

            let localTopLeftRect = CGRect(
                x: intersection.minX - displayBounds.minX,
                y: intersection.minY - displayBounds.minY,
                width: intersection.width,
                height: intersection.height
            )
            image = try cropImageFromTopLeft(image, rect: localTopLeftRect, contextFlag: "--rect")
        }

        return CapturePayload(
            image: image,
            source: CaptureSource(
                type: "display",
                identifier: displayID,
                appName: nil,
                title: nil,
                scale: scale
            )
        )
    }

    private func captureWindow(windowID: UInt32, rect: CGRect?) throws -> CapturePayload {
        let shareable = try fetchShareableContent(onScreenWindowsOnly: false)
        guard let window = shareable.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
            throw ShotError(
                code: .targetNotFound,
                name: "ERR_TARGET_NOT_FOUND",
                message: "windowId \(windowID) not found.",
                hint: nil
            )
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = Double(info.pointPixelScale)

        let widthPx = max(1, Int((info.contentRect.width * CGFloat(scale)).rounded()))
        let heightPx = max(1, Int((info.contentRect.height * CGFloat(scale)).rounded()))
        var image = try captureImage(filter: filter, width: widthPx, height: heightPx)

        if let rect {
            guard let windowBounds = windowBoundsPx(windowID: windowID) else {
                throw ShotError(
                    code: .targetNotFound,
                    name: "ERR_TARGET_NOT_FOUND",
                    message: "windowId \(windowID) not found.",
                    hint: nil
                )
            }

            let intersection = windowBounds.intersection(rect)
            guard !intersection.isEmptyOrNull else {
                throw ShotError(
                    code: .targetNotFound,
                    name: "ERR_TARGET_NOT_FOUND",
                    message: "Requested --rect does not intersect window \(windowID).",
                    hint: nil
                )
            }

            let localTopLeftRect = CGRect(
                x: intersection.minX - windowBounds.minX,
                y: intersection.minY - windowBounds.minY,
                width: intersection.width,
                height: intersection.height
            )
            image = try cropImageFromTopLeft(image, rect: localTopLeftRect, contextFlag: "--rect")
        }

        return CapturePayload(
            image: image,
            source: CaptureSource(
                type: "window",
                identifier: windowID,
                appName: window.owningApplication?.applicationName,
                title: window.title,
                scale: scale
            )
        )
    }

    private func fetchShareableContent(onScreenWindowsOnly: Bool) throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SCShareableContent, Error>?

        SCShareableContent.getExcludingDesktopWindows(
            false,
            onScreenWindowsOnly: onScreenWindowsOnly
        ) { shareable, error in
            if let shareable {
                result = .success(shareable)
            } else if let error {
                result = .failure(error)
            } else {
                result = .failure(NSError(domain: "ShotCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown shareable content error"]))
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            throw ShotError(
                code: .serviceUnavailable,
                name: "ERR_SERVICE_UNAVAILABLE",
                message: "Timed out while querying shareable content.",
                hint: "Try running the command again."
            )
        }

        switch result {
        case .success(let shareable):
            return shareable
        case .failure(let error):
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Failed to query shareable content: \(error.localizedDescription)",
                hint: nil
            )
        case .none:
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Failed to query shareable content.",
                hint: nil
            )
        }
    }

    private func captureImage(filter: SCContentFilter, width: Int, height: Int) throws -> CGImage {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CGImage, Error>?

        let config = SCStreamConfiguration()
        config.width = max(1, width)
        config.height = max(1, height)
        config.showsCursor = false

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
            if let image {
                result = .success(image)
            } else if let error {
                result = .failure(error)
            } else {
                result = .failure(NSError(domain: "ShotCLI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown screenshot error"]))
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Timed out while capturing image.",
                hint: nil
            )
        }

        switch result {
        case .success(let image):
            return image
        case .failure(let error):
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Screenshot capture failed: \(error.localizedDescription)",
                hint: nil
            )
        case .none:
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Screenshot capture failed.",
                hint: nil
            )
        }
    }

    private func windowBoundsPx(windowID: UInt32) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
              let windowInfo = infos.first(where: {
                  ((($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value) == windowID)
              }),
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else {
            return nil
        }

        return rect
    }

    private func cropImageFromTopLeft(_ image: CGImage, rect: CGRect, contextFlag: String) throws -> CGImage {
        guard rect.minX >= 0,
              rect.minY >= 0,
              rect.width > 0,
              rect.height > 0,
              rect.maxX <= CGFloat(image.width),
              rect.maxY <= CGFloat(image.height)
        else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "\(contextFlag) exceeds captured image bounds.",
                hint: nil
            )
        }

        let yBottom = CGFloat(image.height) - rect.minY - rect.height
        let cgCropRect = CGRect(x: rect.minX, y: yBottom, width: rect.width, height: rect.height)

        guard let cropped = image.cropping(to: cgCropRect) else {
            throw ShotError(
                code: .captureFailed,
                name: "ERR_CAPTURE_FAILED",
                message: "Failed to crop captured image.",
                hint: nil
            )
        }

        return cropped
    }

    private func applyOptionalCrop(_ crop: ShotRect?, to image: CGImage) throws -> CGImage {
        guard let crop else { return image }

        guard crop.x >= 0, crop.y >= 0 else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "--crop x/y must be >= 0.",
                hint: nil
            )
        }

        let rect = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
        return try cropImageFromTopLeft(image, rect: rect, contextFlag: "--crop")
    }

    private func encodeImage(_ image: CGImage, format: String, quality: Int) throws -> Data {
        let data = NSMutableData()

        let typeIdentifier: CFString
        switch format {
        case "png":
            typeIdentifier = UTType.png.identifier as CFString
        case "jpg":
            typeIdentifier = UTType.jpeg.identifier as CFString
        case "heic":
            typeIdentifier = UTType.heic.identifier as CFString
        default:
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "Unsupported format: \(format).",
                hint: nil
            )
        }

        guard let destination = CGImageDestinationCreateWithData(data, typeIdentifier, 1, nil) else {
            throw ShotError(
                code: .outputFailed,
                name: "ERR_OUTPUT_FAILED",
                message: "Failed to create image encoder for \(format).",
                hint: nil
            )
        }

        var properties: [CFString: Any] = [:]
        if format != "png" {
            properties[kCGImageDestinationLossyCompressionQuality] = Double(quality) / 100.0
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ShotError(
                code: .outputFailed,
                name: "ERR_OUTPUT_FAILED",
                message: "Failed to encode image as \(format).",
                hint: nil
            )
        }

        return data as Data
    }

    private func resolveOutputPath(
        explicitOutPath: String?,
        outDir: String?,
        template: String?,
        format: String,
        source: CaptureSource
    ) throws -> String {
        if let explicitOutPath {
            return explicitOutPath.expandingTildeInPathIfNeeded()
        }

        let targetDir = (outDir ?? FileManager.default.currentDirectoryPath).expandingTildeInPathIfNeeded()
        let sourceName = (source.appName ?? source.type).sanitizedForFilename()
        let datePart = dateFormatter.string(from: Date())
        let idPart = String(source.identifier)
        let chosenTemplate = template ?? "{date}_{app}_{id}.{ext}"

        let filename = chosenTemplate
            .replacingOccurrences(of: "{date}", with: datePart)
            .replacingOccurrences(of: "{app}", with: sourceName)
            .replacingOccurrences(of: "{id}", with: idPart)
            .replacingOccurrences(of: "{ext}", with: format)
            .sanitizedForFilenameDotsAllowed()

        guard !filename.isEmpty else {
            throw ShotError(
                code: .invalidArguments,
                name: "ERR_INVALID_ARGUMENTS",
                message: "Failed to resolve output filename.",
                hint: "Adjust --name template."
            )
        }

        return URL(fileURLWithPath: targetDir).appendingPathComponent(filename).path
    }

    private func resolveVersionInfo() -> (version: String, build: String) {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        {
            return (version: version, build: build)
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let appBundleURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = appBundleURL.appendingPathComponent("Info.plist")

        if let bundle = Bundle(url: appBundleURL),
           let info = bundle.infoDictionary,
           let version = info["CFBundleShortVersionString"] as? String,
           let build = info["CFBundleVersion"] as? String
        {
            return (version: version, build: build)
        }

        if let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
           let version = info["CFBundleShortVersionString"] as? String,
           let build = info["CFBundleVersion"] as? String
        {
            return (version: version, build: build)
        }

        return ("0.1.0", "1")
    }
}
