-- Be warned, here be dragons

api = require "love-api.love_api"

-- A workaround, rename the event enum
for i, v in ipairs(api.modules) do
	if v.name == "event" then
		v.enums[1].name = "EventType"

		-- Weeeeeee
		for i, v in ipairs(v.functions) do
			for j, w in ipairs(v.variants or {}) do
				for k, x in ipairs(w.arguments or {}) do
					if x.type == "Event" then
						x.type = "EventType"
					end
				end
			end
		end
		break
	end
end

do -- THIS IS AN UGLY HACK
	local imports =
	{
		["love/graphics/Graphics.hx"] = {"love.filesystem.File", "love.filesystem.FileData", "love.image.ImageData", "love.image.CompressedImageData", "love.video.VideoStream"},
		["love/graphics/Video.hx"] = {"love.audio.Source", "love.video.VideoStream"},
		["love/graphics/Image.hx"] = {"love.image.ImageData", "love.image.CompressedImageData"},
		["love/graphics/Canvas.hx"] = {"love.image.ImageData"},
		["love/image/ImageData.hx"] = {"love.filesystem.FileData"},
		["love/Love.hx"] = {"love.filesystem.File", "love.joystick.Joystick", "love.joystick.GamepadAxis", "love.joystick.GamepadButton", "love.joystick.JoystickHat", "love.thread.Thread"},
		["love/thread/Thread.hx"] = {"love.filesystem.FileData"},
	}

	function resolveImports(files)
		for i, v in pairs(files) do
			local importStr = {}
			for j, w in ipairs(imports[i] or {}) do
				table.insert(importStr, ("import %s;"):format(w))
			end
			importStr = table.concat(importStr, "\n")

			local pkg, rest = v:match("^(.-)\n(.+)$")
			files[i] = pkg .. "\n" .. importStr .. "\n" .. rest
		end
	end
end

do -- YET ANOTHER UGLY HACK
	local typeOrder = 
	{
		"Object",
		"Data",
		"Drawable",
		"Texture",
		"Shape",
		"Joint",
	}

	local function find(t, value)
		for i, v in ipairs(t) do
			if v == value then return i end
		end
		print("Unknown supertype: ", value)
	end

	function mostSpecificSupertype(t)
		local maxVal, maxPos = "UserData", 0
		for i, v in ipairs(t) do
			local pos = find(typeOrder, v)
			if pos and pos > maxPos then
				maxVal, maxPos = v, pos
			end
		end
		return maxVal
	end
end

do
	local map =
	{
		number = "Float",
		string = "String",
		boolean = "Bool",
		table = "Table<Dynamic,Dynamic>",
		["light userdata"] = "UserData",
		userdata = "UserData",
		["function"] = "Dynamic", -- FIXME
		mixed = "Dynamic",
		value = "Dynamic",
		any = "Dynamic",

		-- FIXME
		["ShaderVariableType"] = "String",
		["KeyConstant"] = "String",
		["Scancode"] = "String",
	}
	
	function typeMap(t)
		return map[t] or t
	end
end

function capitalize(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

function mergeTables(target, src, prefix)
	prefix = prefix or ""
	for i, v in pairs(src) do
		target[prefix .. i] = v
	end
	return target
end

function dirname(path)
	return path:match("^(.-)/?[^/]+$")
end

function emitOverload(o)
	local args = {}
	for i, v in ipairs(o.arguments or {}) do
		if v.name == "..." then
			table.insert(args, ("args:Rest<%s>"):format(typeMap(v.type)))
		else
			table.insert(args, v.name .. ":" .. typeMap(v.type))
		end
	end
	local retType = "Void"
	if o.returns then -- TODO: multiple returns
		retType = typeMap(o.returns[1].type)
	end
	return ("(%s) : %s"):format(table.concat(args, ", "), retType)
end

function emitCallback(c)
	local type = {}
	for i, v in ipairs(c.variants[1].arguments or {}) do -- TODO: Multiple variants? Does that even exist?
		table.insert(type, typeMap(v.type))
	end

	if c.variants[1].returns then -- TODO: Multiple returns?
		table.insert(type, typeMap(c.variants[1].returns[1].type))
	else
		table.insert(type, "Void")
	end

	-- If there are no arguments, prepend Void
	if #type == 1 then
		table.insert(type, 1, "Void")
	end

	type = table.concat(type, "->")

	return ("\tpublic static var %s : %s;"):format(c.name, type)
end

function rawEmitFunction(f, static)
	local out = {""}

	local sigs = {}
	for i, v in ipairs(f.variants) do
		table.insert(sigs, emitOverload(v))
	end

	local main = table.remove(sigs, 1)
	for i, v in ipairs(sigs) do
		table.insert(out, ("\t@:overload(function %s {})"):format(v))
	end
	table.insert(out, ("\tpublic%s function %s%s;"):format(static and " static" or "", f.name, main))
	return table.concat(out, "\n")
end

function emitFunction(f)
	return rawEmitFunction(f, true)
end

function emitMethod(m)
	return rawEmitFunction(m, false)
end

function emitEnum(e, packageName)
	local out = {}
	table.insert(out, ("package %s;"):format(packageName))
	table.insert(out, "@:enum")
	table.insert(out, ("abstract %s (String)\n{"):format(e.name))

	for i, v in ipairs(e.constants) do
		table.insert(out, ("\tvar %s = \"%s\";"):format(capitalize(v.name), v.name))
	end

	table.insert(out, "}")
	return {[e.name .. ".hx"] = table.concat(out, "\n")}
end

function emitHeader(out, packageName)
	table.insert(out, ("package %s;"):format(packageName))
	table.insert(out, "import haxe.extern.Rest;")
	table.insert(out, "import lua.Table;")
	table.insert(out, "import lua.UserData;")
	table.insert(out, "")
end

function emitType(t, packageName)
	local out = {}
	emitHeader(out, packageName)

	-- TODO: Select proper supertype
	local superType = t.supertypes and mostSpecificSupertype(t.supertypes) or "UserData"
	table.insert(out, ("extern class %s extends %s\n{"):format(t.name, superType))

	for i, v in ipairs(t.functions or {}) do
		table.insert(out, emitMethod(v))
	end

	table.insert(out, "}")
	return {[t.name .. ".hx"] = table.concat(out, "\n")}
end

function emitModule(m, luaName)
	local out = {}
	local files = {}

	local moduleName = luaName or "love." .. m.name
	local prefix = moduleName:gsub("%.", "/") .. "/"
	emitHeader(out, moduleName)
	table.insert(out, ("@:native(\"%s\")"):format(moduleName))
	table.insert(out, ("extern class %s"):format(capitalize(luaName or m.name)))
	table.insert(out, "{")

	for i, v in ipairs(m.functions) do
		table.insert(out, emitFunction(v))
	end

	for i, v in ipairs(m.callbacks or {}) do
		table.insert(out, emitCallback(v))
	end

	table.insert(out, "}")

	for i, v in ipairs(m.enums or {}) do
		mergeTables(files, emitEnum(v, moduleName), prefix)
	end

	for i, v in ipairs(m.types or {}) do
		mergeTables(files, emitType(v, moduleName), prefix)
	end

	files[prefix .. capitalize(luaName or m.name) .. ".hx"] = table.concat(out, "\n")
	return files
end

local files = {}

for i, v in ipairs(api.modules) do
	mergeTables(files, emitModule(v))
end

mergeTables(files, emitModule(api, "love"))

resolveImports(files)

for i, v in pairs(files) do
	os.execute("mkdir -p " .. dirname(i))
	local f = io.open(i, "w")
	f:write(v)
	f:close()
end
