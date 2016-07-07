local load_time_start = minetest.get_us_time()

local range = 2
local pushvel = 20
local preserve_items = false
local tnt_drop_items = false
local damage_objects = true
local tnt_seed = 15
local laser_delay = 1.9
local ignite_delay = 3.7
local mesecons_delay = 0

-- todo: use on_blasts of nodes, maybe dont delay map update because of those memory access crashes

local tnt_side = "default_tnt_side.png^tnt_shadows.png"

local function get_tnt_random(pos)
	return PseudoRandom(math.abs(pos.x+pos.y*3+pos.z*5)+tnt_seed)
end
local pr, lighter_c
local delay_c = 0--ignite_delay

local vsub = 1 / (range * range)
local vfact = pushvel / (4 - vsub)
local function get_pushvel(origin, pos, v)
	if vector.equals(origin, pos) then
		return origin
	end
	local vec = vector.subtract(pos, origin)
	local minr = 0
	for i,v in pairs(vec) do
		v = math.abs(v)
		if v > minr then
			minr = v
		end
	end

	local r = vector.length(vec)
	--local reicht = (r*1/(range+1) + minr*range/(range+1)) / 2
	local reicht = (r + minr*range) / (2 * (range+1))
	-- vsub = 1/range²
	-- vfact = pushvel / (4 - vsub)
	-- v(r) = vfact * (1/r² - vsub)

	local vel = vfact * (1 / (reicht * reicht) - vsub)

	v = vector.add(v, vector.multiply(vec, vel / r))
	vel = vector.length(v)
	if vel > 200 then
		v = vector.multiply(v, 200 / vel)
	end
	return v
end

local function drop_item(pos, nodename, player, origin)
	local drop_items = tnt_drop_items or (player and true)
	local inv
	if not drop_items then
		inv = player:get_inventory()
		if not inv then
			drop_items = true
		end
	end

	for _,item in pairs(minetest.get_node_drops(nodename)) do
		if not drop_items
		and inv:room_for_item("main", item) then
			inv:add_item("main", item)
		else
			local obj = minetest.add_item(pos, item)
			if not obj then
				minetest.log("error", "[tnt] item could not be spawned, aborting..")
				return
			end
			--obj:get_luaentity().collect = true -- @PilzAdam, what is this supposed to do?
			obj:setvelocity(get_pushvel(origin, pos, vector.zero))
		end
	end
end

local function destroy(pos, player, area, nodes, origin)
	local p_pos = area:indexp(pos)
	if nodes[p_pos] == tnt_c_air then
		return
	end
	local nodename = minetest.get_name_from_content_id(nodes[p_pos])
--		minetest.remove_node(pos)
--		nodeupdate(pos)
	local def = minetest.registered_nodes[nodename]
	if def
	and def.groups
	and def.groups.flammable then
		nodes[p_pos] = tnt_c_fire
		return
	end
	nodes[p_pos] = tnt_c_air
	if pr:next(1,3) == 3
	or not preserve_items then
		return
	end
	drop_item(pos, nodename, player, origin)
end

local particledef = {
	amount = 100,
	time = 0.1,
	minvel = {x=0, y=0, z=0},
	maxvel = {x=0, y=0, z=0},
	minacc = {x=-0.5,y=5,z=-0.5},
	maxacc = {x=0.5,y=5,z=0.5},
	minexptime = 0.1,
	maxexptime = 1,
	minsize = 8,
	maxsize = 15,
	collisiondetection = false,
	texture = "tnt_smoke.png",
}

local particledef_hot = {
	velocity = {x=0, y=0, z=0},
	acceleration = {x=0, y=0, z=0},
	expirationtime = 0.5,
	size = 16,
	collisiondetection = false,
	texture = "tnt_boom.png",
}

-- vm updates a single mapchunk
local function update_single_chunk(pos)
	local manip = minetest.get_voxel_manip()
	local emin,emax = manip:read_from_map(pos, pos)--vector.add(pos, 15))

	manip:write_to_map()
	manip:update_map()
end

-- updates mapchunk and then adds particles and plays sound
local function visualized_chunkupdate(p, pos)
	local t1 = minetest.get_us_time()

	update_single_chunk(p)

	minetest.sound_play("tnt_explode", {pos=pos, gain=1.5, max_hear_distance=range*64})

	particledef_hot.pos = pos
	minetest.add_particle(particledef_hot)

	particledef.minpos = vector.subtract(pos, 3)
	particledef.maxpos = vector.add(pos, 3)
	minetest.add_particlespawner(particledef)

	--print("[tnt] map updated at "..vector.pos_to_string(pos) .." after ca. ".. (minetest.get_us_time() - t1) / 1000000 .." s")
end

--[[
local function get_chunk(pos)
	return vector.apply(vector.divide(pos, 16), math.floor)
end--]]

local set = vector.set_data_to_pos
local get = vector.get_data_from_pos
local remove = vector.remove_data_from_pos

local chunkqueue_working = false
local chunkqueue_list
local chunkqueue = {}
local function update_chunks()
	local n
	if not chunkqueue_list
	and next(chunkqueue) then
		local _
		chunkqueue_list,_,_,n = vector.get_data_pos_table(chunkqueue)
	end
	--[[if n then
		print("[tnt] updating "..n.." chunks in time")
	end--]]
	n = next(chunkqueue_list)
	if not n then
		--print("stopping chunkupdate")
		chunkqueue_working = false
		return
	end
	minetest.delay_function(16384, update_chunks)

	local z,y,x, p = unpack(chunkqueue_list[n])
	chunkqueue_list[n] = nil
	remove(chunkqueue, z,y,x)
	z = z*16
	y = y*16
	x = x*16
	visualized_chunkupdate({x=x,y=y,z=z}, p)
end

local function extend_chunkqueue(emin, emax, p)
	for z = emin.z, emax.z, 16 do
		for y = emin.y, emax.y, 16 do
			for x = emin.x, emax.x, 16 do
				set(chunkqueue, z/16,y/16,x/16, p)
			end
		end
	end
	chunkqueue_list = nil
	if not chunkqueue_working then
		chunkqueue_working = true
		--print("start chunkupdate")
		minetest.delay_function(16384, update_chunks)
	end
end

local function bare_boom(pos, player)
	if minetest.get_node(pos).name ~= "tnt:tnt_burning" then
		return
	end

	local t1 = minetest.get_us_time()
	pr = get_tnt_random(pos)

	local manip = minetest.get_voxel_manip()
	local width = range
	local emin, emax = manip:read_from_map(vector.subtract(pos, width), vector.add(pos, width))
	local area = VoxelArea:new{MinEdge=emin, MaxEdge=emax}
	local nodes = manip:get_data()

	local p_pos = area:index(pos.x, pos.y, pos.z)
	nodes[p_pos] = tnt_c_air
	--minetest.set_node(pos, {name="tnt:boom"})

	for _,obj in pairs(minetest.get_objects_inside_radius(pos, 7)) do
		if obj:is_player()
		or (obj:get_luaentity() and obj:get_luaentity().name ~= "__builtin:item") then
			local obj_p = obj:getpos()
			obj:setvelocity(get_pushvel(pos, obj_p, obj:getvelocity() or obj:get_player_velocity() or vector.zero))
			if damage_objects then
				local vec = vector.subtract(obj_p, pos)
				local dist = vector.length(vec)
				local damage = (80*0.5^dist)*2
				obj:punch(obj, 1.0, {
					full_punch_interval=1.0,
					damage_groups={fleshy=damage},
				}, vec)
			end
		end
	end

	local near_tnts,nn = {},1
	for dx=-range,range do
		for dz=-range,range do
			for dy=range,-range,-1 do
				local p = {x=pos.x+dx, y=pos.y+dy, z=pos.z+dz}

				local p_node = area:index(p.x, p.y, p.z)
				local d_p_node = nodes[p_node]
				local nodename =  minetest.get_name_from_content_id(d_p_node)
				if d_p_node == tnt_c_tnt
				or d_p_node == tnt_c_tnt_burning then
					if d_p_node ~= tnt_c_tnt_burning then
						nodes[p_node] = tnt_c_tnt_burning
					end
					near_tnts[nn] = p
					nn = nn+1
				elseif not ( d_p_node == tnt_c_fire
				or string.find(nodename, "default:water_")
				or string.find(nodename, "default:lava_")) then
					if (
						math.abs(dx) < range
						and math.abs(dy) < range
						and math.abs(dz) < range
					) or pr:next(1,5) <= 4 then
						destroy(p, player, area, nodes, pos)
					end
				end

			end
		end
	end

	manip:set_data(nodes)
	manip:write_to_map()
	--print("[tnt] exploded after ca. ".. (minetest.get_us_time() - t1) / 1000000 .." s")

	minetest.delay_function(10000, function(near_tnts, player)
		for _,p in pairs(near_tnts) do
			bare_boom(p, player)
		end
	end, near_tnts, player)

	extend_chunkqueue(emin, emax, pos)
end

local function ignite_tnt(pos, delay, player)
	lighter_c = player
	delay_c = delay
	minetest.set_node(pos, {name="tnt:tnt_burning"})
end

local function delay_single_boom(pos, player)
	minetest.delay_function(10000, bare_boom, pos, player or {})
end

local function timer_expired(pos)
	delay_single_boom(pos, minetest.get_player_by_name(minetest.get_meta(pos):get_string("lighter")))
end

minetest.register_node(":tnt:tnt", {
	description = "TNT",
	tiles = {"default_tnt_top.png", "default_tnt_bottom.png", tnt_side},
	groups = {dig_immediate=2, mesecon=2},
	sounds = default.node_sound_wood_defaults(),

	on_punch = function(pos, node, player)
		if player:get_wielded_item():get_name() == "default:torch" then
			ignite_tnt(pos, ignite_delay, player)
		end
	end,

	mesecons = {
		effector = {
			action_on = function(pos, node)
				ignite_tnt(pos, mesecons_delay)
			end
		},
	},
	laser = {
		enable = function(pos)
			ignite_tnt(pos, laser_delay)
		end
	}
})

local function combine_texture(texture_size, frame_count, texture, ani_texture)
	local l = frame_count
	local px = 0
	local combine_textures = ":0,"..px.."="..texture
	while l ~= 0 do
		combine_textures = combine_textures..":0,"..px.."="..texture
		px = px+texture_size
		l = l-1
	end
	return ani_texture.."^[combine:"..texture_size.."x"..texture_size*frame_count..":"..combine_textures.."^"..ani_texture
end

local animated_tnt_texture = combine_texture(16, 4, "default_tnt_top.png", "tnt_top_burning_animated.png")

minetest.register_node(":tnt:tnt_burning", {
	tiles = {{name=animated_tnt_texture, animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=1}},
	"default_tnt_bottom.png", tnt_side},
	light_source = 5,
	drop = "",
	sounds = default.node_sound_wood_defaults(),
	on_timer = timer_expired,
	-- unaffected by explosions
	on_blast = function() end,
	on_construct = function(pos)
		if delay_c == 0 then
			delay_single_boom(pos, lighter_c)
			return
		end
		if lighter_c then
			minetest.get_meta(pos):set_string("lighter", lighter_c:get_player_name())
		end
		minetest.sound_play("tnt_ignite", {pos = pos})
		minetest.get_node_timer(pos):start(delay_c)
		nodeupdate(pos)
	end,
})

-- burning tnt should explode if it gets loaded when chunkloading
minetest.register_lbm({
	name = "tnt:explode_on_chunkload",
	nodenames = {"tnt:tnt_burning"},
	run_at_every_load = true,
	action = timer_expired,
})

--minetest.register_node("tnt:boom", {drop="", groups={dig_immediate=3}})

function burn(pos, player)
	local nodename = minetest.get_node(pos).name
	if nodename == "tnt:tnt" then
		ignite_tnt(pos, 1, player)
		return
	end
	if nodename ~= "tnt:gunpowder" then
		return
	end
	minetest.sound_play("tnt_gunpowder_burning", {pos=pos, gain=2})
	minetest.set_node(pos, {name="tnt:gunpowder_burning"})

	minetest.after(1, function(pos)
		if minetest.get_node(pos).name ~= "tnt:gunpowder_burning" then
			return
		end
		minetest.after(0.5, function(pos)
			if minetest.get_node(pos).name == "tnt:gunpowder_burning" then
				minetest.remove_node(pos)
			end
		end, vector.new(pos))
		for dx=-1,1 do
			for dz=-1,1 do
				for dy=-1,1 do
					if dx == 0
					or dz == 0 then
						pos.x = pos.x+dx
						pos.y = pos.y+dy
						pos.z = pos.z+dz

						if dy == 0 then
							burn(vector.new(pos), player)
						else
							if dx ~= 0
							or dz ~= 0 then
								burn(vector.new(pos), player)
							end
						end

						pos.x = pos.x-dx
						pos.y = pos.y-dy
						pos.z = pos.z-dz
					end
				end
			end
		end
	end, pos)
end

minetest.register_node(":tnt:gunpowder", {
	description = "Gun Powder",
	drawtype = "raillike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = false,
	tiles = {"tnt_gunpowder.png",},
	inventory_image = "tnt_gunpowder_inventory.png",
	wield_image = "tnt_gunpowder_inventory.png",
	selection_box = {
		type = "fixed",
		fixed = {-1/2, -1/2, -1/2, 1/2, -1/2+1/16, 1/2},
	},
	groups = {dig_immediate=2,attached_node=1},
	sounds = default.node_sound_leaves_defaults(),

	on_punch = function(pos, _, player)
		if player:get_wielded_item():get_name() == "default:torch" then
			burn(pos, puncher)
		end
	end,
})

minetest.register_node(":tnt:gunpowder_burning", {
	drawtype = "raillike",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = false,
	light_source = 5,
	tiles = {{name="tnt_gunpowder_burning_animated.png", animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=1}}},
	selection_box = {
		type = "fixed",
		fixed = {-1/2, -1/2, -1/2, 1/2, -1/2+1/16, 1/2},
	},
	drop = "",
	groups = {dig_immediate=2,attached_node=1},
	sounds = default.node_sound_leaves_defaults(),
})

tnt_c_tnt = minetest.get_content_id("tnt:tnt")
tnt_c_tnt_burning = minetest.get_content_id("tnt:tnt_burning")
tnt_c_air = minetest.get_content_id("air")
tnt_c_fire = minetest.get_content_id("fire:basic_flame")


minetest.register_abm({
	nodenames = {"tnt:tnt", "tnt:gunpowder"},
	neighbors = {"fire:basic_flame"},
	interval = 2,
	chance = 10,
	catch_up = false,
	action = function(pos, node)
		if node.name == "tnt:tnt" then
			ignite_tnt(pos, 0)
		else
			burn(pos)
		end
	end
})

minetest.register_craft({
	output = "tnt:gunpowder",
	type = "shapeless",
	recipe = {"default:coal_lump", "default:gravel"}
})

minetest.register_craft({
	output = "tnt:tnt",
	recipe = {
		{"",			"group:wood",		""			},
		{"group:wood",	"tnt:gunpowder",	"group:wood"},
		{"",			"group:wood",		""			}
	}
})

local time = (minetest.get_us_time() - load_time_start) / 1000000
local msg = "[tnt] loaded after ca. " .. time .. " seconds."
if time > 0.01 then
	print(msg)
else
	minetest.log("info", msg)
end
