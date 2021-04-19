local ecs = ...
local world = ecs.world

local bgfx = require "bgfx"

local ic = ecs.interface "icompute"

function ic.dispatch(vid, ci)
	local properties = ci.properties
	if properties then
		for n, p in pairs(properties) do
			p:set()
		end
	end

	local s = ci.dispatch_size
	bgfx.dispatch(vid, ci.fx.prog, s[1], s[2], s[3])
end


function ic.create_compute_entity(name, materialfile, size)
    return world:create_entity {
        policy = {
            "ant.render|compute_policy",
            "ant.general|name",
        },
        data = {
            name        = name or "",
            material    = materialfile,
            dispatch_size = size,
            compute     = true,
        }
    }
end

local function set_buffer(p)
    bgfx.set_buffer(p.stage, p.handle, p.access)
end

function ic.create_buffer_property(bufferdesc, which_stage)
    local stage = which_stage .. "_stage"
    local access = which_stage .. "_access"
    return {
        type    = "b",
        set     = set_buffer,
        handle  = bufferdesc.handle,
        stage   = bufferdesc[stage],
        access  = bufferdesc[access],
    }
end

local function set_image(p)
    bgfx.set_image(p.stage, p.handle, p.mip, p.access)
end

function ic.create_image_property(handle, stage, mip, access)
    return {
        type    = "i",
        set     = set_image,
        handle  = handle,
        stage   = stage,
        mip     = mip,
        access  = access
    }
end

local ct = ecs.transform "compute_transform"
function ct.process_entity(e)
    local rc = e._rendercache
    rc.dispatch_size = e.dispatch_size
end