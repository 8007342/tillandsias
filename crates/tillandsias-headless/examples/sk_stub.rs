//! Order 1880-9wpd: a stand-in FIDO2 authenticator for the approval fixture.
//!
//! An OpenSSH security-key provider (sk-api.h, API 0x000a0000), loaded by
//! `ssh-keygen -w <this .so>` through ssh-sk-helper, so the fixture can enrol
//! an `ed25519-sk` approval key and sign with it on a host with no YubiKey.
//! It follows OpenSSH's own regress/misc/sk-dummy: the key handle is the
//! ed25519 seed (a real authenticator's handle is useless without the
//! device; this one is not, which is why it is a test provider only), the
//! signed data is sha256(application) || flags || counter || sha256(data),
//! and the response echoes the requested flags, so a key enrolled with
//! `-O verify-required` signs with the user-verified bit set.
//!
//! TILLANDSIAS_SK_STUB_MODE selects a failure, for the fixture's arms:
//!   absent   every call answers SSH_SK_ERR_DEVICE_NOT_FOUND (no key plugged in)
//!   decline  enrol works, signing answers SSH_SK_ERR_GENERAL (PIN or touch refused)
//!
//! Built by `cargo build -p tillandsias-headless --example sk_stub` as
//! target/debug/examples/libsk_stub.so. It is never shipped.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, c_char};

const SSH_SK_VERSION_MAJOR: u32 = 0x000a_0000;
const SSH_SK_ED25519: u32 = 0x01;
const SSH_SK_ERR_GENERAL: i32 = -1;
const SSH_SK_ERR_UNSUPPORTED: i32 = -2;
const SSH_SK_ERR_DEVICE_NOT_FOUND: i32 = -4;
const COUNTER: u32 = 0x1234_5678;

#[repr(C)]
pub struct SkEnrollResponse {
    flags: u8,
    public_key: *mut u8,
    public_key_len: usize,
    key_handle: *mut u8,
    key_handle_len: usize,
    signature: *mut u8,
    signature_len: usize,
    attestation_cert: *mut u8,
    attestation_cert_len: usize,
    authdata: *mut u8,
    authdata_len: usize,
}

#[repr(C)]
pub struct SkSignResponse {
    flags: u8,
    counter: u32,
    sig_r: *mut u8,
    sig_r_len: usize,
    sig_s: *mut u8,
    sig_s_len: usize,
}

#[repr(C)]
pub struct SkOption {
    name: *mut c_char,
    value: *mut c_char,
    required: u8,
}

fn mode() -> String {
    std::env::var("TILLANDSIAS_SK_STUB_MODE").unwrap_or_default()
}

/// A malloc'd copy of `b`: OpenSSH frees every buffer with free().
fn c_copy(b: &[u8]) -> *mut u8 {
    // SAFETY: malloc with a nonzero size; the copy stays within the allocation.
    unsafe {
        let p = libc::malloc(b.len().max(1)) as *mut u8;
        if !p.is_null() {
            std::ptr::copy_nonoverlapping(b.as_ptr(), p, b.len());
        }
        p
    }
}

/// Refuse any required option this stub does not know, as sk-dummy does.
unsafe fn options_ok(options: *mut *mut SkOption) -> bool {
    if options.is_null() {
        return true;
    }
    let mut i = 0;
    loop {
        // SAFETY: OpenSSH passes a NULL-terminated array of option pointers.
        let o = unsafe { *options.add(i) };
        if o.is_null() {
            return true;
        }
        // SAFETY: each option is a valid struct for the call's duration.
        if unsafe { (*o).required } != 0 {
            return false;
        }
        i += 1;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn sk_api_version() -> u32 {
    SSH_SK_VERSION_MAJOR
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sk_enroll(
    alg: u32,
    _challenge: *const u8,
    _challenge_len: usize,
    _application: *const c_char,
    flags: u8,
    _pin: *const c_char,
    options: *mut *mut SkOption,
    enroll_response: *mut *mut SkEnrollResponse,
) -> i32 {
    if enroll_response.is_null() {
        return SSH_SK_ERR_GENERAL;
    }
    // SAFETY: checked non-null above.
    unsafe { *enroll_response = std::ptr::null_mut() };
    if mode() == "absent" {
        return SSH_SK_ERR_DEVICE_NOT_FOUND;
    }
    // SAFETY: options is OpenSSH's NULL-terminated array or NULL.
    if alg != SSH_SK_ED25519 || !unsafe { options_ok(options) } {
        return SSH_SK_ERR_UNSUPPORTED;
    }
    let mut seed = [0u8; 32];
    if getrandom::fill(&mut seed).is_err() {
        return SSH_SK_ERR_GENERAL;
    }
    let Ok(kp) = ring::signature::Ed25519KeyPair::from_seed_unchecked(&seed) else {
        return SSH_SK_ERR_GENERAL;
    };
    use ring::signature::KeyPair as _;
    let resp = SkEnrollResponse {
        flags,
        public_key: c_copy(kp.public_key().as_ref()),
        public_key_len: 32,
        key_handle: c_copy(&seed),
        key_handle_len: 32,
        // "Have to return something here" (sk-dummy): an empty signature, no
        // attestation, so nothing identifying a device is ever produced.
        signature: c_copy(&[0]),
        signature_len: 0,
        attestation_cert: std::ptr::null_mut(),
        attestation_cert_len: 0,
        authdata: std::ptr::null_mut(),
        authdata_len: 0,
    };
    // SAFETY: a malloc'd struct OpenSSH frees with free().
    unsafe {
        let p = libc::calloc(1, std::mem::size_of::<SkEnrollResponse>()) as *mut SkEnrollResponse;
        if p.is_null() {
            return SSH_SK_ERR_GENERAL;
        }
        p.write(resp);
        *enroll_response = p;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sk_sign(
    alg: u32,
    data: *const u8,
    data_len: usize,
    application: *const c_char,
    key_handle: *const u8,
    key_handle_len: usize,
    flags: u8,
    _pin: *const c_char,
    options: *mut *mut SkOption,
    sign_response: *mut *mut SkSignResponse,
) -> i32 {
    use sha2::{Digest, Sha256};
    if sign_response.is_null() {
        return SSH_SK_ERR_GENERAL;
    }
    // SAFETY: checked non-null above.
    unsafe { *sign_response = std::ptr::null_mut() };
    match mode().as_str() {
        "absent" => return SSH_SK_ERR_DEVICE_NOT_FOUND,
        "decline" => return SSH_SK_ERR_GENERAL,
        _ => {}
    }
    // SAFETY: options is OpenSSH's NULL-terminated array or NULL.
    if alg != SSH_SK_ED25519 || key_handle_len != 32 || !unsafe { options_ok(options) } {
        return SSH_SK_ERR_UNSUPPORTED;
    }
    // SAFETY: OpenSSH passes valid buffers of the stated lengths and a
    // NUL-terminated application string.
    let (data, handle, app) = unsafe {
        (
            std::slice::from_raw_parts(data, data_len),
            std::slice::from_raw_parts(key_handle, key_handle_len),
            CStr::from_ptr(application).to_bytes(),
        )
    };
    let Ok(kp) = ring::signature::Ed25519KeyPair::from_seed_unchecked(handle) else {
        return SSH_SK_ERR_GENERAL;
    };
    let mut signed = Vec::with_capacity(32 + 1 + 4 + 32);
    signed.extend_from_slice(&Sha256::digest(app));
    signed.push(flags);
    signed.extend_from_slice(&COUNTER.to_be_bytes());
    signed.extend_from_slice(&Sha256::digest(data));
    let sig = kp.sign(&signed);
    let resp = SkSignResponse {
        flags,
        counter: COUNTER,
        sig_r: c_copy(sig.as_ref()),
        sig_r_len: sig.as_ref().len(),
        sig_s: std::ptr::null_mut(),
        sig_s_len: 0,
    };
    // SAFETY: a malloc'd struct OpenSSH frees with free().
    unsafe {
        let p = libc::calloc(1, std::mem::size_of::<SkSignResponse>()) as *mut SkSignResponse;
        if p.is_null() {
            return SSH_SK_ERR_GENERAL;
        }
        p.write(resp);
        *sign_response = p;
    }
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sk_load_resident_keys(
    _pin: *const c_char,
    _options: *mut *mut SkOption,
    _rks: *mut *mut *mut std::ffi::c_void,
    _nrks: *mut usize,
) -> i32 {
    SSH_SK_ERR_UNSUPPORTED
}

/// An example target needs a main only when built as a binary; this one is
/// built as a cdylib (see Cargo.toml), so this is never called.
#[allow(dead_code)]
fn main() {}
