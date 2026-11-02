// entity: spawning, despawning and stale handles; stores set, get,
// remove and walk; joins; deferred changes; a schedule's stages and fixed
// steps; a headless run.
//
//     vsc run check
package main

import (
    "entity"
    "entity/run"
    "entity/schedule"
    "math"
)

var failures = 0

func check(ok: bool, what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

struct Place { var X: float32 }
struct Speed { var V: float32 }
struct Tag {}

func main() -> int32 {
    let w = entity.World()
    let places = w.Store(Place.self)
    let speeds = w.Store(Speed.self)
    let a = w.Spawn(), b = w.Spawn(), c = w.Spawn()
    check(w.Count == 3 && w.Alive(b), "spawning makes live entities")
    places.Set(a, Place(X: 0))
    places.Set(b, Place(X: 10))
    places.Set(c, Place(X: 20))
    speeds.Set(a, Speed(V: 1))
    speeds.Set(c, Speed(V: -2))
    check(places.Count == 3 && speeds.Count == 2 && !speeds.Has(b), "stores hold what entities have")
    check(w.Store(Place.self) === places, "a world gives the same store for a type")

    entity.Join(speeds, places) { _, s, p in p.X += s.V }
    check(places[a]!.X == 1 && places[b]!.X == 10 && places[c]!.X == 18, "a join changes both components in place")

    w.Despawn(b)
    check(!w.Alive(b) && places.Count == 2 && places[b] == nil, "despawning removes an entity's components")
    let d = w.Spawn()
    check(d.Index == b.Index && d != b && places[b] == nil && !w.Alive(b), "an index is reused, a stale handle finds nothing")
    places.Set(d, Place(X: 5))
    check(places[d]!.X == 5 && places[b] == nil, "the new entity has its own components")

    // Removing while walking is deferred.
    var seen = 0
    places.Each { e, p in
        seen += 1
        if p.X > 10 { w.Later { w.Despawn(e) } }
    }
    w.Flush()
    check(seen == 3 && places.Count == 2 && !w.Alive(c), "Later puts a despawn after the walk")

    // A schedule: input once, fixed steps as the time calls for, then frame.
    var order: [string] = []
    var fixed = 0
    var steps: [float32] = []
    let s = schedule.Schedule(hz: 60)
    s.Add("input", .input) { _ in order.append("input") }
    s.Add("physics", .fixed) { dt in
        fixed += 1
        if order.last != "physics" { order.append("physics") }
        steps.append(dt)
    }
    s.Add("draw", .late) { _ in order.append("draw") }
    s.Add("animate", .frame) { _ in order.append("animate") }
    s.Run(1.0 / 30)
    check(fixed == 2 && order == ["input", "physics", "animate", "draw"], "a frame of 1/30 s runs two fixed steps, stages in order (\(order))")
    s.Run(0.004)
    check(fixed == 2 && s.Alpha > 0.2, "a short frame runs no step and carries the time over (alpha \(s.Alpha))")
    s.Run(5)
    check(fixed == 2 + s.MaxSteps, "a long frame runs at most MaxSteps")
    var exact = true
    for dt in steps where math.Abs(dt - 1.0 / 60) > 1e-6 { exact = false }
    check(exact, "fixed systems always get the fixed step")
    check(s.Report().contains("physics (fixed)"), "the report names each system")

    // Headless: ten simulated seconds.
    var ticks = 0
    let h = schedule.Schedule(hz: 120)
    h.Add("tick", .fixed) { _ in ticks += 1 }
    let took = run.Headless(h, seconds: 10)
    check(ticks >= 1199 && ticks <= 1201, "a headless run of 10 s at 120 Hz takes \(ticks) steps (\(Int(took * 1000)) ms)")
    _ = Tag()
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}
