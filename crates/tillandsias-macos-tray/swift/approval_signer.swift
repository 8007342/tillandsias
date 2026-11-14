// Order 1886-hf9j: the Secure Enclave half of the macOS approval signer.
//
// CryptoKit is Swift-only, so this file is compiled by build.rs into a static
// library and called from approval_signer.rs over a C ABI. It does the three
// things only CryptoKit can: create a Secure Enclave P-256 key whose private
// half never leaves the enclave, hand back its wrapped `dataRepresentation`
// (usable only by this Mac's enclave, so storing it is not storing a secret),
// and sign with it after LocalAuthentication's check. The SSHSIG envelope
// around the signature is built in Rust.
//
// Every function returns 0 on success and a negative code on failure, and
// writes only into buffers the caller owns.
//
// Design: openspec/changes/os-verified-approval-gates (approval-attestation).

import CryptoKit
import Foundation
import LocalAuthentication
import Security

private let errNoEnclave: Int32 = -1
private let errAccessControl: Int32 = -2
private let errCreate: Int32 = -3
private let errBuffer: Int32 = -4
private let errLoad: Int32 = -5
private let errSign: Int32 = -6
private let errKey: Int32 = -7

private func copyOut(_ data: Data, _ out: UnsafeMutablePointer<UInt8>, _ cap: Int, _ len: UnsafeMutablePointer<Int>) -> Bool {
    if data.count > cap { return false }
    data.copyBytes(to: out, count: data.count)
    len.pointee = data.count
    return true
}

/// 1 when this Mac has a Secure Enclave, else 0.
@_cdecl("tla_se_available")
public func tla_se_available() -> Int32 {
    return SecureEnclave.isAvailable ? 1 : 0
}

/// Create a Secure Enclave key. `biometric` 1 asks for the enrolled
/// fingerprints (`.biometryCurrentSet`), 0 for user presence (Touch ID or the
/// Mac password). Writes the wrapped key and the 65-byte X9.63 public key.
@_cdecl("tla_se_create")
public func tla_se_create(
    _ biometric: Int32,
    _ blobOut: UnsafeMutablePointer<UInt8>, _ blobCap: Int, _ blobLen: UnsafeMutablePointer<Int>,
    _ pubOut: UnsafeMutablePointer<UInt8>, _ pubCap: Int, _ pubLen: UnsafeMutablePointer<Int>
) -> Int32 {
    guard SecureEnclave.isAvailable else { return errNoEnclave }
    let flags: SecAccessControlCreateFlags = biometric != 0
        ? [.privateKeyUsage, .biometryCurrentSet]
        : [.privateKeyUsage, .userPresence]
    var cfErr: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &cfErr
    ) else { return errAccessControl }
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
        return errCreate
    }
    guard copyOut(key.dataRepresentation, blobOut, blobCap, blobLen),
          copyOut(key.publicKey.x963Representation, pubOut, pubCap, pubLen)
    else { return errBuffer }
    return 0
}

/// The 65-byte X9.63 public key of a wrapped Secure Enclave key, with no
/// prompt (reading the public half needs no user check).
@_cdecl("tla_se_public")
public func tla_se_public(
    _ blob: UnsafePointer<UInt8>, _ blobLen: Int,
    _ pubOut: UnsafeMutablePointer<UInt8>, _ pubCap: Int, _ pubLen: UnsafeMutablePointer<Int>
) -> Int32 {
    let data = Data(bytes: blob, count: blobLen)
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) else {
        return errLoad
    }
    return copyOut(key.publicKey.x963Representation, pubOut, pubCap, pubLen) ? 0 : errBuffer
}

/// Sign `msg` (ECDSA P-256, SHA-256) with a wrapped Secure Enclave key. The
/// enclave asks for Touch ID (or the password) showing `reason`; each call is
/// a fresh LAContext, so two signatures are two prompts. Writes the 64-byte
/// raw r||s signature.
@_cdecl("tla_se_sign")
public func tla_se_sign(
    _ blob: UnsafePointer<UInt8>, _ blobLen: Int,
    _ msg: UnsafePointer<UInt8>, _ msgLen: Int,
    _ reason: UnsafePointer<CChar>,
    _ sigOut: UnsafeMutablePointer<UInt8>, _ sigCap: Int, _ sigLen: UnsafeMutablePointer<Int>
) -> Int32 {
    let context = LAContext()
    context.localizedReason = String(cString: reason)
    let data = Data(bytes: blob, count: blobLen)
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(
        dataRepresentation: data, authenticationContext: context
    ) else { return errLoad }
    guard let sig = try? key.signature(for: Data(bytes: msg, count: msgLen)) else {
        return errSign
    }
    return copyOut(sig.rawRepresentation, sigOut, sigCap, sigLen) ? 0 : errBuffer
}

/// Test seam: the same signature from a SOFTWARE P-256 key given as its
/// 32-byte raw scalar, so the SSHSIG envelope can be checked by ssh-keygen
/// without an enclave or a finger. Writes the public key and r||s.
@_cdecl("tla_sw_sign")
public func tla_sw_sign(
    _ raw: UnsafePointer<UInt8>, _ rawLen: Int,
    _ msg: UnsafePointer<UInt8>, _ msgLen: Int,
    _ pubOut: UnsafeMutablePointer<UInt8>, _ pubCap: Int, _ pubLen: UnsafeMutablePointer<Int>,
    _ sigOut: UnsafeMutablePointer<UInt8>, _ sigCap: Int, _ sigLen: UnsafeMutablePointer<Int>
) -> Int32 {
    guard let key = try? P256.Signing.PrivateKey(rawRepresentation: Data(bytes: raw, count: rawLen)) else {
        return errKey
    }
    guard let sig = try? key.signature(for: Data(bytes: msg, count: msgLen)) else {
        return errSign
    }
    guard copyOut(key.publicKey.x963Representation, pubOut, pubCap, pubLen),
          copyOut(sig.rawRepresentation, sigOut, sigCap, sigLen)
    else { return errBuffer }
    return 0
}

// ---------------------------------------------------------------------------
// Orders 2022-89hm / 2022-ygqj: one window, one Touch ID, the whole batch.
// ---------------------------------------------------------------------------

import AppKit

private let errCancelled: Int32 = -8

/// Sign `count` messages with ONE LocalAuthentication evaluation: the context
/// is evaluated once (one Touch ID, or the password where no finger is
/// enrolled), then every signature reuses it with no further prompt. `msgs`
/// is the messages back to back; `lens` their lengths. Writes 64 bytes of
/// r||s per message into `sigOut` (cap >= 64 * count). A failed or
/// cancelled evaluation signs nothing and returns errCancelled.
@_cdecl("tla_se_sign_batch")
public func tla_se_sign_batch(
    _ blob: UnsafePointer<UInt8>, _ blobLen: Int,
    _ msgs: UnsafePointer<UInt8>, _ lens: UnsafePointer<Int>, _ count: Int,
    _ reason: UnsafePointer<CChar>,
    _ sigOut: UnsafeMutablePointer<UInt8>, _ sigCap: Int
) -> Int32 {
    if sigCap < 64 * count { return errBuffer }
    let context = LAContext()
    let why = String(cString: reason)
    var policyErr: NSError?
    let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyErr)
        ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
    let done = DispatchSemaphore(value: 0)
    var ok = false
    context.evaluatePolicy(policy, localizedReason: why) { success, _ in
        ok = success
        done.signal()
    }
    done.wait()
    if !ok { return errCancelled }
    let data = Data(bytes: blob, count: blobLen)
    guard let key = try? SecureEnclave.P256.Signing.PrivateKey(
        dataRepresentation: data, authenticationContext: context
    ) else { return errLoad }
    var sigs: [Data] = []
    var off = 0
    for i in 0..<count {
        let n = lens[i]
        let m = Data(bytes: msgs + off, count: n)
        off += n
        guard let sig = try? key.signature(for: m) else { return errSign }
        sigs.append(sig.rawRepresentation)
    }
    for (i, s) in sigs.enumerated() {
        if s.count != 64 { return errSign }
        s.copyBytes(to: sigOut + 64 * i, count: 64)
    }
    return 0
}

/// The approval window's controller: approve stays disabled until the text
/// has been scrolled to the bottom (a text short enough to need no scroll
/// enables on first full view).
private final class ApprovalWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let scroll: NSScrollView
    let approve: NSButton
    var result: Int32 = 0
    var finished = false
    let onDone: (Int32) -> Void

    init(title: String, body: String, onDone: @escaping (Int32) -> Void) {
        self.onDone = onDone
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        scroll = NSScrollView(frame: NSRect(x: 20, y: 64, width: 580, height: 476))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 476))
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.systemFont(ofSize: 14)
        text.string = body
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        approve = NSButton(title: "Approve with Touch ID", target: nil, action: nil)
        approve.frame = NSRect(x: 420, y: 16, width: 180, height: 32)
        approve.bezelStyle = .rounded
        approve.keyEquivalent = "\r"
        approve.isEnabled = false
        approve.autoresizingMask = [.minXMargin]
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.frame = NSRect(x: 320, y: 16, width: 96, height: 32)
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.autoresizingMask = [.minXMargin]
        let hint = NSTextField(labelWithString: "Scroll to the end to approve.")
        hint.frame = NSRect(x: 20, y: 22, width: 290, height: 20)
        super.init()
        approve.target = self
        approve.action = #selector(onApprove)
        cancel.target = self
        cancel.action = #selector(onCancel)
        window.delegate = self
        let content = window.contentView!
        content.addSubview(scroll)
        content.addSubview(approve)
        content.addSubview(cancel)
        content.addSubview(hint)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(onScroll),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func show() {
        window.center()
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        text_layout()
        onScroll()
    }

    private func text_layout() {
        if let tv = scroll.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
        }
    }

    @objc func onScroll() {
        guard let doc = scroll.documentView else { return }
        let visible = scroll.contentView.documentVisibleRect
        // 4pt slack so a fractional scroll position still counts as the end.
        if visible.maxY >= doc.bounds.height - 4 { approve.isEnabled = true }
    }

    func finish(_ r: Int32) {
        if finished { return }
        finished = true
        result = r
        NotificationCenter.default.removeObserver(self)
        window.delegate = nil
        window.orderOut(nil)
        onDone(r)
    }

    @objc func onApprove() { if approve.isEnabled { finish(1) } }
    @objc func onCancel() { finish(0) }
    func windowWillClose(_ notification: Notification) { finish(0) }
}

private var liveControllers: [ApprovalWindowController] = []

/// Show ONE approval window with `body` and block the CALLING thread (never
/// the main thread) until the user approves (1) or cancels/closes (0).
/// Returns -9 if called on the main thread, which would deadlock.
@_cdecl("tla_approval_window")
public func tla_approval_window(_ title: UnsafePointer<CChar>, _ body: UnsafePointer<CChar>) -> Int32 {
    if Thread.isMainThread { return -9 }
    let t = String(cString: title)
    let b = String(cString: body)
    let done = DispatchSemaphore(value: 0)
    var out: Int32 = 0
    DispatchQueue.main.async {
        let c = ApprovalWindowController(title: t, body: b) { r in
            out = r
            liveControllers.removeAll { $0.finished }
            done.signal()
        }
        liveControllers.append(c)
        c.show()
    }
    done.wait()
    return out
}
