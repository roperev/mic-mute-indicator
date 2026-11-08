import AppKit
import Foundation

/// Proof-of-concept / debugging commands:
///   TeamsMuteLight --cli devices
///   TeamsMuteLight --cli kuando <#RRGGBB|off> [seconds]
///   TeamsMuteLight --cli blinkstick <#RRGGBB|off> [seconds] [ledCount]
///   TeamsMuteLight --cli cycle kuando|blinkstick
///   TeamsMuteLight --cli ax-dump
///   TeamsMuteLight --cli watch
enum CLI {
    static func run(_ args: [String]) -> Never {
        Log.echoToStdout = true
        guard let cmd = args.first else { usage() }

        switch cmd {
        case "devices":
            let infos = HIDDeviceManager.shared.allInfos
            if infos.isEmpty { print("No supported USB lights found (Kuando 27BB:*, 04D8:F848, BlinkStick 20A0:41E5).") }
            for i in infos {
                let kind = i.isKuando ? "Kuando" : i.isBlinkStick ? "BlinkStick" : "?"
                print("\(kind.padding(toLength: 11, withPad: " ", startingAt: 0)) \(i.vidpid)  \(i.manufacturer) \(i.product)  serial=\(i.serial.isEmpty ? "-" : i.serial)")
            }
            for device in MatrixDeviceInfo.connected() {
                print("ESP32 USB   \(device.displayName) (MicMatrix firmware verified on connection)")
            }
            exit(0)

        case "matrix-probe", "matrix-test", "matrix-rainbow", "matrix":
            let matrix = MatrixLight()
            let configuration = AppSettings.load().matrix
            matrix.rotation = configuration.rotation
            matrix.mirrored = configuration.mirrored
            matrix.fullColor = configuration.fullColor
            matrix.colorStyles = configuration.colorStyles
            if cmd == "matrix" {
                guard args.count >= 3, let icon = MatrixIcon(rawValue: args[1]),
                      let color = RGB(string: args[2]) else { usage() }
                let seconds = args.count >= 4 ? Double(args[3]) : 3
                guard let seconds, seconds.isFinite, seconds > 0, seconds <= 60 else {
                    fail("Matrix test duration must be between 0 and 60 seconds.")
                }
                if args.count >= 5 { matrix.serial = args[4] }
                if args.count >= 6 {
                    guard let offset = Int(args[5]), (0...3).contains(offset) else {
                        fail("Matrix orientation offset must be 0...3.")
                    }
                    matrix.rotation = offset
                }
                if args.count >= 7 {
                    guard args[6] == "0" || args[6] == "1" else { fail("Matrix mirror flag must be 0 or 1.") }
                    matrix.mirrored = args[6] == "1"
                }
                if args.count >= 8 {
                    guard args[7] == "mono" || args[7] == "color" else { fail("Artwork mode must be mono or color.") }
                    matrix.fullColor = args[7] == "color"
                    matrix.colorStyles = nil
                }
                matrix.icons.unmuted = icon
                testMatrix(matrix, color: color, seconds: seconds)
            } else {
                if args.count >= 2 { matrix.serial = args[1] }
                testMatrix(matrix, color: .off, seconds: 0.1)
                if cmd == "matrix-rainbow" {
                    let start = Date()
                    while Date().timeIntervalSince(start) < 3 {
                        matrix.applyRainbow(t: Date().timeIntervalSince(start), duration: 3,
                            sweeps: 2, brightness: MatrixFrame.demoLevel)
                        spin(Effects.frameInterval)
                        if matrix.statusText.hasPrefix("Error:") {
                            let error = matrix.statusText
                            matrix.release()
                            fail("Matrix rainbow failed: \(error)")
                        }
                    }
                }
                if cmd == "matrix-test" {
                    for (icon, color) in [(MatrixIcon.microphone, RGB.red), (.mutedMicrophone, .green),
                                          (.fire, .amber), (.prohibited, .blue), (.dot, .green)] {
                        matrix.icons.unmuted = icon
                        print("Showing \(icon.label), \(color.hex), 2% brightness")
                        testMatrix(matrix, color: color, seconds: 1)
                    }
                }
            }
            print(matrix.statusText)
            matrix.release()
            spin(0.2)
            exit(0)

        case "kuando", "blinkstick":
            guard args.count >= 2, let color = RGB(string: args[1]) else { usage() }
            let seconds = args.count >= 3 ? max(1, Double(args[2]) ?? 10) : 10
            let output: LightOutput
            if cmd == "kuando" {
                let k = KuandoLight()
                guard k.connectedDevice != nil else { fail("No Kuando Busylight found.") }
                output = k
            } else {
                let b = BlinkStickLight()
                if args.count >= 4, let n = Int(args[3]) { b.ledCount = n }
                guard b.connectedDevice != nil else { fail("No BlinkStick found.") }
                output = b
            }
            print("\(output.name): \(output.statusText)\nShowing \(color.hex) for \(Int(seconds))s…")
            output.apply(state: .unmuted, color: color, brightness: 1)
            spin(seconds)
            output.release()
            spin(0.2)
            exit(0)

        case "cycle":
            guard args.count >= 2 else { usage() }
            let output: LightOutput = args[1] == "blinkstick" ? BlinkStickLight() : KuandoLight()
            let steps: [(String, RGB)] = [("red", .red), ("green", .green), ("blue", .blue), ("amber", .amber), ("off", .off)]
            for (name, c) in steps {
                print("→ \(name)")
                output.apply(state: .unmuted, color: c, brightness: 1)
                spin(1.5)
            }
            output.release()
            spin(0.2)
            exit(0)

        case "ax-dump":
            print(AccessibilityMonitor.dump())
            exit(0)

        case "watch":
            print("Watching Teams mute state (Ctrl-C to quit)…")
            print("Accessibility trusted: \(AccessibilityMonitor.isTrusted)")
            let ax = AccessibilityMonitor()
            ax.onChange = { r in print("[AX ] \(r.state.label) — \(r.detail)") }
            ax.configure(mutedPattern: AppSettings().axMutedPattern, unmutedPattern: AppSettings().axUnmutedPattern, interval: 0.5)
            ax.start()
            let api = TeamsAPIMonitor()
            api.onChange = { s in
                let inMeeting = s.isInMeeting.map { $0 ? "yes" : "no" } ?? "?"
                let muted = s.isMuted.map { $0 ? "yes" : "no" } ?? "?"
                print("[API] \(s.status.rawValue)  inMeeting=\(inMeeting) muted=\(muted) canPair=\(s.canPair)")
            }
            api.start()
            withExtendedLifetime((ax, api)) { RunLoop.main.run() }
            exit(0)

        default:
            usage()
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func testMatrix(_ matrix: MatrixLight, color: RGB, seconds: Double) {
        let previous = matrix.acknowledgedFrames
        matrix.apply(state: .unmuted, color: color, brightness: MatrixFrame.demoLevel)
        let deadline = Date().addingTimeInterval(5)
        while matrix.acknowledgedFrames == previous && Date() < deadline {
            spin(0.05)
            if matrix.statusText.hasPrefix("Error:") {
                let error = matrix.statusText
                matrix.release()
                fail("Matrix test failed: \(error)")
            }
        }
        guard matrix.acknowledgedFrames > previous else {
            matrix.release()
            fail("Matrix test failed: \(matrix.statusText)")
        }
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if matrix.icons[.unmuted].isAnimated {
                matrix.apply(state: .unmuted, color: color, brightness: MatrixFrame.demoLevel)
            }
            spin(min(0.05, until.timeIntervalSinceNow))
            guard matrix.connectedDevice != nil, matrix.statusText.hasPrefix("OK") else {
                let error = matrix.statusText
                matrix.release()
                fail("Matrix connection failed during test: \(error)")
            }
        }
        if matrix.icons[.unmuted].isAnimated, seconds >= 1 {
            guard matrix.acknowledgedFrames > previous + 2 else {
                matrix.release()
                fail("Matrix animation did not acknowledge changing frames.")
            }
            print("Animated frames acknowledged: \(matrix.acknowledgedFrames - previous)")
        }
    }

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(2)
    }

    private static func usage() -> Never {
        print("""
        Usage: TeamsMuteLight --cli <command>
          devices                                   List HID lights and Espressif USB serial devices
          matrix-probe [serial]                     Verify MicMatrix firmware without lighting LEDs
          matrix-test [serial]                      Show five icons below 2%, then turn off
          matrix-rainbow [serial]                   Full-panel rainbow flow for 3 s at 2%, then off
          matrix <icon> <#RRGGBB|off> [seconds] [serial] [offset] [mirror] [color|mono]
                                                    Show one icon below 2% (default 3 s, maximum 60 s)
                                                    Offset: 0...3; mirror: 0 or 1
          kuando <#RRGGBB|off> [seconds]            Set the Kuando Busylight color (default 10 s)
          blinkstick <#RRGGBB|off> [seconds] [leds] Set the BlinkStick color
          cycle kuando|blinkstick                   Cycle red/green/blue/amber/off
          ax-dump                                   Print Teams buttons seen via Accessibility
          watch                                     Live-print mute state from both detectors
        Note: ax-dump/watch need Accessibility permission for your terminal app.
        Matrix icons: microphone, mutedMicrophone, fire, prohibited, check, dot, orientation,
                      heart, shield, rainbow, headphones, moon, afk, smiley, shrug, warning.
        The legacy "off" identifier is still accepted for a dark CLI frame.
        The legacy identifier "shield" now displays Adobe A.
        Disable the matrix in the app before using its CLI or flashing firmware.
        """)
        exit(1)
    }
}
