// Package entity is the running world: entities, and the components
// (plain structs) they have. A component type gets a Store, a dense array
// with a sparse index by entity, so a system walks only what has the
// component and reads it at array speed; Each and Join walk one or two
// stores. Changes that would disturb a walk in progress (spawning,
// despawning) can wait for Flush.
//
//     let world = entity.World()
//     let places = world.Store(Place.self)
//     let speeds = world.Store(Speed.self)
//     let e = world.Spawn()
//     places.Set(e, Place(x: 0))
//     speeds.Set(e, Speed(v: 2))
//     entity.Join(places, speeds) { _, place, speed in place.x += speed.v * dt }
//
// Positions and other world data are the program's own components; this
// package knows nothing about space, physics or drawing.
package entity

/// Entity names a thing in a world. Its index is reused after a despawn,
/// its generation is not, so a stale Entity never finds the new one.
public struct Entity: Equatable, Hashable {
    public let Index: int32
    public let Generation: uint32

    public init(index: int32, generation: uint32) {
        Index = index
        Generation = generation
    }

    /// None is no entity.
    public static let None = Entity(index: -1, generation: 0)

    public static func == (a: Entity, b: Entity) -> bool {
        return a.Index == b.Index && a.Generation == b.Generation
    }

    public func hash(into h: inout Hasher) {
        h.combine(int64(Index) << 32 | int64(Generation))
    }
}

/// storage is what a world needs of every store: forgetting an entity.
protocol storage: AnyObject {
    func forget(e: Entity)
    var name: string { get }
}

/// World is entities and their stores.
public final class World {
    var generations: [uint32] = []
    var alive: [bool] = []
    var free: [int32] = []
    var stores: [storage] = []
    var deferred: [() -> void] = []
    public private(set) var Count = 0

    public init() {}

    /// Spawn makes a new entity, with no components yet.
    public func Spawn() -> Entity {
        if let i = free.popLast() {
            alive[int(i)] = true
            Count += 1
            return Entity(index: i, generation: generations[int(i)])
        }
        let i = int32(generations.count)
        generations.append(1)
        alive.append(true)
        Count += 1
        return Entity(index: i, generation: 1)
    }

    /// Despawn removes an entity and all its components, now. Inside a walk
    /// over a store, use Later.
    public func Despawn(e: Entity) {
        if !Alive(e) { return }
        for s in stores { s.forget(e) }
        let i = int(e.Index)
        alive[i] = false
        generations[i] += 1
        free.append(e.Index)
        Count -= 1
    }

    /// Alive is whether the entity exists (and isn't a stale handle).
    public func Alive(e: Entity) -> bool {
        let i = int(e.Index)
        return i >= 0 && i < alive.count && alive[i] && generations[i] == e.Generation
    }

    /// Store is a store for one component type, made the first time and
    /// remembered by `name` (by default, the type's name).
    public func Store<T>(type: T.Type, name: string = "") -> entity.Store<T> {
        let key = name.isEmpty ? "\(T.self)" : name
        for s in stores where s.name == key {
            if let typed = s as? entity.Store<T> { return typed }
        }
        let s = entity.Store<T>(key, world: self)
        stores.append(s)
        return s
    }

    /// Later runs f at the next Flush: a change that would disturb a walk
    /// in progress (spawning, despawning, adding a component to a store
    /// being walked).
    public func Later(f: () -> void) {
        deferred.append(f)
    }

    /// Flush runs what Later put off, in order (more may be added as it
    /// runs; they run too).
    public func Flush() {
        var i = 0
        while i < deferred.count {
            deferred[i]()
            i += 1
        }
        deferred = []
    }

    /// Stores names the stores, for reports.
    public var StoreNames: [string] {
        var out: [string] = []
        for s in stores { out.append(s.name) }
        return out
    }
}

/// Store is one component type's values, by entity.
public final class Store<T>: storage {
    let name: string
    unowned let world: World
    /// Dense: the values, and whose each is.
    var values: [T] = []
    var owners: [Entity] = []
    /// Sparse: by entity index, its slot in values, or -1.
    var slots: [int32] = []

    init(name: string, world: World) {
        self.name = name
        self.world = world
    }

    /// Name is what the store is called (the component type's name).
    public var Name: string { return name }

    /// Count is how many entities have the component.
    public var Count: int { return values.count }

    /// Entities is who has the component, in the order Each walks.
    public var Entities: [Entity] { return owners }

    func slot(e: Entity) -> int {
        let i = int(e.Index)
        if i < 0 || i >= slots.count { return -1 }
        let s = int(slots[i])
        if s < 0 || owners[s].Generation != e.Generation { return -1 }
        return s
    }

    /// Has is whether the entity has the component.
    public func Has(e: Entity) -> bool {
        return slot(e) >= 0
    }

    /// Get is an entity's component, or nil.
    public func Get(e: Entity) -> T? {
        let s = slot(e)
        return s >= 0 ? values[s] : nil
    }

    /// The component of an entity: nil when it has none. Read only:
    /// Set and Remove change it (a settable subscript here doesn't lower
    /// yet, vsc_TODO #75).
    public subscript(e: Entity) -> T? {
        return Get(e)
    }

    /// Set gives an entity the component, or replaces the one it has.
    public func Set(e: Entity, v: T) {
        if !world.Alive(e) { return }
        let s = slot(e)
        if s >= 0 {
            values[s] = v
            return
        }
        let i = int(e.Index)
        while slots.count <= i { slots.append(-1) }
        slots[i] = int32(values.count)
        values.append(v)
        owners.append(e)
    }

    /// Remove takes the component away (the last value moves into its slot).
    public func Remove(e: Entity) {
        let s = slot(e)
        if s < 0 { return }
        let last = values.count - 1
        if s != last {
            values[s] = values[last]
            owners[s] = owners[last]
            slots[int(owners[s].Index)] = int32(s)
        }
        values.removeLast()
        owners.removeLast()
        slots[int(e.Index)] = -1
    }

    func forget(e: Entity) {
        Remove(e)
    }

    /// Modify changes an entity's component in place; false when it has none.
    @discardableResult
    public func Modify(e: Entity, f: (inout T) -> void) -> bool {
        let s = slot(e)
        if s < 0 { return false }
        f(&values[s])
        return true
    }

    /// Each walks every entity with the component, the value changeable in
    /// place. Don't add or remove components of this store inside; use
    /// World.Later.
    public func Each(f: (Entity, inout T) -> void) {
        var i = 0
        let n = values.count
        while i < n && i < values.count {
            f(owners[i], &values[i])
            i += 1
        }
    }

    /// At is the i-th value and its owner, in walking order.
    public func At(i: int) -> (Entity, T) {
        return (owners[i], values[i])
    }
}

/// Join walks the entities that have both components, both changeable in
/// place. It walks a and looks each up in b, so give the smaller store
/// first.
public func Join<A, B>(a: Store<A>, b: Store<B>, f: (Entity, inout A, inout B) -> void) {
    var i = 0
    while i < a.values.count {
        let e = a.owners[i]
        let s = b.slot(e)
        if s >= 0 { f(e, &a.values[i], &b.values[s]) }
        i += 1
    }
}

/// Join3 walks the entities that have all three components.
public func Join3<A, B, C>(a: Store<A>, b: Store<B>, c: Store<C>, f: (Entity, inout A, inout B, inout C) -> void) {
    var i = 0
    while i < a.values.count {
        let e = a.owners[i]
        let sb = b.slot(e), sc = c.slot(e)
        if sb >= 0 && sc >= 0 { f(e, &a.values[i], &b.values[sb], &c.values[sc]) }
        i += 1
    }
}
