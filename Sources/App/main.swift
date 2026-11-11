import AppKit

// Writing to a claude process that has already exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

let arguments = CommandLine.arguments
if arguments.contains("--cli") {
    exit(CLI.run(Array(arguments.dropFirst())))
}
if arguments.contains("--list-voices") {
    for voice in SpeechController.voices(prefix: "en") {
        print("\(voice.identifier)\t\(voice.name)\t\(voice.language)\t\(SpeechController.qualityLabel(voice))")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions(arguments: arguments))
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        application.run()
    }
}
