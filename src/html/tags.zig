const tables = @import("tables.zig");

pub fn isVoidTag(name: []const u8) bool {
    if (name.len == 0) return false;
    const c0 = tables.lower(name[0]);
    return switch (c0) {
        'a' => tables.eqlIgnoreCaseAscii(name, "area"),
        'b' => tables.eqlIgnoreCaseAscii(name, "base") or tables.eqlIgnoreCaseAscii(name, "br"),
        'c' => tables.eqlIgnoreCaseAscii(name, "col"),
        'e' => tables.eqlIgnoreCaseAscii(name, "embed"),
        'h' => tables.eqlIgnoreCaseAscii(name, "hr"),
        'i' => tables.eqlIgnoreCaseAscii(name, "img") or tables.eqlIgnoreCaseAscii(name, "input"),
        'l' => tables.eqlIgnoreCaseAscii(name, "link"),
        'm' => tables.eqlIgnoreCaseAscii(name, "meta"),
        'p' => tables.eqlIgnoreCaseAscii(name, "param"),
        's' => tables.eqlIgnoreCaseAscii(name, "source"),
        't' => tables.eqlIgnoreCaseAscii(name, "track"),
        'w' => tables.eqlIgnoreCaseAscii(name, "wbr"),
        else => false,
    };
}

pub fn isRawTextTag(name: []const u8) bool {
    if (name.len == 0) return false;
    const c0 = tables.lower(name[0]);
    if (c0 == 's') return tables.eqlIgnoreCaseAscii(name, "script") or tables.eqlIgnoreCaseAscii(name, "style");
    return false;
}

pub fn shouldImplicitlyClose(open_tag: []const u8, new_tag: []const u8) bool {
    if (open_tag.len == 0) return false;

    return switch (tables.lower(open_tag[0])) {
        'l' => tables.eqlIgnoreCaseAscii(open_tag, "li") and tables.eqlIgnoreCaseAscii(new_tag, "li"),
        'p' => tables.eqlIgnoreCaseAscii(open_tag, "p") and closesP(new_tag),
        'd' => blk: {
            if (tables.eqlIgnoreCaseAscii(open_tag, "dt")) {
                break :blk tables.eqlIgnoreCaseAscii(new_tag, "dt") or tables.eqlIgnoreCaseAscii(new_tag, "dd");
            }
            if (tables.eqlIgnoreCaseAscii(open_tag, "dd")) {
                break :blk tables.eqlIgnoreCaseAscii(new_tag, "dt") or tables.eqlIgnoreCaseAscii(new_tag, "dd");
            }
            break :blk false;
        },
        'o' => tables.eqlIgnoreCaseAscii(open_tag, "option") and tables.eqlIgnoreCaseAscii(new_tag, "option"),
        't' => blk: {
            if (tables.eqlIgnoreCaseAscii(open_tag, "tr")) {
                break :blk tables.eqlIgnoreCaseAscii(new_tag, "tr");
            }
            if (tables.eqlIgnoreCaseAscii(open_tag, "td") or tables.eqlIgnoreCaseAscii(open_tag, "th")) {
                break :blk tables.eqlIgnoreCaseAscii(new_tag, "td") or tables.eqlIgnoreCaseAscii(new_tag, "th");
            }
            break :blk false;
        },
        'h' => tables.eqlIgnoreCaseAscii(open_tag, "head") and tables.eqlIgnoreCaseAscii(new_tag, "body"),
        else => false,
    };
}

fn closesP(new_tag: []const u8) bool {
    return tables.eqlIgnoreCaseAscii(new_tag, "address") or
        tables.eqlIgnoreCaseAscii(new_tag, "article") or
        tables.eqlIgnoreCaseAscii(new_tag, "aside") or
        tables.eqlIgnoreCaseAscii(new_tag, "blockquote") or
        tables.eqlIgnoreCaseAscii(new_tag, "div") or
        tables.eqlIgnoreCaseAscii(new_tag, "dl") or
        tables.eqlIgnoreCaseAscii(new_tag, "fieldset") or
        tables.eqlIgnoreCaseAscii(new_tag, "footer") or
        tables.eqlIgnoreCaseAscii(new_tag, "form") or
        tables.eqlIgnoreCaseAscii(new_tag, "h1") or
        tables.eqlIgnoreCaseAscii(new_tag, "h2") or
        tables.eqlIgnoreCaseAscii(new_tag, "h3") or
        tables.eqlIgnoreCaseAscii(new_tag, "h4") or
        tables.eqlIgnoreCaseAscii(new_tag, "h5") or
        tables.eqlIgnoreCaseAscii(new_tag, "h6") or
        tables.eqlIgnoreCaseAscii(new_tag, "header") or
        tables.eqlIgnoreCaseAscii(new_tag, "hr") or
        tables.eqlIgnoreCaseAscii(new_tag, "main") or
        tables.eqlIgnoreCaseAscii(new_tag, "nav") or
        tables.eqlIgnoreCaseAscii(new_tag, "ol") or
        tables.eqlIgnoreCaseAscii(new_tag, "p") or
        tables.eqlIgnoreCaseAscii(new_tag, "pre") or
        tables.eqlIgnoreCaseAscii(new_tag, "section") or
        tables.eqlIgnoreCaseAscii(new_tag, "table") or
        tables.eqlIgnoreCaseAscii(new_tag, "ul");
}
