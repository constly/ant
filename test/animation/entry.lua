local runtime = import_package "ant.imguibase".runtime
runtime.start {
	policy = {
		"ant.animation|animation",
		"ant.animation|state_chain",
		"ant.animation|ozzmesh",
		"ant.animation|ozz_skinning",
		"ant.serialize|serialize",
		"ant.bullet|collider.capsule",
		"ant.render|render",
		"ant.render|name",
		"ant.render|light.directional",
		"ant.render|light.ambient",
	},
	system = {
		"ant.test.animation|init_loader",
	},
	pipeline = {
		{ name = "init",
			"init",
			"post_init",
		},
		{ name = "update",
			"timer",
			{name = "logic",
				"spawn_camera",
				"bind_camera",
				"motion_camera",
			},
			"data_changed",
			{name = "collider",
				"update_collider_transform",
				"update_collider",
			},
			{ name = "animation",
				"animation_state",
				"sample_animation_pose",
				"skin_mesh",
			},
			{ name = "sky",
				"update_sun",
				"update_sky",
			},
			"widget",
			{ name = "render",
				"shadow_camera",
				"load_render_properties",
				"filter_primitive",
				"make_shadow",
				"debug_shadow",
				"cull",
				"render_commit",
				{ name = "postprocess",
					"bloom",
					"tonemapping",
					"combine_postprocess",
				}
			},
			"camera_control",
			"camera_lock_target",
			"pickup",
			{ name = "ui",
				"ui_start",
				"ui_update",
				"ui_end",
			},
			"end_frame",
			"final",
		}
	}
}
