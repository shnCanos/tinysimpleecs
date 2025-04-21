const std = @import("std");
const lib = @import("first_raylib_zig_lib");
const rl = @import("raylib");
const ecs = @import("tinysimpleecs");

pub const possible_movement = [_]SimpleMovementKey{ .{
    .key = .d,
    .movement = rl.Vector2.init(1, 0),
}, .{
    .key = .a,
    .movement = rl.Vector2.init(-1, 0),
}, .{
    .key = .w,
    .movement = rl.Vector2.init(0, -1),
}, .{
    .key = .s,
    .movement = rl.Vector2.init(0, 1),
} };

pub const SimpleMovementKey = struct {
    key: rl.KeyboardKey,
    movement: rl.Vector2,

    pub fn pressed(movement_key: SimpleMovementKey) bool {
        return rl.isKeyDown(movement_key.key);
    }
};

pub const SimpleKeyboardMovement = struct {
    const Self = @This();
    possible: []const SimpleMovementKey = &possible_movement,
    speed: f32 = 4.0,

    pub fn get_movement(simple_movement: Self) rl.Vector2 {
        var vec_sum = rl.Vector2.init(0, 0);
        for (simple_movement.possible) |simple_movement_key| {
            if (simple_movement_key.pressed()) {
                vec_sum = vec_sum.add(simple_movement_key.movement);
            }
        }
        return vec_sum.normalize().scale(simple_movement.speed);
    }
};

pub const Circle = struct {
    radius: f32 = 50,
    color: rl.Color = rl.Color.maroon,

    pub fn draw(self: *const Circle, pos: rl.Vector2) void {
        rl.drawCircleV(pos, self.radius, self.color);
    }
};

pub const Position = struct {
    pos: rl.Vector2 = rl.Vector2.init(0, 0),
};

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

const screenWidth = 800.0;
const screenHeight = 451.0;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var world = try ecs.World(.{ SimpleKeyboardMovement, Circle, Position }, .{
        .startup = .{spawnEntities},
        .update = .{ movement, drawCircles, destroyOnContact },
    }).init(allocator);
    defer world.deinit();

    rl.initWindow(screenWidth, screenHeight, "My cool cool window!");
    defer rl.closeWindow(); // Close window and OpenGL context
    rl.setTargetFPS(60);
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.white);
        try world.runSystems();
    }
}
