import AppKit

/// Dwell-timing settings: the knobs that decide how hover (click-free) mode
/// feels. Exposed as a panel because the right values are personal — a
/// wheelchair-joystick user needs very different pacing from a trackpad user,
/// and asking anyone to edit JSON to find their pace is absurd.
final class SettingsWindow: NSWindow {
    /// Called with the updated config on every slider change.
    var onChange: ((Config) -> Void)?

    private var config: Config
    private var rows: [(slider: NSSlider, value: NSTextField,
                        get: (Config) -> Double, set: (inout Config, Double) -> Void)] = []

    init(config: Config) {
        self.config = config
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = "Dwell Settings"
        isReleasedWhenClosed = false

        let content = NSView(frame: contentLayoutRect)
        contentView = content

        var y: CGFloat = 190
        func addRow(_ label: String, _ hint: String, min: Double, max: Double,
                    get: @escaping (Config) -> Double,
                    set: @escaping (inout Config, Double) -> Void) {
            let name = NSTextField(labelWithString: label)
            name.frame = NSRect(x: 20, y: y + 18, width: 260, height: 18)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            content.addSubview(name)

            let hintField = NSTextField(labelWithString: hint)
            hintField.frame = NSRect(x: 20, y: y + 2, width: 300, height: 14)
            hintField.font = .systemFont(ofSize: 10)
            hintField.textColor = .secondaryLabelColor
            content.addSubview(hintField)

            let value = NSTextField(labelWithString: "\(Int(get(config))) ms")
            value.frame = NSRect(x: 340, y: y + 18, width: 70, height: 18)
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            content.addSubview(value)

            let slider = NSSlider(value: get(config), minValue: min, maxValue: max,
                                  target: self, action: #selector(sliderChanged(_:)))
            slider.frame = NSRect(x: 20, y: y - 22, width: 380, height: 22)
            slider.tag = rows.count
            content.addSubview(slider)

            rows.append((slider, value, get, set))
            y -= 62
        }

        addRow("Start a word / arm tracing",
               "How long to pause on a letter before a word begins",
               min: 200, max: 1500,
               get: { $0.hoverStartDwellMS }, set: { $0.hoverStartDwellMS = $1 })
        addRow("Press a button",
               "How long to hold still on suggestions, space, delete…",
               min: 300, max: 2000,
               get: { $0.dwellActivateMS }, set: { $0.dwellActivateMS = $1 })
        addRow("Type a single letter",
               "Total time resting on one key to type just that letter",
               min: 600, max: 3000,
               get: { $0.hoverLetterDwellMS }, set: { $0.hoverLetterDwellMS = $1 })

        let reset = NSButton(title: "Reset to defaults", target: self,
                             action: #selector(resetDefaults))
        reset.frame = NSRect(x: 20, y: 12, width: 160, height: 28)
        reset.bezelStyle = .rounded
        content.addSubview(reset)

        center()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let row = rows[sender.tag]
        row.set(&config, sender.doubleValue)
        row.value.stringValue = "\(Int(sender.doubleValue)) ms"
        onChange?(config)
    }

    @objc private func resetDefaults() {
        let defaults = Config()
        config.hoverStartDwellMS = defaults.hoverStartDwellMS
        config.dwellActivateMS = defaults.dwellActivateMS
        config.hoverLetterDwellMS = defaults.hoverLetterDwellMS
        for row in rows {
            row.slider.doubleValue = row.get(config)
            row.value.stringValue = "\(Int(row.get(config))) ms"
        }
        onChange?(config)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
