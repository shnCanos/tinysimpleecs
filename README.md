# tinysimpleecs

My first attempt at both writing an ecs engine and zig. Note that it is pretty simplistic in implementation and likely has bugs.

# Install

Run:
```sh
zig fetch --save https://github.com/shnCanos/tinysimpleecs/archive/refs/heads/main.tar.gz
```
Then edit `build.zig`
```zig
// -- Find place where exe is defined --

// Add these two lines
const tinysimpleecs = b.dependency("tinysimpleecs", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tinysimpleecs", tinysimpleecs.module("tinysimpleecs"));
```

You will then be able to import it with:

```zig
const ecs = @import("tinysimpleecs");
```

You can find an example [here](https://github.com/shnCanos/tinysimpleecs/tree/main/example)
# Usage

## Starting the world

The world is started with the following syntax:

```zig
var world = try ecs.World(.{Component1, Component2, ...}, .{
	.startup = .{startupsystem1, startupsystem2, ...},
	.update = .{system1, system2, ...},
}).init(allocator);
defer world.deinit();
```

## Running systems

Systems are run with the following syntax.

```zig
while (!shouldFinish) {
	try world.runSystems();
}
```

## Creating a Component

```zig
// The only difference between a component and a normal
// struct is getting declared when initializing the world
pub const Component1 = struct {};
```

## Creating a System (from the example)

A system is a function that has:
- Only arguments of type `Query`, `Spawn` and `Despawn`
- Return type `!void`

A `Query` will return a list containing every entity with matching components. For instance:

```
query: ecs.Query(.{ .ent = ecs.Entity, .c = Circle, .pos = Position })
```

Will return every entity that contains the `Circle` and `Position` components.

>[!TIP]
> You can query `ecs.Entity` from any `entity`

A `Spawner` can spawn entities with the specified components. For instance:

```
spawner: *ecs.Spawn(.{ Circle, SimpleKeyboardMovement, Position })
```

Will return a `Spawner` which allows you to spawn entities with the components `Circle`, `SimpleKeyboardMovement` and `Position`.

A `Despawner` can despawn entities. It is imported like so:

```
despawner: *ecs.Despawn,
```

Here are examples of systems from the [example](https://github.com/shnCanos/tinysimpleecs/tree/main/example).


```zig
pub fn movement(query: ecs.Query(.{ .kbmv = SimpleKeyboardMovement, .pos = Position })) !void {
    for (query.result.items) |result| {
        const pos: *Position = result.pos;
        const kbmv: *SimpleKeyboardMovement = result.kbmv;

        pos.pos = pos.pos.add(kbmv.get_movement());
    }
}

pub fn drawCircles(query: ecs.Query(.{ Circle, Position })) !void {
    for (query.result.items) |result| {
        result[0].draw(result[1].pos);
    }
}

pub fn destroyOnContact(despawner: *ecs.Despawn, query1: ecs.Query(.{ .ent = ecs.Entity, .c = Circle, .pos = Position }), query2: ecs.Query(.{ .ent = ecs.Entity, .c = Circle, .pos = Position })) !void {
    blk: for (query1.result.items) |result1| {
        for (query2.result.items) |result2| {
            if (result1.ent.id == result2.ent.id) {
                continue;
            }

            const pos1: *Position = result1.pos;
            const circle1: *Circle = result1.c;
            const pos2: *Position = result2.pos;
            const circle2: *Circle = result2.c;

            const hit = pos1.pos.distance(pos2.pos) <= circle1.radius + circle2.radius;

            if (hit) {
                try despawner.despawn(result1.ent);
                try despawner.despawn(result2.ent);
                break :blk;
            }
        }
    }
}

pub fn spawnEntities(spawner: *ecs.Spawn(.{ Circle, SimpleKeyboardMovement, Position })) !void {
    try spawner.spawn(.{
        Circle{
            .radius = 40,
            .color = rl.Color.green,
        },
        SimpleKeyboardMovement{},
        Position{
            .pos = rl.Vector2.init(screenWidth / 2.0, screenHeight / 2.0),
        },
    });
    try spawner.spawn(.{
        Circle{},
        SimpleKeyboardMovement{
            .speed = 19.0,
        },
        Position{},
    });
}
```

## Events

In order to create an Event, you can add it as a component, spawn it in the emitting system, and then query it, and despawn it in the receiving system.

## Resources

In order to create a resource you can simply spawn it in a startup system and query it in any system that uses it.

# Licence
MIT
