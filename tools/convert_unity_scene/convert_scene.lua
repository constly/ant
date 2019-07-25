package.path = table.concat({
		"./tools/convert_unity_scene/?.lua",
		"./tools/fbx2gltf/?.lua",
		"./tools/?.lua",
		"./packages/utility/?.lua",
		"./?.lua",
		"./engine/?.lua",
		"./engine/?/?.lua",
	}, ";")

package.cpath = "projects/msvc/vs_bin/x64/Debug/?.dll"

local fs = require "filesystem.local"

local viking_projpath = fs.path "test/samples/unity_viking"
local viking_originpath = fs.path "D:/Code/github/Viking-Village"	--should be passed by argument

local scenefile = viking_projpath / "Assets/scene/viking.lua"

if not fs.exists(scenefile) then
	error(string.format("file not found:%s", scenefile:string()))
end

local util = require "convert_unity_scene.util"
local metafile_loader = require "convert_unity_scene.metafile_loader"


local world = util.loadworld(scenefile)
for _, scene in ipairs(world) do
	local fbxfilepaths = {}
	local meshfiles = scene.Meshes
	for _, fn in ipairs(meshfiles) do
		local fbxfilepath = viking_projpath / fn
		if fs.is_regular_file(fbxfilepath) then
			fbxfilepaths[#fbxfilepaths+1] = fbxfilepath
		else
			fbxfilepaths[#fbxfilepaths+1] = false
			print("fbx file not exist:", fbxfilepath:string())
		end
	end
	
	local maxdepth = 2
	local function is_root_node(node, level)
		return level <= maxdepth and node.name:match "RootNode"
	end
	local function is_geometric_node(node)
		return node.mesh and node.name:match "_Geometric$"
	end

	local function read_scale_from_meta_file(fbxfilepath)
		local metafilepath = fs.path(fbxfilepath:string() .. ".meta")
		if fs.exists(metafilepath) then
			local metacontent = metafile_loader(metafilepath)
			local mesh_setting = metacontent.ModelImporter.meshes

			local scale = mesh_setting.useFileScale == 1 and 1 or 100
			return mesh_setting.globalScale * scale
		end

		return 1
	end

	local function get_scale(glbfilepath)
		local glbfile = fs.path(glbfilepath):replace_extension("fbx"):string():lower()
		local meshfile
		for _, mf in ipairs(meshfiles) do
			if glbfile:match(mf:lower()) then
				meshfile = mf
				break
			end
		end
		
		if meshfile then
			return read_scale_from_meta_file(viking_originpath / meshfile)
		end
		return 1
	end
	
	local function reset_transform(node)
		if node.matrix then
			node.matrix = {
				1, 0, 0, 0,
				0, 1, 0, 0,
				0, 0, 1, 0,
				0, 0, 0, 1,
			}
		else
			local s, r, t = node.scale, node.rotation, node.translation
			if s then
				s[1], s[2], s[3] = 1, 1, 1
			end
			if r then
				assert(#r==4)	--queration
				r[1], r[2], r[3], r[4] = 0, 0, 0, 1
			end
			if t then
				t[1], t[2], t[3] = 0, 0, 0
			end
		end
	end
	
	local function reset_scene_transform(scene)
		local function iter_nodes(nodes, level)
			level = level or 1
			for _, nodeidx in ipairs(nodes)do
				local node = scene.nodes[nodeidx+1]
				if is_root_node(node, level) or 
					not is_geometric_node(node) then
					reset_transform(node)
				end
	
				if node.children then
					iter_nodes(node.children, level+1)
				end
			end
		end
	
		iter_nodes(scene.scenes[scene.scene+1].nodes, 1)
	end
	
	-- local function bake_transform_to_vertices(scene)
	
	-- end
	
	local fbxconvert = require "fbx2gltf.convert"
	fbxconvert(fbxfilepaths, {
		processlk = function(filepath, lkcontent)
			if lkcontent.config.mesh == nil then
				lkcontent.config.mesh = {}
			end

			lkcontent.config.mesh.scale = get_scale(filepath)
			lkcontent.config.mesh.coord_system = "right"
			lkcontent.config.mesh.negative_axis = "X"
		end,
		postconvert = function (filepath, scene)
			reset_scene_transform(scene)
		end
	})

	for idx, f in ipairs(meshfiles) do
		local p = fs.path(f):replace_extension "glb"
		if fs.is_regular_file(viking_projpath / p) then
			meshfiles[idx] = p:string()
			print("file converted:", f)
		else
			meshfiles[idx] = ""
			print("convert file failed:", f)
		end
	end
end

local stringify = require "stringify"
local newscenefile = scenefile:parent_path() / "viking_glb.lua"
local f = fs.open(newscenefile, "w")
f:write(stringify(world, true, false))
f:close()

-- local meshdesc_path = viking_projpath / "Assets/mesh_desc"
-- local cu = require "fbx2gltf.util"

-- local files = {}
-- cu.list_files(meshdesc_path, function(p) return p:extension():string():lower() == ".mesh" end, {}, files)

-- for _, f in ipairs(files)do
-- 	local t = cu.raw_table(f)
-- 	t.mesh_path = fs.path(t.mesh_path):replace_extension("glb"):string()
	
-- 	local ff = fs.open(f, "w")
-- 	ff:write(stringify(t, false, true))
-- 	ff:close()
-- end