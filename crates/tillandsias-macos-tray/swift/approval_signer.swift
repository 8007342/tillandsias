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
