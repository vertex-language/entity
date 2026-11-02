// Package schedule runs a program's systems in stages each frame: what
// reads input first, then the fixed-step simulation as many times as the
// frame's time calls for (physics, controllers, minds, rules), then the
// per-frame work (animation, camera), then what draws. Each system says
// what it reads and writes, and is timed, so a slow one names itself.
//
//     var s = schedule.Schedule(hz: 60)
//     s.Add("move", .fixed, writes: ["Place"]) { dt in … }
//     s.Add("animate", .frame, reads: ["Place"]) { dt in … }
//     s.Run(frameTime)
//
// Systems run in the order added within a stage, on the calling thread.
// The reads and writes are recorded for running independent systems in
// parallel (on sync/job) once that exists.
package schedule

import (
    "time"
)

/// Stage is when in a frame a system runs.
public enum Stage {
    /// Once a frame, first: input, intents.
    case input
    /// At the fixed rate, as many times as the frame needs: simulation.
    case fixed
    /// Once a frame, after the simulation: animation, camera.
    case frame
    /// Once a frame, last: extraction and drawing.
    case late
}

/// System is a named piece of work.
public final class System {
    public let Name: string
    public let Stage: Stage
    public let Reads: [string]
    public let Writes: [string]
    public var Enabled = true
    let run: (float32) -> void
    /// Milliseconds of its last frame (all its fixed steps together), and
    /// an average over recent frames.
    public private(set) var LastMs: float64 = 0
    public private(set) var AverageMs: float64 = 0
    var frameMs: float64 = 0

    init(name: string, stage: Stage, reads: [string], writes: [string], run: (float32) -> void) {
        Name = name
        self.Stage = stage
        Reads = reads
        Writes = writes
        self.run = run
    }
}

/// Schedule is a program's systems and the fixed-step clock.
public final class Schedule {
    public private(set) var Systems: [System] = []
    /// Seconds per fixed step.
    public var Step: float32
    /// At most this many fixed steps a frame; a slower frame runs slow
    /// rather than falling further behind.
    public var MaxSteps = 4
    /// How far into the next fixed step the frame is, 0…1: for drawing
    /// between two simulated states.
    public private(set) var Alpha: float32 = 0
    /// Fixed steps run so far, and frames.
    public private(set) var Steps: int64 = 0
    public private(set) var Frames: int64 = 0
    /// The simulated time, in seconds.
    public private(set) var Time: float64 = 0
    var accumulator: float32 = 0
    /// Runs after every system, between them: the world's Flush.
    public var Between: (() -> void)? = nil

    public init(hz: float32 = 60) {
        Step = 1 / hz
    }

    /// Add appends a system to a stage.
    @discardableResult
    public func Add(name: string, stage: Stage, reads: [string] = [], writes: [string] = [], run: (float32) -> void) -> System {
        let s = System(name, stage, reads: reads, writes: writes, run)
        Systems.append(s)
        return s
    }

    /// Find is a system by name.
    public func Find(name: string) -> System? {
        return Systems.first(where: { $0.Name == name })
    }

    /// Run runs one frame of dt seconds: input, the fixed steps it owes,
    /// frame, late.
    public func Run(dt: float32) {
        for s in Systems { s.frameMs = 0 }
        stage(.input, dt)
        accumulator += min(dt, Step * float32(MaxSteps))
        var n = 0
        while accumulator >= Step && n < MaxSteps {
            stage(.fixed, Step)
            accumulator -= Step
            Steps += 1
            Time += float64(Step)
            n += 1
        }
        if n == MaxSteps && accumulator >= Step { accumulator = 0 }
        Alpha = accumulator / Step
        stage(.frame, dt)
        stage(.late, dt)
        Frames += 1
        for s in Systems {
            s.LastMs = s.frameMs
            s.AverageMs += (s.frameMs - s.AverageMs) * (Frames < 10 ? 0.5 : 0.05)
        }
    }

    /// Steps runs only the fixed stage, n times: a headless simulation, a
    /// test.
    public func RunSteps(n: int) {
        for _ in 0..<n {
            for s in Systems { s.frameMs = 0 }
            stage(.fixed, Step)
            Steps += 1
            Time += float64(Step)
            for s in Systems where s.Stage == .fixed {
                s.LastMs = s.frameMs
                s.AverageMs += (s.frameMs - s.AverageMs) * 0.05
            }
        }
    }

    func stage(st: Stage, dt: float32) {
        for s in Systems where s.Stage == st && s.Enabled {
            let t0 = time.Instant.Now()
            s.run(dt)
            if let b = Between { b() }
            s.frameMs += float64((time.Instant.Now() - t0).AsMicroseconds()) / 1000
        }
    }

    /// Report is a line per system: its stage, and what it costs.
    public func Report() -> string {
        var out = ""
        for s in Systems {
            out += "  \(s.Name) (\(s.Stage)): \(fmt(s.AverageMs)) ms\n"
        }
        return out
    }
}

func fmt(ms: float64) -> string {
    let t = Int((ms * 100).rounded())
    return "\(t / 100).\(t % 100 < 10 ? "0" : "")\(t % 100)"
}
