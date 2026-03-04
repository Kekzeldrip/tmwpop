--[[--------------------------------------------------------------------
    TMWPop – SimCParser.lua
    Parses SimulationCraft action-priority-list text into an internal
    rule / priority representation consumed by Engine.lua.
----------------------------------------------------------------------]]

local Parser = {}
TMWPop.SimCParser = Parser

--[[--------------------------------------------------------------------
    Data structures returned by the parser
----------------------------------------------------------------------]]

--[[
    Profile = {
        meta  = { class = "warrior", spec = "fury", ... },
        lists = {
            ["default"]   = { Rule, Rule, ... },
            ["precombat"] = { Rule, Rule, ... },
            ...
        },
    }

    Rule = {
        action   = "rampage",          -- spell / token name
        args     = { key = value },    -- everything after the first comma
        condTree = <condNode> | nil,   -- parsed "if" condition tree
    }

    condNode = {
        op    = "and" | "or" | "not" | "<" | ">" | "<=" | ">=" | "=" | "!="
                | "value",
        left  = condNode | nil,
        right = condNode | nil,
        value = <number | string>,     -- leaf value for "value" nodes
    }
----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
    Helpers
----------------------------------------------------------------------]]

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function normaliseKey(s)
    -- "crusader_strike" stays as-is; "Crusader Strike" → "crusader_strike"
    return s:lower():gsub("[%s%-]", "_")
end

--[[--------------------------------------------------------------------
    Tokeniser for condition expressions
----------------------------------------------------------------------]]

local TOK = {
    NUM    = "NUM",
    IDENT  = "IDENT",
    OP     = "OP",
    LPAREN = "(",
    RPAREN = ")",
    EOF    = "EOF",
}

local function tokenise(expr)
    local tokens = {}
    local pos = 1
    local len = #expr

    while pos <= len do
        -- skip whitespace
        local ws = expr:match("^%s+", pos)
        if ws then pos = pos + #ws end
        if pos > len then break end

        local ch = expr:sub(pos, pos)

        if ch == "(" then
            tokens[#tokens+1] = { type = TOK.LPAREN, value = "(" }
            pos = pos + 1
        elseif ch == ")" then
            tokens[#tokens+1] = { type = TOK.RPAREN, value = ")" }
            pos = pos + 1
        elseif ch == "!" and expr:sub(pos, pos+1) == "!=" then
            tokens[#tokens+1] = { type = TOK.OP, value = "!=" }
            pos = pos + 2
        elseif ch == "!" then
            tokens[#tokens+1] = { type = TOK.OP, value = "!" }
            pos = pos + 1
        elseif ch == "<" then
            if expr:sub(pos, pos+1) == "<=" then
                tokens[#tokens+1] = { type = TOK.OP, value = "<=" }
                pos = pos + 2
            else
                tokens[#tokens+1] = { type = TOK.OP, value = "<" }
                pos = pos + 1
            end
        elseif ch == ">" then
            if expr:sub(pos, pos+1) == ">=" then
                tokens[#tokens+1] = { type = TOK.OP, value = ">=" }
                pos = pos + 2
            else
                tokens[#tokens+1] = { type = TOK.OP, value = ">" }
                pos = pos + 1
            end
        elseif ch == "=" then
            tokens[#tokens+1] = { type = TOK.OP, value = "=" }
            pos = pos + 1
        elseif ch == "&" then
            tokens[#tokens+1] = { type = TOK.OP, value = "&" }
            pos = pos + 1
        elseif ch == "|" then
            tokens[#tokens+1] = { type = TOK.OP, value = "|" }
            pos = pos + 1
        else
            -- number
            local num = expr:match("^%-?%d+%.?%d*", pos)
            if num then
                tokens[#tokens+1] = { type = TOK.NUM, value = tonumber(num) }
                pos = pos + #num
            else
                -- identifier  (letters, digits, underscore, dot)
                local id = expr:match("^[%a_][%w_%.]*", pos)
                if id then
                    tokens[#tokens+1] = { type = TOK.IDENT, value = id }
                    pos = pos + #id
                else
                    -- skip unknown character
                    pos = pos + 1
                end
            end
        end
    end

    tokens[#tokens+1] = { type = TOK.EOF, value = "" }
    return tokens
end

--[[--------------------------------------------------------------------
    Recursive-descent parser for condition expressions
    Grammar (simplified):
        expr     → or_expr
        or_expr  → and_expr ( "|" and_expr )*
        and_expr → cmp_expr ( "&" cmp_expr )*
        cmp_expr → unary ( ( "=" | "!=" | "<" | ">" | "<=" | ">=" ) unary )?
        unary    → "!" unary | primary
        primary  → "(" expr ")" | NUMBER | IDENT
----------------------------------------------------------------------]]

local function parseExpr(tokens, pos)
    -- forward declarations
    local parseOr

    local function peek() return tokens[pos] end
    local function advance() local t = tokens[pos]; pos = pos + 1; return t end

    local function parsePrimary()
        local t = peek()
        if t.type == TOK.LPAREN then
            advance() -- consume (
            local node
            node, pos = parseOr(tokens, pos)
            if peek().type == TOK.RPAREN then advance() end
            return node, pos
        elseif t.type == TOK.NUM then
            advance()
            return { op = "value", value = t.value }, pos
        elseif t.type == TOK.IDENT then
            advance()
            return { op = "value", value = t.value }, pos
        else
            -- unexpected token – return a nil-safe node
            advance()
            return { op = "value", value = 0 }, pos
        end
    end

    local function parseUnary()
        if peek().type == TOK.OP and peek().value == "!" then
            advance()
            local node
            node, pos = parseUnary()
            return { op = "not", left = node }, pos
        end
        return parsePrimary()
    end

    local function parseCmp()
        local left
        left, pos = parseUnary()
        local t = peek()
        if t.type == TOK.OP and (t.value == "=" or t.value == "!=" or
           t.value == "<" or t.value == ">" or t.value == "<=" or t.value == ">=") then
            advance()
            local right
            right, pos = parseUnary()
            return { op = t.value, left = left, right = right }, pos
        end
        return left, pos
    end

    local function parseAnd()
        local left
        left, pos = parseCmp()
        while peek().type == TOK.OP and peek().value == "&" do
            advance()
            local right
            right, pos = parseCmp()
            left = { op = "and", left = left, right = right }
        end
        return left, pos
    end

    parseOr = function(toks, p)
        pos = p
        tokens = toks
        local left
        left, pos = parseAnd()
        while peek().type == TOK.OP and peek().value == "|" do
            advance()
            local right
            right, pos = parseAnd()
            left = { op = "or", left = left, right = right }
        end
        return left, pos
    end

    return parseOr(tokens, pos)
end

--- Public: parse a condition expression string into a tree.
--- @param expr string   e.g. "buff.enrage.up&cooldown.rampage.ready"
--- @return table condNode
function Parser.ParseCondition(expr)
    if not expr or expr == "" then return nil end
    local tokens = tokenise(expr)
    local tree = parseExpr(tokens, 1)
    return tree
end

--[[--------------------------------------------------------------------
    Parse a single action line's comma-separated args
----------------------------------------------------------------------]]

local function parseArgs(argStr)
    local args = {}
    for part in argStr:gmatch("[^,]+") do
        local k, v = part:match("^(.-)=(.+)$")
        if k then
            args[trim(k)] = trim(v)
        end
    end
    return args
end

--[[--------------------------------------------------------------------
    Parse a single "actions" line into one or more Rule objects.
----------------------------------------------------------------------]]

local function parseActionLine(line)
    -- line is e.g. "rampage,if=buff.enrage.up&rage>=80"
    local rules = {}
    -- split on "/" for OR-alternatives (rare but valid in some profiles)
    for segment in line:gmatch("[^/]+") do
        segment = trim(segment)
        local action, rest = segment:match("^([%w_]+),?(.*)")
        if action then
            local args = parseArgs(rest)
            local condTree = nil
            if args["if"] then
                condTree = Parser.ParseCondition(args["if"])
            end
            rules[#rules+1] = {
                action   = normaliseKey(action),
                args     = args,
                condTree = condTree,
            }
        end
    end
    return rules
end

--[[--------------------------------------------------------------------
    Main entry point: parse a full SimC profile string.
----------------------------------------------------------------------]]

--- @param text string  raw SimC profile (multi-line)
--- @return table Profile
function Parser.Parse(text)
    local profile = {
        meta  = {},
        lists = {},
    }

    for line in text:gmatch("[^\r\n]+") do
        line = trim(line)
        -- skip comments and blank lines
        if line == "" or line:sub(1,1) == "#" then
            -- noop

        -- metadata lines:  class=warrior, spec=fury, etc.
        elseif line:match("^%a[%a_]*=") and not line:match("^actions") then
            local key, value = line:match("^(%a[%a_]*)=(.+)$")
            if key then
                profile.meta[normaliseKey(key)] = trim(value)
            end

        -- action lines
        elseif line:match("^actions") then
            local listName, assign, body = line:match("^actions%.?([%w_]*)(%+?=)(.+)$")
            if body then
                listName = (listName == "" or listName == nil) and "default" or normaliseKey(listName)
                if assign == "=" and not profile.lists[listName] then
                    profile.lists[listName] = {}
                elseif assign == "+=" and not profile.lists[listName] then
                    profile.lists[listName] = {}
                end
                local list = profile.lists[listName]
                local rules = parseActionLine(body)
                for _, r in ipairs(rules) do
                    list[#list+1] = r
                end
            end
        end
    end

    return profile
end

--- Convenience: check if a profile has at least one action list.
function Parser.IsValid(profile)
    if not profile or not profile.lists then return false end
    for _ in pairs(profile.lists) do return true end
    return false
end
