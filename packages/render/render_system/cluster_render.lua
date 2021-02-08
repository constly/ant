local ecs = ...
local world = ecs.world

local math3d    = require "math3d"
local bgfx      = require "bgfx"
local declmgr   = require "vertexdecl_mgr"
local assetmgr  = import_package "ant.asset"
local irq       = world:interface "ant.render|irenderqueue"
local iom       = world:interface "ant.objcontroller|obj_motion"
local ilight    = world:interface "ant.render|light"

local cfs = ecs.system "cluster_forward_system"

local cluster_grid_x<const>, cluster_grid_y<const>, cluster_grid_z<const> = 16, 9, 24
local cluster_cull_light_size<const> = 6
assert(cluster_cull_light_size * 4 == cluster_grid_z)
local cluster_count<const> = cluster_grid_x * cluster_grid_y * cluster_grid_z;

local cluster_aabb_fx, cluster_light_cull_fx

-- cluster [forward] render system
--1. build cluster aabb
--2. find visble cluster. [opt]
--3. cull lights
--4. shading

local cluster_buffers = {
    AABB = {
        stage = 0,
        build_access = "w",
        cull_access = "r",
        name = "CLUSTER_BUFFER_AABB_STAGE",
        layout = declmgr.get "t30|t31",
    },
    -- index buffer of 32bit, and only 1 element
    global_index_count = {
        stage = 1,
        cull_access = "rw",
        name = "CLUSTER_BUFFER_GLOBAL_INDEX_COUNT_STAGE",
    },

    --[[
        struct light_grids {
            uint offset;
            uint count;
        };
        need 2 32bit data
    ]]
    light_grids = {
        stage = 2,
        render_stage = 10,
        cull_access = "w",
        render_access = "r",
        name = "CLUSTER_BUFFER_LIGHT_GRID_STAGE",
        layout = declmgr.get "t40Nii"   --4 int16_t as 2 uint
    },
    -- index buffer of 32bit
    light_index_list = {
        stage = 3,
        cull_access = "w",
        render_access = "r",
        render_stage = 11,
        name = "CLUSTER_BUFFER_LIGHT_GRID_STAGE",
    },
    --[[
        struct light_info{
            vec4 pos; vec4 dir; vec4 color; 
            vec4 param;
        };
    ]]
    light_info = {
        stage = 4,
        render_stage = 12,
        build_access = "r",
        cull_access = "r",
        render_access = "r",
        name = "CLUSTER_BUFFER_LIGHT_INFO_STAGE",
        layout = declmgr.get "t30|t31|t32|t33",
    }
}

local lighttypes = {
	directional = 0,
	point = 1,
	spot = 2,
}

local function create_light_buffers()
	--[[
		struct light_info{
			vec4	pos;
			vec4	dir;
			vec4	color;
			float	type;
			float	intensity;
			float	inner_cutoff;
			float	outter_cutoff;
		};
	]]

	local lights = {}
	for _, leid in world:each "light_type" do
		local le = world[leid]
		
		local p	= math3d.tovalue(iom.get_position(leid))
		local d	= math3d.tovalue(iom.get_direction(leid))
		local c = ilight.color(leid)
		local t	= le.light_type
        local enable<const> = 1
		lights[#lights+1] = ('f'):rep(16):pack(
			p[1], p[2], p[3], ilight.range(leid),
			d[1], d[2], d[3], enable,
			c[1], c[2], c[3], c[4],
			lighttypes[t], ilight.intensity(leid),
			ilight.inner_cutoff(leid),	ilight.outter_cutoff(leid))
	end
    return lights
end

local function create_cluster_buffers()
    cluster_buffers.AABB.handle                = bgfx.create_dynamic_vertex_buffer(cluster_count, cluster_buffers.AABB.layout.handle, "rwa")
    cluster_buffers.light_grids.handle         = bgfx.create_dynamic_vertex_buffer(cluster_count, cluster_buffers.light_grids.layout.handle, "rwa")
    cluster_buffers.global_index_count.handle  = bgfx.create_dynamic_index_buffer(1, "rwa")
    local lights = create_light_buffers()
    cluster_buffers.light_index_list.handle    = bgfx.create_dynamic_index_buffer(#lights, "rwa")
    cluster_buffers.light_info.handle          = bgfx.create_dynamic_vertex_buffer(#lights, cluster_buffers.light_info.layout.handle, "ra")
    local c = table.concat(lights, "")
	bgfx.update(cluster_buffers.light_info.handle, 0, bgfx.memory_buffer(c))
end

local function build_cluster_aabb_struct()
    local mq_eid = world:singleton_entity_id "main_queue"
    for _, b in pairs(cluster_buffers) do
        local build_access = b.build_access
        if build_access then
            bgfx.set_buffer(b.stage, b.handle, build_access)
        end
    end

    bgfx.dispatch(irq.viewid(mq_eid), cluster_aabb_fx.prog, cluster_grid_x, cluster_grid_y, cluster_grid_z)
end

local cr_camera_mb
local camera_frustum_mb

function cfs:init()
    
end

function cfs:post_init()
    local mq_eid = world:singleton_entity_id "main_queue"
    cr_camera_mb = world:sub{"component_changed", "camera_eid", mq_eid}
    camera_frustum_mb = world:sub{"component_changed", "frustum", world[mq_eid].camera_eid}

    create_cluster_buffers()

    cluster_aabb_fx = assetmgr.load_fx{
        cs = "/pkg/ant.resources/shaders/compute/cs_cluster_aabb.sc",
        setting = {CLUSTER_PREPROCESS = 1},
    }
    cluster_light_cull_fx = assetmgr.load_fx{
        cs = "/pkg/ant.resources/shaders/compute/cs_lightcull.sc",
        setting = {CLUSTER_PREPROCESS=1}
    }
    build_cluster_aabb_struct()
end

function cfs:data_changed()
    local mq = world:singleton_entity "main_queue"
    for _ in cr_camera_mb:unpack() do
        build_cluster_aabb_struct()
        camera_frustum_mb = world:sub{"component_changed", "frustum", mq.camera_eid}
    end

    for _ in camera_frustum_mb:unpack() do
        build_cluster_aabb_struct()
    end
end


local function cull_lights()
    local mq_eid = world:singleton_entity_id "main_queue"
    for _, b in pairs(cluster_buffers) do
        local cull_access = b.cull_access
        if cull_access then
            bgfx.set_buffer(b.stage, b.handle, cull_access)
        end
    end

    bgfx.dispatch(irq.viewid(mq_eid), cluster_light_cull_fx.prog, cluster_grid_x, cluster_grid_y, cluster_cull_light_size)
end

function cfs:render_preprocess()
    cull_lights()
end

local icr = ecs.interface "icluster_render"

function icr.set_buffers()
    for _, b in pairs(cluster_buffers) do
        local render_access = b.render_access
        if render_access then
            bgfx.set_buffer(b.render_stage, b.handle, render_access)
        end
    end
end

function icr.cluster_sizes()
    return {cluster_grid_x, cluster_grid_y, cluster_grid_z}
end