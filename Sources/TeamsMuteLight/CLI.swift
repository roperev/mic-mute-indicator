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

    private static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(2)
    }

    private static func usage() -> Never {
        print("""
        Usage: TeamsMuteLight --cli <command>
          devices                                   List connected Kuando / BlinkStick lights
          kuando <#RRGGBB|off> [seconds]            Set the Kuando Busylight color (default 10 s)
          blinkstick <#RRGGBB|off> [seconds] [leds] Set the BlinkStick color
          cycle kuando|blinkstick                   Cycle red/green/blue/amber/off
          ax-dump                                   Print Teams buttons seen via Accessibility
          watch                                     Live-print mute state from both detectors
        Note: ax-dump/watch need Accessibility permission for your terminal app.
        """)
        exit(1)
    }
}
