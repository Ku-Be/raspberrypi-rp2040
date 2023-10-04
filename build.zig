const std = @import("std");
const microzig = @import("root").dependencies.imports.microzig; // HACK: Please import MicroZig always under the name `microzig`. Otherwise the RP2040 module will fail to be properly imported.

fn root() []const u8 {
    return comptime (std.fs.path.dirname(@src().file) orelse ".");
}
const build_root = root();

////////////////////////////////////////
//      MicroZig Gen 2 Interface      //
////////////////////////////////////////

pub fn build(b: *std.Build) !void {
    //  Dummy func to make package manager happy
    _ = b;
}

pub const chips = struct {
    // Note: This chip has no flash support defined and requires additional configuration!
    pub const rp2040 = .{
        .preferred_format = .{ .uf2 = .RP2040 },
        .chip = chip,
        .hal = hal,
        .board = null,
        .linker_script = linker_script,
    };
};

pub const boards = struct {
    pub const raspberry_pi = struct {
        pub const pico = .{
            .preferred_format = .{ .uf2 = .RP2040 },
            .chip = chip,
            .hal = hal,
            .linker_script = linker_script,
            .board = .{
                .name = "RaspberryPi Pico",
                .source_file = .{ .cwd_relative = build_root ++ "/src/boards/raspberry_pi_pico.zig" },
                .url = "https://www.raspberrypi.com/products/raspberry-pi-pico/",
            },
            .configure = rp2040_configure(.w25q080, .flash),
        };
        pub const pico_ram_only = .{
            .preferred_format = .{ .uf2 = .RP2040 },
            .chip = chip,
            .hal = hal,
            .linker_script = linker_script_ram_only,
            .board = .{
                .name = "RaspberryPi Pico",
                .source_file = .{ .cwd_relative = build_root ++ "/src/boards/raspberry_pi_pico.zig" },
                .url = "https://www.raspberrypi.com/products/raspberry-pi-pico/",
            },
            .configure = rp2040_configure(.w25q080, .ram),
        };
    };
};

pub const BootROM = union(enum) {
    artifact: *std.build.CompileStep, // provide a custom startup code
    blob: std.build.LazyPath, // just include a binary blob

    // Pre-shipped ones:
    at25sf128a,
    generic_03h,
    is25lp080,
    w25q080,
    w25x10cl,

    // Use the old stage2 bootloader vendored with MicroZig till 2023-09-13
    legacy,
};

pub const Storage = enum {
    flash,
    ram,
};

const linker_script = .{
    .source_file = .{ .cwd_relative = build_root ++ "/rp2040.ld" },
};

const linker_script_ram_only = .{
    .source_file = .{ .cwd_relative = build_root ++ "/rp2040-ram-only.ld"},
};

const hal = .{
    .source_file = .{ .cwd_relative = build_root ++ "/src/hal.zig" },
};

const chip = .{
    .name = "RP2040",
    .url = "https://www.raspberrypi.com/products/rp2040/",
    .cpu = .cortex_m0plus,
    .register_definition = .{
        .json = .{ .cwd_relative = build_root ++ "/src/chips/RP2040.json" },
    },
    .memory_regions = &.{
        .{ .kind = .flash, .offset = 0x10000100, .length = (2048 * 1024) - 256 },
        .{ .kind = .flash, .offset = 0x10000000, .length = 256 },
        .{ .kind = .ram, .offset = 0x20000000, .length = 256 * 1024 },
    },
};

/// Returns a configuration function that will add the provided `BootROM` to the firmware.
pub fn rp2040_configure(comptime bootrom: BootROM, comptime storage: Storage) *const fn (host_build: *std.Build, *microzig.Firmware) void {
    const T = struct {
        fn configure(host_build: *std.Build, fw: *microzig.Firmware) void {
            const bootrom_file = getBootrom(host_build, bootrom, storage);

            // HACK: Inject the file as a dependency to MicroZig.board
            fw.modules.board.?.dependencies.put(
                "bootloader",
                host_build.createModule(.{
                    .source_file = bootrom_file.bin,
                }),
            ) catch @panic("oom");
            bootrom_file.bin.addStepDependencies(&fw.artifact.step);
        }
    };

    return T.configure;
}

pub const Stage2Bootloader = struct {
    bin: std.Build.LazyPath,
    elf: ?std.Build.LazyPath,
};

pub fn getBootrom(b: *std.Build, rom: BootROM, storage: Storage) Stage2Bootloader {
    const rom_exe = switch (rom) {
        .artifact => |artifact| artifact,
        .blob => |blob| return Stage2Bootloader{
            .bin = blob,
            .elf = null,
        },

        else => blk: {
            var target = @as(microzig.CpuModel, chip.cpu).getDescriptor().target;
            target.abi = .eabi;

            const rom_path = b.pathFromRoot(b.fmt("{s}/src/bootroms/{s}.S", .{ build_root, @tagName(rom) }));

            const rom_exe = b.addExecutable(.{
                .name = b.fmt("stage2-{s}", .{@tagName(rom)}),
                .optimize = .ReleaseSmall,
                .target = target,
                .root_source_file = null,
            });
            rom_exe.linkage = .static;

            var suffix: []const u8 = undefined;
            switch (storage) {
                .flash => suffix = "",
                .ram => suffix = "-ram-only",
            }

            rom_exe.setLinkerScript(.{ .path = build_root ++ std.fmt("/src/bootroms/shared/stage2{s}.ld", .{suffix}) });
            rom_exe.addAssemblyFile(.{ .path = rom_path });
            rom_exe.addAssemblyFile(.{ .path = build_root ++ std.fmt("/src/bootroms/shared/exit_from_boot2{s}.S", .{suffix}) });

            break :blk rom_exe;
        },
    };

    const rom_objcopy = b.addObjCopy(rom_exe.getEmittedBin(), .{
        .basename = b.fmt("{s}.bin", .{@tagName(rom)}),
        .format = .bin,
    });

    return Stage2Bootloader{
        .bin = rom_objcopy.getOutput(),
        .elf = rom_exe.getEmittedBin(),
    };
}
