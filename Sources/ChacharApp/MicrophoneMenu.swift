import AppKit
import ChacharCore

/// Builds the "which microphone" menu the listening pill pops up, and writes the choice to the
/// settings store — `AppDelegate.applySettings` then retargets the running engine, so this menu
/// and the Settings picker share one path.
///
/// The list is read from Core Audio each time the menu opens: devices come and go, and a menu
/// built at launch would offer AirPods that left an hour ago.
@MainActor
final class MicrophoneMenu: NSObject {
    private let store: SettingsStore

    init(store: SettingsStore) {
        self.store = store
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinned = store.settings.preferredMicrophone

        let header = NSMenuItem(title: "Dictate with", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Name the device the default resolves to: "System Default" alone hides exactly the thing
        // that changes under you.
        let defaultName = AudioInputDevices.systemDefault()?.name
        let followDefault = item(defaultName.map { "System Default (\($0))" } ?? "System Default",
                                 device: nil)
        followDefault.state = pinned == nil ? .on : .off
        menu.addItem(followDefault)
        menu.addItem(.separator())

        let devices = AudioInputDevices.all()
        for device in devices {
            let entry = item(device.name, device: device)
            entry.state = device.uid == pinned?.uid ? .on : .off
            menu.addItem(entry)
        }
        // A pinned mic that is unplugged stays visible: it is still the choice, and capture falls
        // back to the default only until it returns.
        if let pinned, !devices.contains(where: { $0.uid == pinned.uid }) {
            let missing = item("\(pinned.name) (not connected)", device: pinned)
            missing.state = .on
            missing.isEnabled = false
            menu.addItem(missing)
        }
        return menu
    }

    private func item(_ title: String, device: AudioInputDevice?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = device
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let device = sender.representedObject as? AudioInputDevice
        guard store.settings.preferredMicrophone != device else { return }
        chacharLog("mic chosen: \(device?.name ?? "system default")")
        store.settings.preferredMicrophone = device
    }
}
