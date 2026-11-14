import SwiftUI
import UIKit

/// The HibiVo keyboard: a microphone button and a few keys. Recording happens in the app (keyboard
/// extensions can't use the microphone), so this only sends commands and inserts the result.
final class KeyboardViewController: UIInputViewController {
    private static let height: CGFloat = 244

    private var model: KeyboardModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = KeyboardModel(
            host: KeyboardModel.Host(
                insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
                openApp: { [weak self] in self?.openApp() },
                hasFullAccess: { [weak self] in self?.hasFullAccess ?? false }))
        self.model = model

        let keys = KeyboardKeys(
            insert: { [weak self] in self?.textDocumentProxy.insertText($0) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            inputModeSwitch: needsInputModeSwitchKey ? InputModeSwitch(controller: self) : nil)
        let hosting = UIHostingController(rootView: KeyboardView(model: model, keys: keys))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        let height = view.heightAnchor.constraint(equalToConstant: Self.height)
        // Below required, so the system can still size the keyboard during rotation.
        height.priority = .init(999)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        hosting.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model?.appear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.disappear()
    }

    /// Brings the app to the front so it can turn the microphone on.
    ///
    /// iOS has no supported way for a keyboard to open its app, so this reaches the host's
    /// `UIApplication` through the responder chain and calls `openURL:options:completionHandler:`
    /// on it dynamically (the method is marked unavailable to extensions at compile time).
    private func openApp() {
        guard let url = URL(string: KeyboardBridge.sessionURL) else { return }
        typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector),
                let implementation = current.method(for: selector)
            {
                unsafeBitCast(implementation, to: Open.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
        view.window?.windowScene?.open(url, options: nil, completionHandler: nil)
    }
}

/// The text keys next to the microphone button.
struct KeyboardKeys {
    var insert: @MainActor (String) -> Void
    var deleteBackward: @MainActor () -> Void
    /// nil where the system already shows its own globe key (iPhones without a Home button).
    var inputModeSwitch: InputModeSwitch?
}

/// The globe key. It has to be a UIKit control: the system's handler needs the touch event to tell a
/// tap (next keyboard) from a long press (the list of keyboards).
struct InputModeSwitch: UIViewRepresentable {
    weak var controller: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = String(localized: "次のキーボード")
        if let controller {
            button.addTarget(
                controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {}
}
