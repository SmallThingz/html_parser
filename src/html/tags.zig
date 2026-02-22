const tables = @import("tables.zig");

const void_tags = [_][]const u8{
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
};

const raw_text_tags = [_][]const u8{
    "script", "style",
};

pub fn isVoidTag(name: []const u8) bool {
    for (void_tags) |tag| {
        if (tables.eqlIgnoreCaseAscii(name, tag)) return true;
    }
    return false;
}

pub fn isRawTextTag(name: []const u8) bool {
    for (raw_text_tags) |tag| {
        if (tables.eqlIgnoreCaseAscii(name, tag)) return true;
    }
    return false;
}

pub fn shouldImplicitlyClose(open_tag: []const u8, new_tag: []const u8) bool {
    if (tables.eqlIgnoreCaseAscii(open_tag, "li") and tables.eqlIgnoreCaseAscii(new_tag, "li")) return true;
    if (tables.eqlIgnoreCaseAscii(open_tag, "p") and closesP(new_tag)) return true;

    if (tables.eqlIgnoreCaseAscii(open_tag, "dt") and (tables.eqlIgnoreCaseAscii(new_tag, "dt") or tables.eqlIgnoreCaseAscii(new_tag, "dd"))) return true;
    if (tables.eqlIgnoreCaseAscii(open_tag, "dd") and (tables.eqlIgnoreCaseAscii(new_tag, "dt") or tables.eqlIgnoreCaseAscii(new_tag, "dd"))) return true;

    if (tables.eqlIgnoreCaseAscii(open_tag, "option") and tables.eqlIgnoreCaseAscii(new_tag, "option")) return true;

    if (tables.eqlIgnoreCaseAscii(open_tag, "tr") and tables.eqlIgnoreCaseAscii(new_tag, "tr")) return true;

    if ((tables.eqlIgnoreCaseAscii(open_tag, "td") or tables.eqlIgnoreCaseAscii(open_tag, "th")) and
        (tables.eqlIgnoreCaseAscii(new_tag, "td") or tables.eqlIgnoreCaseAscii(new_tag, "th"))) return true;

    if (tables.eqlIgnoreCaseAscii(open_tag, "head") and tables.eqlIgnoreCaseAscii(new_tag, "body")) return true;

    return false;
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
