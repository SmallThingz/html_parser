const std = @import("std");
const tables = @import("tables.zig");

pub const TagHashValue = u64;
const InvalidTagHash: TagHashValue = std.math.maxInt(TagHashValue);

pub const TagHash = struct {
    value_: TagHashValue = 0,

    pub fn init() TagHash {
        return .{};
    }

    pub fn update(self: *TagHash, c: u8) void {
        if (self.value_ == InvalidTagHash) return;
        if ((self.value_ >> (64 - 5)) != 0) {
            self.value_ = InvalidTagHash;
            return;
        }

        const code: TagHashValue = switch (c) {
            'a'...'z', 'A'...'Z' => (@as(TagHashValue, c & 0x1f) + 5),
            '1'...'6' => (@as(TagHashValue, c & 0x0f) - 1),
            else => {
                self.value_ = InvalidTagHash;
                return;
            },
        };
        self.value_ = (self.value_ << 5) | code;
    }

    pub fn value(self: TagHash) TagHashValue {
        return self.value_;
    }
};

pub fn hashBytes(name: []const u8) TagHashValue {
    var h = TagHash.init();
    for (name) |c| h.update(c);
    return h.value();
}

fn comptimeHash(comptime name: []const u8) TagHashValue {
    return comptime hashBytes(name);
}

const HASH_AREA = comptimeHash("area");
const HASH_BASE = comptimeHash("base");
const HASH_BR = comptimeHash("br");
const HASH_COL = comptimeHash("col");
const HASH_EMBED = comptimeHash("embed");
const HASH_HR = comptimeHash("hr");
const HASH_IMG = comptimeHash("img");
const HASH_INPUT = comptimeHash("input");
const HASH_LINK = comptimeHash("link");
const HASH_META = comptimeHash("meta");
const HASH_PARAM = comptimeHash("param");
const HASH_SOURCE = comptimeHash("source");
const HASH_TRACK = comptimeHash("track");
const HASH_WBR = comptimeHash("wbr");
const HASH_SCRIPT = comptimeHash("script");
const HASH_STYLE = comptimeHash("style");

const HASH_LI = comptimeHash("li");
const HASH_P = comptimeHash("p");
const HASH_DT = comptimeHash("dt");
const HASH_DD = comptimeHash("dd");
const HASH_OPTION = comptimeHash("option");
const HASH_TR = comptimeHash("tr");
const HASH_TD = comptimeHash("td");
const HASH_TH = comptimeHash("th");
const HASH_HEAD = comptimeHash("head");
const HASH_BODY = comptimeHash("body");

const HASH_ADDRESS = comptimeHash("address");
const HASH_ARTICLE = comptimeHash("article");
const HASH_ASIDE = comptimeHash("aside");
const HASH_BLOCKQUOTE = comptimeHash("blockquote");
const HASH_DIV = comptimeHash("div");
const HASH_DL = comptimeHash("dl");
const HASH_FIELDSET = comptimeHash("fieldset");
const HASH_FOOTER = comptimeHash("footer");
const HASH_FORM = comptimeHash("form");
const HASH_H1 = comptimeHash("h1");
const HASH_H2 = comptimeHash("h2");
const HASH_H3 = comptimeHash("h3");
const HASH_H4 = comptimeHash("h4");
const HASH_H5 = comptimeHash("h5");
const HASH_H6 = comptimeHash("h6");
const HASH_HEADER = comptimeHash("header");
const HASH_MAIN = comptimeHash("main");
const HASH_NAV = comptimeHash("nav");
const HASH_OL = comptimeHash("ol");
const HASH_PRE = comptimeHash("pre");
const HASH_SECTION = comptimeHash("section");
const HASH_TABLE = comptimeHash("table");
const HASH_UL = comptimeHash("ul");

pub fn isVoidTag(name: []const u8) bool {
    return isVoidTagHash(name, hashBytes(name));
}

pub fn isRawTextTag(name: []const u8) bool {
    return isRawTextTagHash(name, hashBytes(name));
}

pub fn shouldImplicitlyClose(open_tag: []const u8, new_tag: []const u8) bool {
    return shouldImplicitlyCloseHash(open_tag, hashBytes(open_tag), new_tag, hashBytes(new_tag));
}

pub fn isVoidTagHash(name: []const u8, name_hash: TagHashValue) bool {
    return hashEq(name, name_hash, HASH_AREA, "area") or
        hashEq(name, name_hash, HASH_BASE, "base") or
        hashEq(name, name_hash, HASH_BR, "br") or
        hashEq(name, name_hash, HASH_COL, "col") or
        hashEq(name, name_hash, HASH_EMBED, "embed") or
        hashEq(name, name_hash, HASH_HR, "hr") or
        hashEq(name, name_hash, HASH_IMG, "img") or
        hashEq(name, name_hash, HASH_INPUT, "input") or
        hashEq(name, name_hash, HASH_LINK, "link") or
        hashEq(name, name_hash, HASH_META, "meta") or
        hashEq(name, name_hash, HASH_PARAM, "param") or
        hashEq(name, name_hash, HASH_SOURCE, "source") or
        hashEq(name, name_hash, HASH_TRACK, "track") or
        hashEq(name, name_hash, HASH_WBR, "wbr");
}

pub fn isRawTextTagHash(name: []const u8, name_hash: TagHashValue) bool {
    return hashEq(name, name_hash, HASH_SCRIPT, "script") or
        hashEq(name, name_hash, HASH_STYLE, "style");
}

pub fn shouldImplicitlyCloseHash(open_tag: []const u8, open_hash: TagHashValue, new_tag: []const u8, new_hash: TagHashValue) bool {
    if (hashEq(open_tag, open_hash, HASH_LI, "li") and hashEq(new_tag, new_hash, HASH_LI, "li")) return true;
    if (hashEq(open_tag, open_hash, HASH_P, "p") and closesPHash(new_tag, new_hash)) return true;

    if (hashEq(open_tag, open_hash, HASH_DT, "dt") and (hashEq(new_tag, new_hash, HASH_DT, "dt") or hashEq(new_tag, new_hash, HASH_DD, "dd"))) return true;
    if (hashEq(open_tag, open_hash, HASH_DD, "dd") and (hashEq(new_tag, new_hash, HASH_DT, "dt") or hashEq(new_tag, new_hash, HASH_DD, "dd"))) return true;

    if (hashEq(open_tag, open_hash, HASH_OPTION, "option") and hashEq(new_tag, new_hash, HASH_OPTION, "option")) return true;

    if (hashEq(open_tag, open_hash, HASH_TR, "tr") and hashEq(new_tag, new_hash, HASH_TR, "tr")) return true;

    if ((hashEq(open_tag, open_hash, HASH_TD, "td") or hashEq(open_tag, open_hash, HASH_TH, "th")) and
        (hashEq(new_tag, new_hash, HASH_TD, "td") or hashEq(new_tag, new_hash, HASH_TH, "th"))) return true;

    if (hashEq(open_tag, open_hash, HASH_HEAD, "head") and hashEq(new_tag, new_hash, HASH_BODY, "body")) return true;

    return false;
}

fn closesPHash(new_tag: []const u8, new_hash: TagHashValue) bool {
    return hashEq(new_tag, new_hash, HASH_ADDRESS, "address") or
        hashEq(new_tag, new_hash, HASH_ARTICLE, "article") or
        hashEq(new_tag, new_hash, HASH_ASIDE, "aside") or
        hashEq(new_tag, new_hash, HASH_BLOCKQUOTE, "blockquote") or
        hashEq(new_tag, new_hash, HASH_DIV, "div") or
        hashEq(new_tag, new_hash, HASH_DL, "dl") or
        hashEq(new_tag, new_hash, HASH_FIELDSET, "fieldset") or
        hashEq(new_tag, new_hash, HASH_FOOTER, "footer") or
        hashEq(new_tag, new_hash, HASH_FORM, "form") or
        hashEq(new_tag, new_hash, HASH_H1, "h1") or
        hashEq(new_tag, new_hash, HASH_H2, "h2") or
        hashEq(new_tag, new_hash, HASH_H3, "h3") or
        hashEq(new_tag, new_hash, HASH_H4, "h4") or
        hashEq(new_tag, new_hash, HASH_H5, "h5") or
        hashEq(new_tag, new_hash, HASH_H6, "h6") or
        hashEq(new_tag, new_hash, HASH_HEADER, "header") or
        hashEq(new_tag, new_hash, HASH_HR, "hr") or
        hashEq(new_tag, new_hash, HASH_MAIN, "main") or
        hashEq(new_tag, new_hash, HASH_NAV, "nav") or
        hashEq(new_tag, new_hash, HASH_OL, "ol") or
        hashEq(new_tag, new_hash, HASH_P, "p") or
        hashEq(new_tag, new_hash, HASH_PRE, "pre") or
        hashEq(new_tag, new_hash, HASH_SECTION, "section") or
        hashEq(new_tag, new_hash, HASH_TABLE, "table") or
        hashEq(new_tag, new_hash, HASH_UL, "ul");
}

fn hashEq(name: []const u8, name_hash: TagHashValue, expected_hash: TagHashValue, expected_name: []const u8) bool {
    if (name_hash == expected_hash) return true;
    if (name_hash == InvalidTagHash) return tables.eqlIgnoreCaseAscii(name, expected_name);
    return false;
}
