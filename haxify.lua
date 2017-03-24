-- Be warned, here be dragons

api = require "love-api.love_api"

do
	-- Map types to their modules, so we can properly do imports
	local lovetypes = {}

	for _, type in ipairs(api.types) do
		lovetypes[type.name] = "love"
	end

	for _, module in ipairs(api.modules) do
		local modulename = "love." .. module.name
		if module.types then
			for _, type in ipairs(module.types) do
				lovetypes[type.name] = modulename
			end
		end
		if module.enums then
			for _, type in ipairs(module.enums) do
				lovetypes[type.name] = modulename
			end
		end
	end

	-- types: { name -> true }
	function resolveImports(types, package)
		local imports = {}
		for i, v in pairs(types) do
			local module = lovetypes[i]
			if module and module ~= package then
				table.insert(imports, ("import %s.%s;"):format(module, i))
			end
		end
		table.sort(imports)
		return table.concat(imports, "\n")
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

function emitOverload(o, types)
	local args = {}
	for i, v in ipairs(o.arguments or {}) do
		v.type = typeMap(v.type)
		types[v.type] = true

		if v.name == "..." then
			table.insert(args, ("args:Rest<%s>"):format(v.type))
		else
			local arg = (v.default and "?" or "") .. v.name .. ":" .. v.type
			table.insert(args, arg)
		end
	end
	local retType = "Void"
	if o.returns then -- TODO: multiple returns
		retType = typeMap(o.returns[1].type)
		types[retType] = true
	end
	return ("(%s) : %s"):format(table.concat(args, ", "), retType)
end

function emitCallback(c, types)
	local type = {}
	for i, v in ipairs(c.variants[1].arguments or {}) do -- TODO: Multiple variants? Does that even exist?
		table.insert(type, typeMap(v.type))
		types[type[#type]] = true
	end

	if c.variants[1].returns then -- TODO: Multiple returns?
		table.insert(type, typeMap(c.variants[1].returns[1].type))
		types[type[#type]] = true
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

function rawEmitFunction(f, types, static)
	local out = {""}

	local sigs = {}
	for i, v in ipairs(f.variants) do
		table.insert(sigs, emitOverload(v, types))
	end

	local main = table.remove(sigs, 1)
	for i, v in ipairs(sigs) do
		table.insert(out, ("\t@:overload(function %s {})"):format(v))
	end
	table.insert(out, ("\tpublic%s function %s%s;"):format(static and " static" or "", f.name, main))
	return table.concat(out, "\n")
end

function emitFunction(f, types)
	return rawEmitFunction(f, types, true)
end

function emitMethod(m, types)
	return rawEmitFunction(m, types, false)
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
	local types = {}
	emitHeader(out, packageName)

	local superType = t.supertypes and mostSpecificSupertype(t.supertypes) or "UserData"
	table.insert(out, ("extern class %s extends %s\n{"):format(t.name, superType))

	for i, v in ipairs(t.functions or {}) do
		table.insert(out, emitMethod(v, types))
	end

	table.insert(out, "}")
	table.insert(out, 2, resolveImports(types, packageName))
	return {[t.name .. ".hx"] = table.concat(out, "\n")}
end

function emitModule(m, luaName)
	local out = {}
	local files = {}
	local types = {}

	local moduleName = luaName or "love." .. m.name
	local prefix = moduleName:gsub("%.", "/") .. "/"
	emitHeader(out, moduleName)
	table.insert(out, ("@:native(\"%s\")"):format(moduleName))
	table.insert(out, ("extern class %s"):format(capitalize(luaName or (m.name .. "Module"))))
	table.insert(out, "{")

	for i, v in ipairs(m.functions) do
		table.insert(out, emitFunction(v, types))
	end

	for i, v in ipairs(m.callbacks or {}) do
		table.insert(out, emitCallback(v, types))
	end

	table.insert(out, "}")

	for i, v in ipairs(m.enums or {}) do
		mergeTables(files, emitEnum(v, moduleName), prefix)
	end

	for i, v in ipairs(m.types or {}) do
		mergeTables(files, emitType(v, moduleName), prefix)
	end

	table.insert(out, 2, resolveImports(types, moduleName))
	files[prefix .. capitalize(luaName or (m.name .. "Module")) .. ".hx"] = table.concat(out, "\n")
	return files
end

local files = {}

for i, v in ipairs(api.modules) do
	mergeTables(files, emitModule(v))
end

mergeTables(files, emitModule(api, "love"))

for i, v in pairs(files) do
	os.execute("mkdir -p " .. dirname(i))
	local f = io.open(i, "w")
	f:write(v)
	f:close()
end
