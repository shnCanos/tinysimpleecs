const lib = @import("first_raylib_zig_lib");
const std = @import("std");
const pretty = @import("pretty");

const Allocator = std.mem.Allocator;

fn RemovePointerFromType(A: type) type {
    return switch (@typeInfo(A)) {
        .pointer => |ptr_info| ptr_info.child,
        else => unreachable,
    };
}

pub const ComponentsManager = struct {
    table_union_type: type,
    table_size: usize,

    pub fn init(comptime components: anytype) ComponentsManager {
        const ArgsType = @TypeOf(components);
        const components_type_info = @typeInfo(ArgsType);
        if (components_type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        const fields_info = components_type_info.@"struct".fields;

        var i = 0;
        var enum_fields: [fields_info.len]std.builtin.Type.EnumField = undefined;
        var union_fields: [fields_info.len]std.builtin.Type.UnionField = undefined;
        while (i < fields_info.len) : (i += 1) {
            const current_field = fields_info[i];
            if (@typeInfo(current_field.type) != .type) {
                @compileError("Expected Type but found: " ++ @typeName(current_field.type));
            }

            const current_comp = @field(components, current_field.name);
            enum_fields[i] = std.builtin.Type.EnumField{
                .name = @typeName(current_comp),
                .value = i,
            };
            union_fields[i] = std.builtin.Type.UnionField{
                .name = @typeName(current_comp),
                .alignment = @alignOf(current_comp),
                .type = *current_comp,
            };
        }

        const tagenum =
            @Type(std.builtin.Type{ .@"enum" = std.builtin.Type.Enum{
                .tag_type = usize,
                .fields = &enum_fields,
                .decls = &[0]std.builtin.Type.Declaration{},
                .is_exhaustive = true,
            } });
        const table_union =
            @Type(std.builtin.Type{ .@"union" = std.builtin.Type.Union{
                .tag_type = tagenum,
                .fields = &union_fields,
                .decls = &[0]std.builtin.Type.Declaration{},
                .layout = .auto,
            } });
        return ComponentsManager{
            .table_size = enum_fields.len,
            .table_union_type = table_union,
        };
    }

    fn GetTableEnum(self: *const ComponentsManager) type {
        return std.meta.Tag(self.table_union_type);
    }

    pub fn getComponentPos(self: *const ComponentsManager, comptime component: type) usize {
        return @intFromEnum(@field(self.GetTableEnum(), @typeName(component)));
    }

    pub fn fromComponentPos(self: *const ComponentsManager, pos: usize) self.GetTableEnum() {
        return @enumFromInt(pos);
    }

    pub fn unwrapComponentFromType(ComponentType: type, component: anytype) ComponentType {
        const ComponentUnion = @TypeOf(component);

        if (@typeInfo(ComponentUnion) != .@"union") {
            @compileError("Expected union type, found " ++ @typeName(ComponentUnion));
        }

        inline for (std.meta.fields(ComponentUnion)) |field| {
            if (field.type == ComponentType) {
                return @field(component, field.name);
            }
        }
        @panic("Component type not found. Should not happen.");
    }
};

pub fn BitMask(comptime component_n: usize) type {
    return struct {
        const Self = @This();
        const set_len = component_n;

        set: std.StaticBitSet(component_n),

        pub fn init() Self {
            return .{
                .set = std.StaticBitSet(component_n).initEmpty(),
            };
        }

        pub fn fromComponents(comptime components_manager: ComponentsManager, components: anytype) Self {
            var bitset = std.StaticBitSet(components_manager.table_size).initEmpty();
            const ArgsType = @TypeOf(components);
            const components_type_info = @typeInfo(ArgsType);
            if (components_type_info != .@"struct") {
                @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }

            const fields_info = components_type_info.@"struct".fields;

            comptime var i = 0;
            inline while (i < fields_info.len) : (i += 1) {
                const current_comp = fields_info[i];
                const CurrentCompType = switch (@typeInfo(current_comp.type)) {
                    .@"struct" => current_comp.type,
                    .type => @field(components, current_comp.name),
                    else => @compileError("Expected either Struct or Type but found: " ++ @typeName(current_comp.type)),
                };

                if (CurrentCompType != Entity) {
                    bitset.set(components_manager.getComponentPos(CurrentCompType));
                }
            }
            return Self{ .set = bitset };
        }

        pub fn intoComponents(self: *const Self, allocator: Allocator, components_manager: ComponentsManager) !std.ArrayList(components_manager.GetTableEnum()) {
            const EnumType = components_manager.GetTableEnum();

            var trt = std.ArrayList(EnumType).init(allocator);
            for (0..components_manager.table_size) |i| {
                if (self.isSet(i)) {
                    trt.append(components_manager.fromComponentPos(i));
                }
            }

            return trt;
        }

        pub fn addPosition(self: *Self, pos: usize) void {
            self.set.set(pos);
        }

        pub fn print(self: *const Self) void {
            var str: [set_len]u8 = undefined;
            var i: usize = 0;
            while (i < set_len) : (i += 1) {
                str[i] = @as(u8, @intFromBool(self.set.isSet(i))) + '0';
            }

            std.debug.print("Bitset: {s}", .{str});
        }
    };
}

pub fn SystemsManager(comptime sys: anytype) type {
    return struct {
        const Self = @This();
        const update_systems = sys.update;
        const startup_systems = sys.startup;

        // TODO: Run startup sytems or something
        pub fn init(allocator: Allocator, entity_manager: anytype, components_manager: ComponentsManager) !Self {
            // Run startup systems
            try Self.runAllFrom(&.{}, allocator, entity_manager, components_manager, startup_systems);
            return .{};
        }

        fn typeNameUntilParenthesis(T: type) []const u8 {
            const str = @typeName(T);
            const parenthesis_index = std.mem.indexOf(u8, str, "(");
            if (parenthesis_index) |index| {
                return str[0..index];
            }
            return str;
        }

        // There probably is a better way to do this, but I don't care
        fn typeComparisonWorkaround(A: type, B: type) bool {
            const nameA = typeNameUntilParenthesis(A);
            const nameB = typeNameUntilParenthesis(B);
            return std.mem.eql(u8, nameA, nameB);
        }

        pub fn runAllFrom(
            _: *const Self,
            allocator: Allocator,
            entity_manager: anytype,
            components_manager: ComponentsManager,
            comptime systems: anytype,
        ) !void {
            // Argument sanity check
            const ArgsType = @TypeOf(systems);
            const components_type_info = @typeInfo(ArgsType);
            if (components_type_info != .@"struct") {
                @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }
            const fields_info = components_type_info.@"struct".fields;

            inline for (fields_info) |current_field| {
                if (@typeInfo(current_field.type) != .@"fn") {
                    @compileError("expected functions, found " ++ @typeName(ArgsType));
                }

                const current_system = @field(systems, current_field.name);
                const SystemArgsType = std.meta.ArgsTuple(@TypeOf(current_system));
                var args_to_give_to_system: SystemArgsType = undefined;
                // Init arguments
                inline for (std.meta.fields(SystemArgsType), 0..) |arg_type_field, i| {
                    // Took me a while to debug this, but for some reason this specific lines needs to be
                    // explicitly comptime or else it will ALWAYS return false (even if I compare the same variable)
                    const is_query = comptime typeComparisonWorkaround(arg_type_field.type, Query(.{}));
                    const is_spawn = comptime typeComparisonWorkaround(arg_type_field.type, *Spawn(.{}));
                    const is_despawn = comptime arg_type_field.type == *Despawn;
                    if (is_query) {
                        args_to_give_to_system[i] = try arg_type_field.type.init(allocator, entity_manager, components_manager);
                    } else if (is_spawn) {
                        const ActualSpawnType = RemovePointerFromType(arg_type_field.type);
                        const new_spawn = try allocator.create(ActualSpawnType);
                        new_spawn.* = ActualSpawnType.init(allocator);
                        args_to_give_to_system[i] = new_spawn;
                    } else if (is_despawn) {
                        const ActualDespawnType = RemovePointerFromType(arg_type_field.type);
                        const new_despawn = try allocator.create(ActualDespawnType);
                        new_despawn.* = ActualDespawnType.init(allocator);
                        args_to_give_to_system[i] = new_despawn;
                    } else {
                        @compileError("System arg type different from expected: " ++ typeNameUntilParenthesis(arg_type_field.type));
                    }
                }

                try @call(.auto, current_system, args_to_give_to_system);

                // Deinit arguments
                inline for (std.meta.fields(SystemArgsType), 0..) |arg_type_field, i| {
                    const is_query = comptime typeComparisonWorkaround(arg_type_field.type, Query(.{}));
                    const is_spawn = comptime typeComparisonWorkaround(arg_type_field.type, *Spawn(.{}));
                    const is_despawn = comptime arg_type_field.type == *Despawn;
                    if (is_query) {
                        args_to_give_to_system[i].deinit();
                    } else if (is_spawn) {
                        const ActualSpawnType = RemovePointerFromType(arg_type_field.type);
                        // Spawn everything
                        for (args_to_give_to_system[i].to_spawn_list.items) |component| {
                            try entity_manager.addEntity(@as(ActualSpawnType.ComponentsType, component));
                        }
                        // Only then deinit
                        args_to_give_to_system[i].deinit();
                        allocator.destroy(args_to_give_to_system[i]);
                    } else if (is_despawn) {
                        // Despawn everything
                        for (args_to_give_to_system[i].to_despawn_list.items) |entity| {
                            try entity_manager.removeEntity(entity);
                        }
                        // Only then deinit
                        args_to_give_to_system[i].deinit();
                        allocator.destroy(args_to_give_to_system[i]);
                    } else {
                        unreachable;
                    }
                }
            }
        }

        pub fn runAllUpdate(
            self: *Self,
            allocator: Allocator,
            entity_manager: anytype,
            components_manager: ComponentsManager,
        ) !void {
            try self.runAllFrom(allocator, entity_manager, components_manager, update_systems);
        }
    };
}

pub const Despawn = struct {
    to_despawn_list: std.ArrayList(Entity),

    pub fn init(allocator: Allocator) Despawn {
        return .{
            .to_despawn_list = std.ArrayList(Entity).init(allocator),
        };
    }

    pub fn despawn(self: *Despawn, entity: Entity) !void {
        try self.to_despawn_list.append(entity);
    }

    pub fn deinit(self: *Despawn) void {
        self.to_despawn_list.deinit();
    }
};

pub fn Spawn(comptime components: anytype) type {
    return struct {
        const Self = @This();
        const ComponentsType = GetComponentsType();
        to_spawn_list: std.ArrayList(ComponentsType),

        pub fn GetComponentsType() type {
            // Argument sanity check
            const ArgsType = @TypeOf(components);
            const components_type_info = @typeInfo(ArgsType);
            if (components_type_info != .@"struct") {
                @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }
            const fields_info = components_type_info.@"struct".fields;
            var new_field_info: [fields_info.len]type = undefined;
            inline for (0..fields_info.len) |i| {
                const current_field = fields_info[i];

                if (@typeInfo(current_field.type) != .type) {
                    @compileError("Expected Type but found: " ++ @typeName(current_field.type));
                }

                const current_component = @field(components, current_field.name);

                new_field_info[i] = current_component;
            }

            return std.meta.Tuple(&new_field_info);
        }

        pub fn init(allocator: Allocator) Self {
            return .{
                .to_spawn_list = std.ArrayList(ComponentsType).init(allocator),
            };
        }

        pub fn spawn(self: *Self, toSpawn: ComponentsType) !void {
            try self.to_spawn_list.append(toSpawn);
        }

        pub fn deinit(self: *Self) void {
            self.to_spawn_list.deinit();
        }
    };
}

pub fn Query(comptime query: anytype) type {
    return struct {
        const Self = @This();
        const ResultType = GetQueryResultType();

        result: std.ArrayList(ResultType),

        pub fn GetQueryResultType() type {
            // Argument sanity check
            const ArgsType = @TypeOf(query);
            const components_type_info = @typeInfo(ArgsType);
            if (components_type_info != .@"struct") {
                @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }
            const fields_info = components_type_info.@"struct".fields;
            var new_field_info: [fields_info.len]std.builtin.Type.StructField = undefined;
            inline for (0..fields_info.len) |i| {
                const current_field = fields_info[i];

                if (@typeInfo(current_field.type) != .type) {
                    @compileError("Expected Type but found: " ++ @typeName(current_field.type));
                }

                const current_component = @field(query, current_field.name);

                const component_field = switch (current_component) {
                    Entity => current_component,
                    else => *current_component,
                };
                new_field_info[i] = std.builtin.Type.StructField{
                    .default_value_ptr = null,
                    .alignment = @alignOf(component_field),
                    .is_comptime = false,
                    .name = current_field.name,
                    .type = component_field,
                };
            }

            return @Type(std.builtin.Type{
                .@"struct" = std.builtin.Type.Struct{
                    .decls = &[0]std.builtin.Type.Declaration{},
                    .fields = &new_field_info,
                    .is_tuple = components_type_info.@"struct".is_tuple,
                    .layout = .auto,
                },
            });
        }

        pub fn init(allocator: Allocator, entity_manager: anytype, components_manager: ComponentsManager) !Self {
            const QueryResultType = Query(query);

            const bitmask = BitMask(components_manager.table_size).fromComponents(components_manager, query);

            var result = std.ArrayList(QueryResultType.ResultType).init(allocator);
            for (entity_manager.entities.items) |entity| {
                if (bitmask.set.subsetOf(entity.component_set.bitmask.set)) {
                    const matching_components = try entity.component_set.componentsFromBitmask(bitmask);
                    defer matching_components.deinit();

                    var current_result: QueryResultType.ResultType = undefined;
                    const fields = std.meta.fields(QueryResultType.ResultType);

                    // Sort the fields
                    comptime var new_fields: [fields.len]std.builtin.Type.StructField = undefined;
                    @memcpy(&new_fields, fields.ptr);
                    comptime std.mem.sort(std.builtin.Type.StructField, &new_fields, void, struct {
                        pub fn lessThan(_: type, a: std.builtin.Type.StructField, b: std.builtin.Type.StructField) bool {
                            if (a.type == Entity or b.type == Entity) {
                                return false;
                            }
                            return components_manager.getComponentPos(RemovePointerFromType(a.type)) < components_manager.getComponentPos(RemovePointerFromType(b.type));
                        }
                    }.lessThan);

                    comptime var i = 0;
                    inline for (new_fields) |field| {
                        if (field.type == Entity) {
                            @field(current_result, field.name) = entity.entity;
                        } else {
                            @field(current_result, field.name) = ComponentsManager.unwrapComponentFromType(field.type, matching_components.items[i]);
                            i += 1;
                        }
                    }

                    try result.append(current_result);
                }
            }

            return .{ .result = result };
        }

        pub fn deinit(self: *Self) void {
            // No need to deinit the ResultType;
            // They should continue existing
            self.result.deinit();
        }
    };
}
pub fn ComponentSet(comptime components_manager: ComponentsManager) type {
    return struct {
        const Self = @This();
        alloc: Allocator,
        components: []const components_manager.table_union_type,
        components_len: usize,
        bitmask: BitMask(components_manager.table_size),

        pub fn init(allocator: Allocator, components: anytype) !Self {
            const ArgsType = @TypeOf(components);
            const components_type_info = @typeInfo(ArgsType);
            if (components_type_info != .@"struct") {
                @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
            }

            const fields_info = components_type_info.@"struct".fields;

            var wrapped_components = try allocator.alloc(components_manager.table_union_type, fields_info.len);
            inline for (0..fields_info.len) |i| {
                const current_field = fields_info[i];
                if (@typeInfo(current_field.type) != .@"struct") {
                    @compileError("Expected Struct but found: " ++ @typeName(current_field.type));
                }
                const current_comp = @field(components, current_field.name);

                const new_component = try allocator.create(@TypeOf(current_comp));
                errdefer allocator.destroy(new_component);
                new_component.* = current_comp;

                wrapped_components[i] = @unionInit(components_manager.table_union_type, @typeName(@TypeOf(current_comp)), new_component);
            }

            std.mem.sort(components_manager.table_union_type, wrapped_components, {}, struct {
                pub fn lessThan(_: void, a: components_manager.table_union_type, b: components_manager.table_union_type) bool {
                    return @intFromEnum(std.meta.activeTag(a)) < @intFromEnum(std.meta.activeTag(b));
                }
            }.lessThan);

            return .{
                .alloc = allocator,
                .components = wrapped_components,
                .components_len = wrapped_components.len,
                .bitmask = BitMask(components_manager.table_size).fromComponents(components_manager, components),
            };
        }

        // The returned list is in the heap
        pub fn componentsFromBitmask(self: *const Self, bitmask: BitMask(components_manager.table_size)) !std.ArrayList(components_manager.table_union_type) {
            var components_list = std.ArrayList(components_manager.table_union_type).init(self.alloc);
            var i: usize = 0;
            for (0..components_manager.table_size) |mask_index| {
                const self_has = self.bitmask.set.isSet(mask_index);
                const other_has = bitmask.set.isSet(mask_index);

                if (self_has) {
                    if (other_has) {
                        try components_list.append(self.components[i]);
                    }
                    i += 1;
                }
            }

            return components_list;
        }

        pub fn deinit(self: *Self) void {
            const EnumType = components_manager.GetTableEnum();
            const enum_field_count = std.meta.fields(EnumType).len;
            comptime var mask_index = 0;
            comptime var comp_index = 0;
            inline while (mask_index < enum_field_count) : (mask_index += 1) {
                if (self.bitmask.set.isSet(mask_index)) {
                    defer comp_index += 1;
                    const current_tag: EnumType = @enumFromInt(mask_index);
                    const current_value = @field(components_manager.table_union_type, @tagName(current_tag));
                    self.alloc.destroy(current_value);
                }
            }

            self.alloc.free(self.components);
        }
    };
}

pub fn EntityInfo(comptime components_manager: ComponentsManager) type {
    return struct {
        entity: Entity,
        component_set: ComponentSet(components_manager),
    };
}

const EntityManagerError = error{
    EntityDoesNotExist,
};
pub fn EntityManager(comptime components_manager: ComponentsManager) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        entities: std.ArrayList(EntityInfo(components_manager)),
        last_spawn: usize = 0,

        pub fn init(allocator: Allocator) Self {
            return .{
                .entities = std.ArrayList(EntityInfo(components_manager)).init(allocator),
                .alloc = allocator,
            };
        }

        pub fn addEntity(self: *Self, components: anytype) !void {
            const new_entity = Entity.init(self.last_spawn);
            const entity_components = try ComponentSet(components_manager).init(self.alloc, components);
            // errdefer entity_components.deinit();

            const entity_info = EntityInfo(components_manager){
                .entity = new_entity,
                .component_set = entity_components,
            };

            try self.entities.append(entity_info);

            self.last_spawn += 1;
        }

        pub fn entityIndex(self: *const Self, entity: Entity) ?usize {
            for (self.entities.items, 0..) |entityInfo, i| {
                if (entityInfo.entity.id == entity.id) {
                    return i;
                }
            }
            return null;
        }

        pub fn removeEntity(self: *Self, entity: Entity) !void {
            if (self.entityIndex(entity)) |index| {
                _ = self.entities.swapRemove(index);
                return;
            }

            return EntityManagerError.EntityDoesNotExist;
        }

        pub fn deinit(self: *Self) void {
            for (0..self.entities.items.len) |i| {
                self.entities.items[i].component_set.deinit();
            }
            self.entities.deinit();
        }
    };
}

pub const Entity = struct {
    id: usize,

    pub fn init(id: usize) Entity {
        return .{
            .id = id,
        };
    }
};

pub fn World(comptime all_components: anytype, systems: anytype) type {
    // const components_manager = comptime ComponentsManager.init(all_components);

    return struct {
        const Self = @This();
        pub const components_manager = ComponentsManager.init(all_components);
        const EntityManagerType = EntityManager(components_manager);
        const SystemsManagerType = SystemsManager(systems);
        alloc: Allocator,
        systems: SystemsManagerType,
        entity_manager: *EntityManagerType,

        pub fn init(allocator: Allocator) !Self {
            const entity_manager = try allocator.create(EntityManagerType);
            entity_manager.* = EntityManagerType.init(allocator);
            return .{
                .alloc = allocator,
                .entity_manager = entity_manager,
                .systems = try SystemsManagerType.init(allocator, entity_manager, components_manager),
            };
        }

        pub fn getComponentBitmask(_: *const Self, comptime component: type) usize {
            return components_manager.getComponentPos(component);
        }

        pub fn printAll(self: *const Self) !void {
            try self.printEntities();
            self.printComponents();
        }

        pub fn printComponents(_: *const Self) void {
            std.debug.print("Components:\n", .{});
            inline for (@typeInfo(components_manager.GetTableEnum()).@"enum".fields) |f| {
                std.debug.print("  - {s} (id: {d})\n", .{ f.name, f.value });
            }
        }

        pub fn printEntities(self: *const Self) !void {
            std.debug.print("Entities:\n", .{});
            for (self.entity_manager.entities.items) |entity| {
                std.debug.print("  - {d}: \n    - ", .{entity.entity.id});
                entity.component_set.bitmask.print();
                std.debug.print("\n", .{});
                for (entity.component_set.components, 0..entity.component_set.components_len) |component, _| {
                    try pretty.print(self.alloc, component, .{ .fmt = "    - {s}\n", .inline_mode = true, .filter_field_names = .{
                        .exclude = &.{ "alloc", "allocator" },
                    } });
                }
            }
        }

        pub fn addEntity(self: *Self, comptime components: anytype) !void {
            try self.entity_manager.addEntity(components);
        }

        pub fn deinit(self: *Self) void {
            self.entity_manager.deinit();
            self.alloc.destroy(self.entity_manager);
        }

        pub fn printWithPretty(self: Self) !void {
            try pretty.print(self.alloc, self, .{ .filter_field_names = .{
                .exclude = &.{ "alloc", "allocator" },
            } });
            try pretty.print(self.alloc, components_manager, .{});
        }

        pub fn runSystems(self: *Self) !void {
            try self.systems.runAllUpdate(self.alloc, self.entity_manager, components_manager);
        }

        // pub fn query_world(self: *Self, comptime query: anytype) void {}
    };
}

test "Component bitmasks" {
    const Banana = struct {};
    const NotBanana = struct { i: usize };
    var world = World(.{ Banana, NotBanana }, .{}).init(std.testing.allocator);
    try std.testing.expectEqual(0, world.getComponentBitmask(Banana));
    try std.testing.expectEqual(1, world.getComponentBitmask(NotBanana));
}

test "Adding and Querying entities" {
    const Banana = struct {};
    const NotBanana = struct { i: usize };
    const NotBanana2 = struct {};
    const allocator = std.testing.allocator;
    var world = World(.{ Banana, NotBanana, NotBanana2 }, .{}).init(allocator);
    defer world.deinit();
    try world.add_entity(.{ Banana{}, NotBanana{ .i = 32 } });
    try world.add_entity(.{NotBanana{ .i = 13 }});
    var query_result = try Query(.{NotBanana}).init(allocator, world.entityManager, ComponentsManager.init(.{ Banana, NotBanana, NotBanana2 }));
    defer query_result.deinit();
}
