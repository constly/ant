local utility = require "model.utility"
local serialize = import_package "ant.serialize"
local lfs = require "bee.filesystem"
local fs = require "filesystem"
local material_compile = require "material.compile"

local invalid_chars<const> = {
    '<', '>', ':', '/', '\\', '|', '?', '*', ' ', '\t', '\r', '%[', '%]', '%(', '%)'
}

local pattern_fmt<const> = ("[%s]"):format(table.concat(invalid_chars, ""))
local replace_char<const> = '_'

local function fix_invalid_name(name)
    return name:gsub(pattern_fmt, replace_char)
end

local function create_entity(status, t)
    if t.parent then
        t.mount = t.parent
        t.data.scene = t.data.scene or {}
    end
    table.sort(t.policy)
    status.prefab[#status.prefab+1] = {
        policy = t.policy,
        data = t.data,
        mount = t.mount,
    }
    return #status.prefab
end

local function get_transform(math3d, node)
    if node.matrix then
        local s, r, t = math3d.srt(math3d.matrix(node.matrix))
        local rr = math3d.tovalue(r)
        rr[3], rr[4] = -rr[3], -rr[4]
        local ttx, tty, ttz = math3d.index(t, 1, 2, 3)
        return {
            s = {math3d.index(s, 1, 2, 3)},
            r = rr,
            t = {ttx, tty, -ttz},
        }
    end

    local t, r = node.translation, node.rotation
    return {
        s = node.scale,
        r = r and {r[1], r[2], -r[3], -r[4]} or nil,     --r2l
        t = t and {t[1], t[2], -t[3]} or nil,            --r2l
    }
end

local DEFAULT_STATE = "main_view|selectable|cast_shadow"

local function duplicate_table(m)
    local t = {}
    for k, v in pairs(m) do
        if type(v) == "table" then
            t[k] = duplicate_table(v)
        else
            t[k] = v
        end
    end
    return t
end

local PRIMITIVE_MODES<const> = {
    "POINTS",
    "LINES",
    false, --LINELOOP, not support
    "LINESTRIP",
    "",         --TRIANGLES
    "TRISTRIP", --TRIANGLE_STRIP
    false, --TRIANGLE_FAN not support
}

local check_update_material_info;
do
    local function build_cfg_name(basename, cfg)
        local t = {}
        if cfg.with_color_attrib then
            t[#t+1] = "c"
        end
        if cfg.with_normal_attrib then
            t[#t+1] = "n"
        end
        if not cfg.with_tangent_attrib then
            t[#t+1] = "uT"
        end
        if cfg.hasskin then
            t[#t+1] = "s"
        end
        if not cfg.pack_tangent_frame then
            t[#t+1] = "up"
        end
        if cfg.modename ~= "" then
            t[#t+1] = cfg.modename
        end
        if #t == 0 then
            return basename
        end
        return ("%s_%s"):format(basename, table.concat(t))
    end

    local function build_name(filename, cfg)
        local basename = lfs.path(filename):stem():string()
        return build_cfg_name(basename, cfg)
    end

    local function build_material(material, cfg)
        local nm = duplicate_table(material)
        local function add_setting(n, v)
            if nil == nm.fx.setting then
                nm.fx.setting = {}
            end

            nm.fx.setting[n] = v
        end

        if cfg.modename ~= "" then
            nm.state.PT = cfg.modename
        end

        if cfg.with_color_attrib then
            add_setting("WITH_COLOR_ATTRIB", 1)
        end

        if cfg.with_normal_attrib then
            add_setting("WITH_NORMAL_ATTRIB", 1)
        end

        if cfg.with_tangent_attrib then
            add_setting("WITH_TANGENT_ATTRIB", 1)
        end

        if cfg.hasskin then
            add_setting("GPU_SKINNING", 1)
        end

        if not cfg.pack_tangent_frame then
            add_setting("PACK_TANGENT_TO_QUAT", 0)
        end
        return nm
    end
    function check_update_material_info(status, filename, material, cfg)
        local name = build_name(filename, cfg)
        local c = status.material_cache[name]
        if c == nil then
            c = {
                filename = "materials/"..name..".material",
                material = build_material(material, cfg),
            }
            material_compile(status.tasks, status.depfiles, c.material, status.input, status.output / c.filename, status.setting)
            status.material_cache[name] = c
        end
        return c
    end
end

local function seri_material(status, filename, cfg)
    local material_names = status.material_names
    local stem = fs.path(filename):stem():string()

    if filename:sub(1, 1) == "/" then
        material_names[stem] = stem
        return filename
    else
        local material = assert(status.material[filename])
        local info = check_update_material_info(status, filename, material, cfg)
        material_names[stem] = fs.path(info.filename):stem():string()
        return info.filename
    end
end

local function has_skin(gltfscene, status, nodeidx)
    local node = gltfscene.nodes[nodeidx+1]
    if node.skin and next(status.animations) and status.skeleton then
        if node.skin then
            return true
        end
    end
end

local function create_mesh_node_entity(math3d, input, output, gltfscene, nodeidx, parent, status, setting)
    local node = gltfscene.nodes[nodeidx+1]
    local srt = get_transform(math3d, node)
    local meshidx = node.mesh
    local mesh = gltfscene.meshes[meshidx+1]

    local entity
    for primidx, prim in ipairs(mesh.primitives) do
        local em = status.mesh[meshidx+1][primidx]
        local hasskin = has_skin(gltfscene, status, nodeidx)
        local mode = prim.mode or 4

        local materialfile = status.material_idx[prim.material+1]
        local meshfile = em.meshbinfile
        if meshfile == nil then
            error(("not found meshfile in export data:%d, %d"):format(meshidx+1, primidx))
        end

        status.material_cfg[meshfile] = {
            hasskin                 = hasskin,                  --NOT define by default
            with_color_attrib       = em.with_color_attrib,     --NOT define by default
            pack_tangent_frame      = em.pack_tangent_frame,    --define by default, as 1
            with_normal_attrib      = em.with_normal_attrib,    --NOT define by default
            with_tangent_attrib     = em.with_tangent_attrib,   --define by default
            modename                = assert(PRIMITIVE_MODES[mode+1], "Invalid primitive mode"),
        }

        local data = {
            mesh        = meshfile,
---@diagnostic disable-next-line: need-check-nil
            material    = materialfile,
            visible_state= DEFAULT_STATE,
        }

        local policy = {}

        if hasskin then
            policy[#policy+1] = "ant.render|skinrender"
            data.skinning = true
        else
            policy[#policy+1] = "ant.render|render"
            data.scene    = {s=srt.s,r=srt.r,t=srt.t}
        end

        --TODO: need a mesh node to reference all mesh.primitives, we assume primitives only have one right now
        entity = create_entity(status, {
            policy = policy,
            data = data,
            parent = (not hasskin) and parent,
        })
    end
    return entity
end

local function create_node_entity(math3d, gltfscene, nodeidx, parent, status)
    local node = gltfscene.nodes[nodeidx+1]
    local srt = get_transform(math3d, node)
    local policy = {
        "ant.scene|scene_object"
    }
    local data = {
        scene = {s=srt.s,r=srt.r,t=srt.t}
    }
    --add_animation(gltfscene, status, nodeidx, policy, data)
    return create_entity(status, {
        policy = policy,
        data = data,
        parent = parent,
    })
end

local function create_skin_entity(status, parent)
    if not status.skeleton then
        return
    end
    local has_animation = next(status.animations) ~= nil
    local has_meshskin = #status.skin > 0
    if not has_animation and not has_meshskin then
        return
    end
    local policy = {}
    local data = {}
    if has_meshskin then
        policy[#policy+1] = "ant.scene|scene_object"
        policy[#policy+1] = "ant.animation|meshskin"
        data.meshskin = status.skin[1]
        data.skinning = true
        data.scene = {}
    end
    if has_animation then
        policy[#policy+1] = "ant.animation|animation"
        data.animation = {}
        local anilst = {}
        for name, file in pairs(status.animations) do
            local n = fix_invalid_name(name)
            anilst[#anilst+1] = n
            data.animation[n] = file
        end
        table.sort(anilst)
        data.animation_birth = anilst[1] or ""
        data.anim_ctrl = {}
    end
    data.skeleton = status.skeleton
    return create_entity(status, {
        policy = policy,
        data = data,
        parent = parent,
    })
end

local function find_mesh_nodes(gltfscene, scenenodes, meshnodes)
    for _, nodeidx in ipairs(scenenodes) do
        local node = gltfscene.nodes[nodeidx+1]
        if node.children then
            find_mesh_nodes(gltfscene, node.children, meshnodes)
        end

        if node.mesh then
            meshnodes[#meshnodes+1] = nodeidx
        end
    end
end

local function serialize_path(path)
    if path:sub(1,1) ~= "/" then
        return serialize.path(path)
    end
    return path
end

local function serialize_prefab(status, data)
    for _, v in ipairs(data) do
        local e = v.data
        if e.animation then
            for name, file in pairs(e.animation) do
                e.animation[name] = serialize_path(file)
            end
        end
        if e.material then
            e.material = seri_material(status, e.material, status.material_cfg[e.mesh])
            e.material = serialize_path(e.material)
        end
        if e.mesh then
            e.mesh = serialize_path(e.mesh)
        end
        if e.skeleton then
            e.skeleton = serialize_path(e.skeleton)
        end
        if e.meshskin then
            e.meshskin = serialize_path(e.meshskin)
        end
    end
    return data
end

return function (status)
    local input = status.input
    local output = status.output
    local glbdata = status.glbdata
    local setting = status.setting
    local math3d = status.math3d
    local gltfscene = glbdata.info
    local sceneidx = gltfscene.scene or 0
    local scene = gltfscene.scenes[sceneidx+1]

    status.prefab = {}
    status.material_names = {}
    local rootid = create_entity(status, {
        policy = {
            "ant.scene|scene_object",
        },
        data = {
            scene = {},
        },
    })

    local meshnodes = {}
    find_mesh_nodes(gltfscene, scene.nodes, meshnodes)

    create_skin_entity(status, rootid)

    local C = {}
    local scenetree = status.scenetree
    local function check_create_node_entity(nodeidx)
        local p_nodeidx = scenetree[nodeidx]
        local parent
        if p_nodeidx == nil then
            parent = rootid
        else
            parent = C[p_nodeidx]
            if parent == nil then
                parent = check_create_node_entity(p_nodeidx)
            end
        end

        local node = gltfscene.nodes[nodeidx+1]
        local e
        if node.mesh then
            e = create_mesh_node_entity(math3d, input, output, gltfscene, nodeidx, parent, status, setting)
        else
            e = create_node_entity(math3d, gltfscene, nodeidx, parent, status)
        end

        C[nodeidx] = e
        return e
    end

    for _, nodeidx in ipairs(meshnodes) do
        check_create_node_entity(nodeidx)
    end
    utility.save_txt_file(status, "mesh.prefab", status.prefab, function (data)
        return serialize_prefab(status, data)
    end)

    utility.save_txt_file(status, "translucent.prefab", status.prefab, function (data)
        for _, v in ipairs(data) do
            local e = v.data
            if e.material then
                e.material = serialize_path "/pkg/ant.resources/materials/translucent.material"
            end
        end
        return data
    end)

    utility.save_txt_file(status, "materials.names", status.material_names, function (data) return data end)
end
