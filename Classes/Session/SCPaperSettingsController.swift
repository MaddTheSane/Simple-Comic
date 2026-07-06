//
//  SCPaperSettingsController.swift
//  Simple Comic
//
//  A small floating panel that lets the user tune the paper effect live:
//  sliders for show-through / grain / warmth / black-lift plus a few presets.
//  Everything is stored in NSUserDefaults (see SCPaperFilter) and a change
//  posts SCPaperFilter.settingsChangedNotification so open sessions redraw.
//

import AppKit

@MainActor
@objc(SCPaperSettingsController)
final class SCPaperSettingsController: NSObject {

	@objc(sharedController)
	static let shared = SCPaperSettingsController()

	private struct Knob {
		let key: String
		let title: String
		let min: Double
		let max: Double
	}

	private let knobs: [Knob] = [
		Knob(key: SCPaperFilter.showThroughKey, title: "Paper show-through", min: 0.0, max: 0.8),
		Knob(key: SCPaperFilter.grainKey,       title: "Grain",             min: 0.0, max: 0.4),
		Knob(key: SCPaperFilter.warmthKey,      title: "Warmth",            min: 0.0, max: 1.0),
		Knob(key: SCPaperFilter.blackLiftKey,   title: "Black lift",        min: 0.0, max: 1.0),
	]

	/// Preset name + the parameter bundle it sets.
	private let presets: [(name: String, values: [String: Double])] = [
		("Cream paper", [SCPaperFilter.showThroughKey: 0.38, SCPaperFilter.grainKey: 0.14,
						 SCPaperFilter.warmthKey: 1.0, SCPaperFilter.blackLiftKey: 1.0]),
		("Newsprint",   [SCPaperFilter.showThroughKey: 0.52, SCPaperFilter.grainKey: 0.22,
						 SCPaperFilter.warmthKey: 0.55, SCPaperFilter.blackLiftKey: 1.0]),
		("Manga",       [SCPaperFilter.showThroughKey: 0.20, SCPaperFilter.grainKey: 0.09,
						 SCPaperFilter.warmthKey: 0.25, SCPaperFilter.blackLiftKey: 0.85]),
		("E-Ink",       [SCPaperFilter.showThroughKey: 0.30, SCPaperFilter.grainKey: 0.12,
						 SCPaperFilter.warmthKey: 0.0, SCPaperFilter.blackLiftKey: 1.0]),
	]

	private var panel: NSPanel?
	private var sliders: [String: NSSlider] = [:]
	private var valueLabels: [String: NSTextField] = [:]
	private var presetPopup: NSPopUpButton?

	@objc func showPanel(_ sender: Any?) {
		if panel == nil { panel = buildPanel() }
		syncControls()
		panel?.center()
		panel?.makeKeyAndOrderFront(sender)
	}

	// MARK: - Building

	private func buildPanel() -> NSPanel {
		let grid = NSGridView()
		grid.translatesAutoresizingMaskIntoConstraints = false
		grid.rowSpacing = 10
		grid.columnSpacing = 10

		let popup = NSPopUpButton(frame: .zero, pullsDown: false)
		popup.addItems(withTitles: presets.map { NSLocalizedString($0.name, comment: "Paper effect preset name") }
					   + [NSLocalizedString("Custom", comment: "Paper effect preset: user-adjusted values")])
		popup.target = self
		popup.action = #selector(presetChanged(_:))
		presetPopup = popup
		grid.addRow(with: [label(NSLocalizedString("Preset", comment: "Paper effect preset picker label")),
						   popup, NSGridCell.emptyContentView])

		for knob in knobs {
			let slider = NSSlider(value: knob.min, minValue: knob.min, maxValue: knob.max,
								  target: self, action: #selector(sliderChanged(_:)))
			slider.identifier = NSUserInterfaceItemIdentifier(knob.key)
			slider.isContinuous = true
			slider.widthAnchor.constraint(equalToConstant: 170).isActive = true
			let value = label("")
			value.alignment = .right
			value.widthAnchor.constraint(equalToConstant: 40).isActive = true
			sliders[knob.key] = slider
			valueLabels[knob.key] = value
			grid.addRow(with: [label(NSLocalizedString(knob.title, comment: "Paper effect parameter name")), slider, value])
		}

		let reset = NSButton(title: NSLocalizedString("Reset to Cream", comment: "Paper effect: reset to the default preset"),
							 target: self, action: #selector(resetToDefault(_:)))
		reset.bezelStyle = .rounded
		grid.addRow(with: [NSGridCell.emptyContentView, reset, NSGridCell.emptyContentView])
		grid.column(at: 0).xPlacement = .trailing

		let content = NSView()
		content.addSubview(grid)
		NSLayoutConstraint.activate([
			grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
			grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
			grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
			grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
		])

		let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
						styleMask: [.titled, .closable, .utilityWindow],
						backing: .buffered, defer: false)
		p.title = NSLocalizedString("Paper Effect", comment: "Paper effect settings window title")
		p.isFloatingPanel = true
		p.hidesOnDeactivate = false
		p.isReleasedWhenClosed = false
		p.contentView = content
		return p
	}

	private func label(_ string: String) -> NSTextField {
		NSTextField(labelWithString: string)
	}

	// MARK: - Sync & actions

	private func syncControls() {
		let d = UserDefaults.standard
		for knob in knobs {
			let v = d.object(forKey: knob.key) != nil ? d.double(forKey: knob.key) : knob.min
			sliders[knob.key]?.doubleValue = v
			valueLabels[knob.key]?.stringValue = String(format: "%.2f", v)
		}
		updatePresetSelection()
	}

	@objc private func sliderChanged(_ sender: NSSlider) {
		guard let key = sender.identifier?.rawValue else { return }
		UserDefaults.standard.set(sender.doubleValue, forKey: key)
		valueLabels[key]?.stringValue = String(format: "%.2f", sender.doubleValue)
		updatePresetSelection()
		notifyChanged()
	}

	@objc private func presetChanged(_ sender: NSPopUpButton) {
		let idx = sender.indexOfSelectedItem
		guard idx >= 0 && idx < presets.count else { return }  // "Custom" is a no-op
		let d = UserDefaults.standard
		for (k, v) in presets[idx].values { d.set(v, forKey: k) }
		syncControls()
		notifyChanged()
	}

	@objc private func resetToDefault(_ sender: Any?) {
		guard let popup = presetPopup else { return }
		popup.selectItem(at: 0)
		presetChanged(popup)
	}

	private func updatePresetSelection() {
		let d = UserDefaults.standard
		let match = presets.firstIndex { preset in
			preset.values.allSatisfy { abs(d.double(forKey: $0.key) - $0.value) < 0.001 }
		}
		presetPopup?.selectItem(at: match ?? presets.count)  // last item = "Custom"
	}

	private func notifyChanged() {
		NotificationCenter.default.post(name: SCPaperFilter.settingsChangedNotification, object: nil)
	}
}
