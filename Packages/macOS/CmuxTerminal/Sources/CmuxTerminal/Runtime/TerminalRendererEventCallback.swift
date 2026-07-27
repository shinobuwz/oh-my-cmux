internal import CmuxTerminalCore
internal import GhosttyKit

/// C trampoline required by libghostty's renderer-thread callback API.
let terminalRendererEventCallback: @convention(c) (
    UnsafeMutableRawPointer?, ghostty_renderer_event_e
) -> Void = { userdata, event in
    guard event == GHOSTTY_RENDERER_EVENT_MAILBOX_DRAINED,
          let userdata else { return }
    let context = Unmanaged<GhosttySurfaceCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.rendererMailboxDidDrain()
}
