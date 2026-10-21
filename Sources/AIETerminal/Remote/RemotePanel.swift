import AppKit

@MainActor
final class RemotePanelController: NSWindowController, NSWindowDelegate {
    private let service: RemoteService
    private let status = NSTextField(labelWithString: "")
    private let url = NSTextField(labelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let qr = NSImageView()
    private let copyLink = NSButton(title: "复制链接", target: nil, action: nil)
    private let openLocal = NSButton(title: "在本机打开", target: nil, action: nil)
    private let toggle = NSButton(title: "开启远程", target: nil, action: nil)
    private let confirm = NSButton(title: "确认配对", target: nil, action: nil)
    private let deny = NSButton(title: "拒绝", target: nil, action: nil)
    private let revoke = NSButton(title: "撤销", target: nil, action: nil)
    private var copiedUntil = Date.distantPast
    private var timer: Timer?

    init(service: RemoteService) {
        self.service = service
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "远程"
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        status.frame = NSRect(x: 20, y: 450, width: 380, height: 24)
        url.frame = NSRect(x: 20, y: 412, width: 380, height: 36)
        url.isSelectable = true
        url.maximumNumberOfLines = 2
        url.lineBreakMode = .byCharWrapping
        url.font = NSFont.systemFont(ofSize: 11)
        copyLink.frame = NSRect(x: 20, y: 378, width: 90, height: 28)
        copyLink.target = self
        copyLink.action = #selector(copyPairingURL)
        openLocal.frame = NSRect(x: 118, y: 378, width: 100, height: 28)
        openLocal.target = self
        openLocal.action = #selector(openPairingURL)
        code.frame = NSRect(x: 20, y: 348, width: 380, height: 24)
        qr.frame = NSRect(x: 110, y: 148, width: 200, height: 186)
        qr.imageScaling = .scaleProportionallyUpOrDown
        toggle.frame = NSRect(x: 20, y: 110, width: 90, height: 32)
        toggle.target = self
        toggle.action = #selector(toggleRemote)
        confirm.frame = NSRect(x: 118, y: 110, width: 90, height: 32)
        confirm.target = self
        confirm.action = #selector(confirmPair)
        deny.frame = NSRect(x: 216, y: 110, width: 80, height: 32)
        deny.target = self
        deny.action = #selector(denyPair)
        revoke.frame = NSRect(x: 304, y: 110, width: 80, height: 32)
        revoke.target = self
        revoke.action = #selector(revokeDevice)
        let hint = NSTextField(wrappingLabelWithString: "开启远程会自动打开临时外网；关闭远程会停隧道。手机扫码配对后，同一浏览器可恢复授权；后台交还控制，回前台可重新请求。")
        hint.frame = NSRect(x: 20, y: 16, width: 380, height: 80)
        content.addSubview(status)
        content.addSubview(url)
        content.addSubview(copyLink)
        content.addSubview(openLocal)
        content.addSubview(code)
        content.addSubview(qr)
        content.addSubview(toggle)
        content.addSubview(confirm)
        content.addSubview(deny)
        content.addSubview(revoke)
        content.addSubview(hint)
        window.contentView = content
        refresh()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        service.applyPendingPublicOrigin()
        status.stringValue = service.note.isEmpty ? "状态：\(service.status)" : service.note
        url.stringValue = service.url.isEmpty ? "远程默认关闭" : service.url
        code.stringValue = service.confirmCode.isEmpty ? "" : "确认码 \(service.confirmCode)"
        qr.image = service.qrImage
        toggle.title = service.enabled ? "关闭远程" : "开启远程"
        copyLink.title = Date() < copiedUntil ? "已复制" : "复制链接"
        copyLink.isEnabled = !service.url.isEmpty
        openLocal.isEnabled = URL(string: service.url) != nil
    }

    @objc func copyPairingURL() {
        guard !service.url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(service.url, forType: .string)
        copiedUntil = Date().addingTimeInterval(2)
        refresh()
    }

    @objc func openPairingURL() {
        guard let link = URL(string: service.url) else { return }
        NSWorkspace.shared.open(link)
    }

    @objc func toggleRemote() {
        service.toggle()
        refresh()
    }

    @objc func confirmPair() {
        service.confirm()
        refresh()
    }

    @objc func denyPair() {
        service.deny()
        refresh()
    }

    @objc func revokeDevice() {
        service.revoke()
        refresh()
    }
}
