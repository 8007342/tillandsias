//! ORDER 1244-9dx3 — a quit Apple event drains the VM like the menu Quit.
//!
//! The tray had no application delegate, so a quit Apple event (what
//! `osascript -e 'tell application id "com.tlatoani.tillandsias.tray" to quit'`
//! sends, and what install-macos.sh's graceful stage is meant to send) reached
//! AppKit's default `terminate:`, which exits WITHOUT draining — the VM is torn
//! down by the XPC service and the per-launch `vm-swap.img` survives, the same
//! defect as an unhandled SIGTERM (1426-cb6g). This delegate cancels AppKit's
//! immediate termination and starts the shared graceful quit instead; that path
//! ends the process itself with `exit(0)` once the VM has stopped.

use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{ClassType, DeclaredClass, declare_class, msg_send_id, mutability};
use objc2_app_kit::{NSApplication, NSApplicationDelegate, NSApplicationTerminateReply};
use objc2_foundation::{MainThreadMarker, NSObject, NSObjectProtocol};

declare_class!(
    pub struct TrayAppDelegate;

    // SAFETY: NSObject has no subclassing requirements; an application
    // delegate is main-thread only; TrayAppDelegate does not implement Drop.
    unsafe impl ClassType for TrayAppDelegate {
        type Super = NSObject;
        type Mutability = mutability::MainThreadOnly;
        const NAME: &'static str = "TillandsiasTrayAppDelegate";
    }

    impl DeclaredClass for TrayAppDelegate {}

    unsafe impl NSObjectProtocol for TrayAppDelegate {}

    unsafe impl NSApplicationDelegate for TrayAppDelegate {
        #[method(applicationShouldTerminate:)]
        fn application_should_terminate(&self, _sender: &NSApplication) -> NSApplicationTerminateReply {
            if crate::action_host::request_graceful_quit("quit Apple event") {
                // The drain exits the process when the VM has stopped.
                NSApplicationTerminateReply::NSTerminateCancel
            } else {
                // No action host yet: nothing to drain, terminate normally.
                NSApplicationTerminateReply::NSTerminateNow
            }
        }
    }
);

impl TrayAppDelegate {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = mtm.alloc::<Self>().set_ivars(());
        unsafe { msg_send_id![super(this), init] }
    }
}

/// Install the delegate on `app` and return it: the caller must keep it alive
/// for the life of the run loop (NSApplication holds its delegate weakly).
pub fn install(mtm: MainThreadMarker, app: &NSApplication) -> Retained<TrayAppDelegate> {
    let delegate = TrayAppDelegate::new(mtm);
    app.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    delegate
}
