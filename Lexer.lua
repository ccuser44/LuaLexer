--[=[
	Lexical scanner for creating a sequence of tokens from Lua source code.
	This is a heavily modified version of
	the original Penlight Lexer module:
		https://github.com/stevedonovan/Penlight
	Authors:
		stevedonovan <https://github.com/stevedonovan> ----------- Original Penlight lexer author
		ryanjmulder <https://github.com/ryanjmulder> ------------- Penlight lexer contributer
		mpeterv <https://github.com/mpeterv> --------------------- Penlight lexer contributer
		Tieske <https://github.com/Tieske> ----------------------- Penlight lexer contributer
		boatbomber <https://github.com/boatbomber> --------------- Roblox port, added builtin token, added patterns for incomplete syntax, bug fixes, behavior changes, token optimization
		Sleitnick <https://github.com/Sleitnick> ----------------- Roblox optimizations
		howmanysmall <https://github.com/howmanysmall> ----------- Lua + Roblox optimizations
		boatbomber <https://github.com/boatbomber> --------------- Added lexer.navigator() for non-sequential reads
		ccuser44 <https://github.com/ccuser44> ------------------- Forked from boatbomber, removed "plugin" and "self" from lua_keyword table as they are not keywords, made some changes with whitespace and made some other changes to make the use of the lexer be more applicable in uses outside of syntax highlighting
	
	List of possible tokens:
		- iden
		- keyword
		- string
		- number
		- comment
		- operator
	
	Usage:
		local source = "for i = 1, n do end"
		
		-- The 'scan' function returns a token iterator:
		for token,src in lexer.scan(source) do
			print(token, "'"..src.."'")
		end
		-->	keyword 'for '
		-->	iden 'i '
		-->	operator '= '
		-->	number '1'
		-->	operator ', '
		-->	iden 'n '
		-->	keyword 'do '
		-->	keyword 'end'
		
		-- The 'navigator' function returns a navigator object:
		-- Navigators allow you to use nav.Peek() for non-sequential reads
		local nav = lexer.navigator()
		nav:SetSource(source) -- You can reuse navigators by setting a new Source
		
		for token,src in nav.Next do
			print(token, "'"..src.."'")
			local peektoken, peeksrc = nav.Peek(2) -- You can peek backwards by passing a negative input
			if peektoken then
				print("  Peeked ahead by 2:", peektoken, "'"..peeksrc.."'")
			end
		end
		
		-->	keyword 'for '
		-->	  Peeked ahead by 2: operator '= '
		-->	iden 'i '
		-->	  Peeked ahead by 2: number '1'
		-->	operator '= '
		-->	  Peeked ahead by 2: operator ', '
		-->	number '1'
		-->	  Peeked ahead by 2: iden 'n '
		-->	operator ', '
		-->	  Peeked ahead by 2: keyword 'do '
		-->	iden 'n '
		-->	  Peeked ahead by 2: keyword 'end'
		-->	keyword 'do '
		-->	keyword 'end'
			
	
--]=]

local lexer = {}

local Prefix, Suffix, Cleaner = "^[ \t\n\0\a\b\v\f\r]*", "[ \t\n\0\a\b\v\f\r]*", "[ \t\n\0\a\b\v\f\r]+"
local NUMBER_A = "0[xX][%da-fA-F]+"
local NUMBER_B = "%d+%.?%d*[eE][%+%-]?%d+"
local NUMBER_C = "%d+[%.]?[%deE]*"
local VARARG = "%.%.%"
local CONCAT_OP = "%.%."
local LOREQ_OP, GOREQ_OP, NOTEQ_OP, EQ_OP = "<=", ">=", "~=", "=="
local OPERATORS = "[;<>/%*%(%)%-=,{}%.#%^%+%%]"
local BRACKETS = "[%[%]]" -- needs to be separate pattern from other operators or it'll mess up multiline strings
local IDEN = "[%a_][%w_]*"
local STRING_EMPTY = "(['\"])%1"							--Empty String
local STRING_PLAIN = [=[(['"])[%w%p \t\v\b\f\r\a]-([^%\]%1)]=]	--TODO: Handle escaping escapes
local STRING_INCOMP_A = "(['\"]).-\n"						--Incompleted String with next line
local STRING_INCOMP_B = "(['\"])[^\n]*"					--Incompleted String without next line
local STRING_MULTI = "%[(=*)%[.-%]%1%]"					--Multiline-String
local STRING_MULTI_INCOMP = "%[=*%[.-.*"						--Incompleted Multiline-String
local COMMENT_MULTI = "%-%-%[(=*)%[.-%]%1%]"				--Completed Multiline-Comment
local COMMENT_MULTI_INCOMP = "%-%-%[=*%[.-.*"				--Incompleted Multiline-Comment
local COMMENT_PLAIN = "%-%-.-\n"							--Completed Singleline-Comment
local COMMENT_INCOMP = "%-%-.*"							--Incompleted Singleline-Comment

local TABLE_EMPTY = {}

local lua_keyword = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
	["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
	["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["while"] = true,
	["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true,
}

local implementation_spesific = {
	Lua = { -- Any version of lua. Could be used for example where you want to have it for Lua in general not just a spesific version. If not specified a version the parser will default to this.
		keywords = {
			"continue", "goto", "<const>", "<toclose>"
		},
		operators = {
			NOTEQ_OP, "%+=", "%-=", "%*=", "/=", "%%=", "%^=", "%.%.=", ">>", "<<", "::", "=>",  "[:&|~]", "//"
		},
		numbers = {
			"%d+[%._]?[%_deE]*", "0[bB][01_]+", "0[xX][_%da-fA-F]+"
		},
	},
	["Lua 5.2"] = {
		keywords = {
			"goto"
		}
		operators = {
			"::"
		}
	},
	["Lua 5.3"] = {
		keywords = {
			"goto"
		},
		operators = {
			NOTEQ_OP, --[[Has to be added due to bitwise operators]] ">>", "<<", "::", "[&|~]", "//"
		}
	},
	["Lua 5.4"] = {
		keywords = {
			"goto", "<const>", "<toclose>"
		},
		operators = {
			NOTEQ_OP, --[[Has to be added due to bitwise operators]] ">>", "<<", "::", "[&|~]", "//"
		}
	},
	LuaU = {
		keywords = {
			"continue",
		},
		operators = {
			NOTEQ_OP, "%+=", "%-=", "%*=", "/=", "%%=", "%^=", "%.%.=", "=>", "[:|~]"
		},
		numbers = {
			"%d+[%._]?[%_deE]*", "0[bB][01_]+", "0[xX][_%da-fA-F]+"
		},
	}
}

local function idump(tok)
	--print("tok unknown:",tok)
	return coroutine.yield("iden", tok)
end

local function odump(tok)
	return coroutine.yield("operator", tok)
end

local function ndump(tok)
	return coroutine.yield("number", tok)
end

local function sdump(tok)
	return coroutine.yield("string", tok)
end

local function cdump(tok)
	return coroutine.yield("comment", tok)
end

local function kdump(tok)
	return coroutine.yield("keyword", tok)
end

local function lua_vdump(tok, implementation)
	-- Since we merge spaces into the tok, we need to remove them
	-- in order to check the actual word it contains
	local cleanTok = string.gsub(tok, Cleaner, "")

	if lua_keyword[cleanTok] then
		return coroutine.yield("keyword", tok)
	else
		return coroutine.yield("iden", tok)
	end
end

local lua_matches = {
	-- Indentifiers
	{Prefix.. IDEN ..Suffix, lua_vdump},
	{Prefix.. VARARG ..Suffix, kdump},

	-- Numbers
	{Prefix.. NUMBER_A ..Suffix, ndump},
	{Prefix.. NUMBER_B ..Suffix, ndump},
	{Prefix.. NUMBER_C ..Suffix, ndump},

	-- Strings
	{Prefix.. STRING_EMPTY ..Suffix, sdump},
	{Prefix.. STRING_PLAIN ..Suffix, sdump},
	{Prefix.. STRING_INCOMP_A ..Suffix, sdump},
	{Prefix.. STRING_INCOMP_B ..Suffix, sdump},
	{Prefix.. STRING_MULTI ..Suffix, sdump},
	{Prefix.. STRING_MULTI_INCOMP ..Suffix, sdump},

	-- Comments
	{Prefix.. COMMENT_MULTI ..Suffix, cdump},			
	{Prefix.. COMMENT_MULTI_INCOMP ..Suffix, cdump},
	{Prefix.. COMMENT_PLAIN ..Suffix, cdump},
	{Prefix.. COMMENT_INCOMP ..Suffix, cdump},

	-- Operators
	{Prefix.. CONCAT_OP ..Suffix, odump},
	{Prefix.. LOREQ_OP ..Suffix, odump},
	{Prefix.. GOREQ_OP ..Suffix, odump},
	{Prefix.. NOTEQ_OP ..Suffix, odump},
	{Prefix.. EQ_OP ..Suffix, odump},
	{Prefix.. OPERATORS ..Suffix, odump},
	{Prefix.. BRACKETS ..Suffix, odump},

	-- Unknown
	{"^.", idump}
}

local implementation_spesific_matches = {}

for version, data in pairs(implementation_spesific) do
	local NewTable = {}
	local keywords, operators, numbers = data.keywords, data.operators, data.numbers
	if keywords then
		for _, v in ipairs(keywords) do
			table.insert(NewTable, {Prefix.. v ..Suffix, kdump})
		end
	end
	if numbers then
		for _, v in ipairs(numbers) do
			table.insert(NewTable, {Prefix.. v ..Suffix, ndump})
		end
	end
	if operators then
		for _, v in ipairs(operators) do
			table.insert(NewTable, {Prefix.. v ..Suffix, odump})
		end
	end
	implementation_spesific_matches[version] = NewTable
end

--- Create a plain token iterator from a string.
-- @tparam string s a string.	

function lexer.scan(s, include_wspace, merge_wspace, implementation)
	local startTime = os.clock()
	lexer.finished = false
	assert(type(s) == "string" and s), "invalid argument #1 to 'scan' (string expected, got " .. type(s))
	local matches
	do
		local implementation = (implementation and assert(type(implementation) == "string" and implementation), "bad argument #4 to 'scan' (string expected, got " .. type(implementation)) or "Lua"
		matches = (implementation and implementation_spesific_matches[implementation]) {(table.unpack or unpack)(implementation_spesific_matches[implementation]), (table.unpack or unpack)(lua_matches)} or lua_matches
	end

	local function lex(first_arg)
		local line_nr = 0
		local sz = #s
		local idx = 1

		-- res is the value used to resume the coroutine.
		local function handle_requests(res)
			while res do
				local tp = type(res)
				-- Insert a token list:
				if tp == "table" then
					res = coroutine.yield("", "")
					for _, t in ipairs(res) do
						res = coroutine.yield(t[1], t[2])
					end
				elseif tp == "string" then -- Or search up to some special pattern:
					local i1, i2 = string.find(s, res, idx)
					if i1 then
						idx = i2 + 1
						res = coroutine.yield("", string.sub(s, i1, i2))
					else
						res = coroutine.yield("", "")
						idx = sz + 1
					end
				else
					res = coroutine.yield(line_nr, idx)
				end
			end
		end

		handle_requests(first_arg)
		line_nr = 1

		while true do
			if idx > sz then
				while true do
					handle_requests(coroutine.yield())
				end
			end
			for _, m in ipairs(matches) do
				local findres = {}
				local i1, i2 = string.find(s, m[1], idx)
				findres[1], findres[2] = i1, i2
				if i1 then
					local tok = string.sub(s, i1, i2)
					idx = i2 + 1
					lexer.finished = idx > sz
					--if lexer.finished then
					--	print(string.format("Lex took %.2f ms", (os.clock()-startTime)*1000 ))
					--end

					local res = m[2](tok, findres)

					if string.find(tok, "\n") then
						-- Update line number:
						local _, newlines = string.gsub(tok, "\n", TABLE_EMPTY)
						line_nr = line_nr + newlines
					end

					handle_requests(res)
					break
				end
			end
		end
	end
	return coroutine.wrap(lex)
end

function lexer.navigator()

	local nav = {
		Source = "";
		TokenCache = table.create and table.create(50) or {};

		_RealIndex = 0;
		_UserIndex = 0;
		_ScanThread = nil;
	}

	function nav:Destroy()
		self.Source = nil
		self._RealIndex = nil;
		self._UserIndex = nil;
		self.TokenCache = nil;
		self._ScanThread = nil;
	end

	function nav:SetSource(SourceString)
		self.Source = assert(type(SourceString) == "string") and SourceString, "Attempt to SetSource failed: Passed value is not a string")

		self._RealIndex = 0;
		self._UserIndex = 0;
		if table.clear then
			table.clear(self.TokenCache)
		else
			self.TokenCache = {}
		end

		self._ScanThread = coroutine.create(function()
			for Token, Src in lexer.scan(self.Source) do
				self._RealIndex = self._RealIndex + 1
				self.TokenCache[self._RealIndex] = {Token; Src;}
				coroutine.yield(Token,Src)
			end
		end)
	end

	function nav.Next()
		nav._UserIndex = nav._UserIndex + 1

		if nav._RealIndex >= nav._UserIndex then
			-- Already scanned, return cached
			return (table.unpack or unpack)(nav.TokenCache[nav._UserIndex])
		else
			if coroutine.status(nav._ScanThread) == "dead" then
				-- Scan thread dead
				return
			else
				local success, token, src = coroutine.resume(nav._ScanThread)
				if success and token then
					-- Scanned new data
					return token, src
				else
					-- Lex completed
					return
				end
			end
		end

	end

	function nav.Peek(PeekAmount)
		local GoalIndex = nav._UserIndex + PeekAmount

		if nav._RealIndex >= GoalIndex then
			-- Already scanned, return cached
			if GoalIndex > 0 then
				return (table.unpack or unpack)(nav.TokenCache[GoalIndex])
			else
				-- Invalid peek
				return
			end
		else
			if coroutine.status(nav._ScanThread) == "dead" then
				-- Scan thread dead
				return
			else

				local IterationsAway = GoalIndex - nav._RealIndex

				local success, token, src = nil, nil, nil

				for i = 1, IterationsAway do
					success, token, src = coroutine.resume(nav._ScanThread)
					if not (success or token) then
						-- Lex completed
						break
					end
				end

				return token, src
			end
		end

	end

	return nav
end

return lexer
