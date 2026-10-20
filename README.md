# entity

[![package: vs-package](https://img.shields.io/badge/package-vs--package-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](https://github.com/vertex-language)
[![license: MIT](https://img.shields.io/badge/license-MIT-f4f4f5?style=flat-square&labelColor=e4e4e7&color=18181b)](LICENSE)

The running world: entities, their components, and the schedule that
steps them, in a window or headless. It is the spine of
`proposed_graphics_v3.md` §3. There is no engine; a game is a thin
program that puts these together with the packages it needs (physics,
humanoid, nav, behavior, render). npc-sim is the example.

---

## Packages

| Package | What it is |
| :--- | :--- |
| **`entity`** | `World`: `Spawn`, `Despawn`, `Alive`, generation-checked `Entity` handles (a stale one never finds the entity that reused its index). `Store<T>` per component type (`World.Store(T.self)`): a dense array with a sparse index, `Set`, `Get`, `Remove`, `Modify`, `Each`. `Join` and `Join3` walk entities that have two or three components, all changeable in place. `Later` and `Flush` put off changes that would disturb a walk. |
| **`entity/schedule`** | `Schedule(hz:)`: systems added to stages (`input`, `fixed`, `frame`, `late`) with what they read and write. `Run(dt)` runs a frame: input, as many fixed steps as the time calls for (at most `MaxSteps`, carrying the rest over as `Alpha`), frame, late. `RunSteps(n)` runs only fixed steps. Each system is timed; `Report()` lists them. |
| **`entity/run`** | `Window(title:options:schedule:draw:handle:)`: opens a window and runs the schedule once per display refresh, presenting what `draw` returns and passing other events to `handle`. `Window(title:options:schedule:present:handle:)`: the same on the GPU — the program draws each frame on the device, at the window's own pixels (times `Options.Scale`), and presents it to the window's `gpu.Layer` itself, nothing read back or copied. `Options.Done` lets a program end itself. `Headless(schedule, seconds:)` runs as fast as it can, for servers, tests and training. `RUN_TRACE=1` prints each system's cost, the draw and the present once a second; `RUN_QUIT_AFTER=s` quits after s seconds. |

Components are plain structs, or classes when a component is a handle to
something with its own life (a `motion.Character`, a mind). The world
knows nothing about space, physics or drawing.

---

## Example

```vertex
import "entity"
import "entity/run"
import "entity/schedule"

struct Place { var X: float32 }
struct Speed { var V: float32 }

let world = entity.World()
let places = world.Store(Place.self)
let speeds = world.Store(Speed.self)
for i in 0..<100 {
    let e = world.Spawn()
    places.Set(e, Place(X: float32(i)))
    speeds.Set(e, Speed(V: 1))
}

let s = schedule.Schedule(hz: 60)
s.Add("move", .fixed, reads: ["Speed"], writes: ["Place"]) { dt in
    entity.Join(speeds, places) { _, speed, place in place.X += speed.V * dt }
}
run.Headless(s, seconds: 10)
```

In a window, `run.Window(title: "game", schedule: s, draw: { f in … pixels }, handle: { win, event in … true })`.

---

## Not yet

Queries with `Without` and `Changed`; parent and child relations;
snapshots for saves, replays and rollback; systems run in parallel on
`sync/job` (the reads and writes are recorded for it); `ui/input` action
maps feeding the input stage.

`Store` has no settable subscript: `places[e] = p` doesn't lower in vsc
yet (`vsc_TODO.md` #75). Use `Set`.

---

## Testing

```bash
vsc run check    # spawning, stores, joins, stale handles, Later, stages, fixed steps, MaxSteps, the report, headless
```

---

## License

[MIT](LICENSE)
