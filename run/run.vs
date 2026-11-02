// Package run runs a schedule: in a window, a frame per display refresh
// (events to the program, the schedule run for the time since the last
// frame, the program's pixels presented), or headless, as fast as it can
// (servers, tests, training).
//
//     return await run.Window(title: "npc-sim", schedule: s,
//                             draw: { w, h in renderer.Frame(…) },
//                             handle: { event in … true })
//
// Or on the GPU: the program draws on the device and presents to the
// window's gpu.Layer itself, at the window's own pixels, nothing read
// back (run.Window(…, present:, …)).
//
// RUN_TRACE=1 in the environment prints each system's cost once a
// second; RUN_QUIT_AFTER=seconds quits by itself, for timing a program
// with no one at it.
package run

import (
    "entity/schedule"
    "gpu"
    "os/env"
    "time"
    "ui/window"
)

/// Options are a window's.
public struct Options {
    public var Width: float32 = 1280
    public var Height: float32 = 720
    public var MinWidth: float32 = 480
    public var MinHeight: float32 = 300
    /// Frames are drawn at the window's size in points and stretched to
    /// its pixels: a quarter of the work on a Retina display.
    public var Stretch = true
    /// Asked after each frame: true closes the window (a demo that has
    /// played, a test that has seen what it wanted).
    public var Done: (() -> bool)? = nil
    /// On the GPU (present:): how much of the window's pixels to draw at,
    /// 1 the window's own (Retina), less to trade sharpness for speed; the
    /// layer scales it to fit.
    public var Scale: float32 = 1

    public init() {}
}

/// Frame is what the draw callback knows of the frame it draws.
public struct Frame {
    public var Width: int
    public var Height: int
    /// Seconds since the last frame, and since the window opened.
    public var Dt: float32
    public var Time: float64
}

/// Window opens a window and runs the schedule in it until the window is
/// closed or `handle` answers false. `draw` makes each frame's pixels
/// (RGBA, top row first, width × height); `handle` gets every event but
/// frames. Answers the program's exit status.
@MainActor
public func Window(title: string, options: Options = Options(), schedule s: schedule.Schedule,
                   draw: (Frame) -> [uint8], handle: (window.Window, window.Event) -> bool) async -> int32 {
    var o = window.Options()
    o.MinSize = window.Size(options.MinWidth, options.MinHeight)
    let win: window.Window
    do {
        win = try window.Create(title: title, size: window.Size(options.Width, options.Height), options: o)
    } catch let e as window.WindowError {
        print("run: \(e.Message)")
        return 1
    } catch {
        print("run: \(error)")
        return 1
    }
    if options.Stretch { win.Surface().SetScaling(.stretch) }
    let trace = (env.Get("RUN_TRACE") ?? "") != ""
    let quitAfter = float64(env.Get("RUN_QUIT_AFTER") ?? "") ?? 0
    let begun = time.Instant.Now()
    var last: float64 = -1
    var lastReport: float64 = 0
    var fps: float64 = 60
    var drawAverage: float64 = 0
    var presentAverage: float64 = 0
    win.RequestFrame()
    while let event = await win.WaitEvent() {
        switch event {
        case .closeRequested:
            win.SetPointerLocked(false)
            win.Close()
            return 0
        case .frame(let f):
            let t = f.Time
            let dt = last < 0 ? float32(1.0 / 60.0) : float32(min(t - last, 0.1))
            last = t
            fps += (1 / max(float64(dt), 0.001) - fps) * 0.05
            s.Run(dt)
            let size = options.Stretch ? win.Size() : window.Size(float32(win.PixelSize().Width), float32(win.PixelSize().Height))
            let w = max(64, int(size.Width)), h = max(64, int(size.Height))
            let d0 = time.Instant.Now()
            let px = draw(Frame(Width: w, Height: h, Dt: dt, Time: begun.Elapsed().AsSeconds()))
            let d1 = time.Instant.Now()
            if px.count >= w * h * 4 {
                do {
                    try win.Surface().Present(px, size: window.PixelSize(int32(w), int32(h)))
                } catch {}
            }
            let drawMs = float64((d1 - d0).AsMicroseconds()) / 1000
            let presentMs = float64((time.Instant.Now() - d1).AsMicroseconds()) / 1000
            drawAverage += (drawMs - drawAverage) * 0.05
            presentAverage += (presentMs - presentAverage) * 0.05
            if trace && t - lastReport >= 1 {
                lastReport = t
                print("run: \(Int(fps)) fps, \(s.Steps) steps, \(w)×\(h)\n\(s.Report())  draw: \(ms(drawAverage)) ms\n  present: \(ms(presentAverage)) ms\n", terminator: "")
            }
            if (quitAfter > 0 && begun.Elapsed().AsSeconds() > quitAfter) || (options.Done?() ?? false) {
                win.SetPointerLocked(false)
                win.Close()
                return 0
            }
            win.RequestFrame()
        default:
            if !handle(win, event) {
                win.SetPointerLocked(false)
                win.Close()
                return 0
            }
        }
    }
    return 0
}

/// Window opens a window whose frames are drawn on the GPU and presented
/// where they're drawn: `present` draws each frame (at Frame's size, the
/// window's pixels times Options.Scale) and hands it to the layer
/// (gpu.Layer.Present), nothing read back or copied. `handle` gets every
/// event but frames. Answers the program's exit status; 1 where there's
/// no GPU to present with.
@MainActor
public func Window(title: string, options: Options = Options(), schedule s: schedule.Schedule,
                   present: (Frame, gpu.Layer) -> void, handle: (window.Window, window.Event) -> bool) async -> int32 {
    var o = window.Options()
    o.MinSize = window.Size(options.MinWidth, options.MinHeight)
    let win: window.Window
    do {
        win = try window.Create(title: title, size: window.Size(options.Width, options.Height), options: o)
    } catch let e as window.WindowError {
        print("run: \(e.Message)")
        return 1
    } catch {
        print("run: \(error)")
        return 1
    }
    let device = gpu.Default()
    let px0 = win.PixelSize()
    let scale0 = float64(px0.Width) / float64(max(1, win.Size().Width))
    guard let layer = gpu.Layer.Attach(device: device, view: win.Surface().RawParts().view, width: int(px0.Width), height: int(px0.Height), scale: scale0) else {
        print("run: no GPU to present with (\(device.Name))")
        win.Close()
        return 1
    }
    let trace = (env.Get("RUN_TRACE") ?? "") != ""
    let quitAfter = float64(env.Get("RUN_QUIT_AFTER") ?? "") ?? 0
    let begun = time.Instant.Now()
    var last: float64 = -1
    var lastReport: float64 = 0
    var fps: float64 = 60
    var drawAverage: float64 = 0
    win.RequestFrame()
    while let event = await win.WaitEvent() {
        switch event {
        case .closeRequested:
            win.SetPointerLocked(false)
            win.Close()
            return 0
        case .frame(let f):
            let t = f.Time
            let dt = last < 0 ? float32(1.0 / 60.0) : float32(min(t - last, 0.1))
            last = t
            fps += (1 / max(float64(dt), 0.001) - fps) * 0.05
            s.Run(dt)
            // The window's pixels (they change as it's resized or moved to
            // another display).
            let px = win.PixelSize()
            let scale = float64(px.Width) / float64(max(1, win.Size().Width))
            layer.Resize(width: max(64, int(px.Width)), height: max(64, int(px.Height)), scale: scale)
            let w = max(64, int(float32(px.Width) * options.Scale)), h = max(64, int(float32(px.Height) * options.Scale))
            let d0 = time.Instant.Now()
            present(Frame(Width: w, Height: h, Dt: dt, Time: begun.Elapsed().AsSeconds()), layer)
            let drawMs = float64((time.Instant.Now() - d0).AsMicroseconds()) / 1000
            drawAverage += (drawMs - drawAverage) * 0.05
            if trace && t - lastReport >= 1 {
                lastReport = t
                print("run: \(Int(fps)) fps, \(s.Steps) steps, \(w)×\(h) on the GPU\n\(s.Report())  draw and present: \(ms(drawAverage)) ms\n", terminator: "")
            }
            if (quitAfter > 0 && begun.Elapsed().AsSeconds() > quitAfter) || (options.Done?() ?? false) {
                win.SetPointerLocked(false)
                win.Close()
                return 0
            }
            win.RequestFrame()
        default:
            if !handle(win, event) {
                win.SetPointerLocked(false)
                win.Close()
                return 0
            }
        }
    }
    return 0
}

/// Headless runs the schedule for `seconds` of simulated time in frames
/// of `dt`, as fast as it can, calling `each` after every frame (false
/// stops early). Answers how long it took, in seconds of real time.
@discardableResult
public func Headless(s: schedule.Schedule, seconds: float64, dt: float32 = 1.0 / 60, each: (float64) -> bool = { _ in true }) -> float64 {
    let begun = time.Instant.Now()
    var t: float64 = 0
    while t < seconds {
        s.Run(dt)
        t += float64(dt)
        if !each(t) { break }
    }
    return begun.Elapsed().AsSeconds()
}

func ms(x: float64) -> string {
    let t = Int((x * 100).rounded())
    return "\(t / 100).\(t % 100 < 10 ? "0" : "")\(t % 100)"
}
