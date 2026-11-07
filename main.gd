extends Node3D
## "Step Forward If You Have..." — online 3D party game for Godot 4.
##
## One player is the Question Master (QM). Everyone else stands on a 3D stage
## as a billboard Sprite3D character and secretly picks "Step Forward" or
## "Stay". When the QM taps Reveal, everyone who picked forward walks over
## the line at the same time.
##
## Networking: WebSocketMultiplayerPeer (works on desktop, mobile and web).
##   * Host mode: the host is the server AND the Question Master.
##   * Dedicated mode: run headless with `-- --server`; the first player to
##     join becomes the Question Master (passed on if they leave).

const PORT := 9080
const MAX_NAME := 16
const BASE_Z := 0.0
const FORWARD_Z := 3.2
const LINE_Z := 1.6
const WALK_SPEED := 3.5

const QUESTIONS := [
	"a pet at home",
	"ever broken a bone",
	"been on a plane",
	"a brother or sister",
	"ever sung karaoke",
	"eaten sushi",
	"seen real snow",
	"met someone famous",
	"lived in another country",
	"a nickname",
	"ever lost your phone",
	"learned a musical instrument",
	"been to a concert",
	"stayed up all night",
	"cooked a full meal by yourself",
	"ridden a horse",
	"swum in the sea",
	"won a trophy or medal",
	"ever gotten lost in a city",
	"read a whole book this year",
	"climbed a mountain",
	"more than 100 photos of food on your phone",
	"ever laughed at the wrong moment",
	"a birthday this month",
	"ever fallen asleep in a cinema",
	"tried a food you couldn't pronounce",
	"ever waved back at someone who wasn't waving at you",
	"a secret talent",
]

const SHIRT_COLORS := [
	Color("e63946"), Color("f4a261"), Color("2a9d8f"), Color("457b9d"),
	Color("9b5de5"), Color("f15bb5"), Color("00bbf9"), Color("8ac926"),
	Color("ffca3a"), Color("ff595e"), Color("6a4c93"), Color("1982c4"),
]
const SKIN_COLORS := [
	Color("ffdbac"), Color("f1c27d"), Color("e0ac69"), Color("c68642"), Color("8d5524"),
]
const HAIR_COLORS := [
	Color("2b1d14"), Color("6b3e26"), Color("d4a017"), Color("1a1a1a"),
	Color("b5523b"), Color("8a8a8a"),
]
const OUTLINE_COLOR := Color("1b1b2f")

# --- local state -------------------------------------------------------------
var dedicated := false
var in_game := false
var my_name := ""
var my_choice := -1          # -1 none, 0 stay, 1 forward
var last_round := -1
var next_look := 0
var last_q_index := -1
var anim_time := 0.0
var avatars := {}            # peer id -> Node3D

# --- shared state (authoritative on the server) -----------------------------
var players := {}            # peer id -> {"name": String, "color": int, "choice": int}
var question := ""
var phase := "waiting"       # waiting | answering | reveal
var round_num := 0
var qm_id := 0
var qm_name := ""

# --- UI nodes ----------------------------------------------------------------
var lobby_panel: PanelContainer
var name_edit: LineEdit
var addr_edit: LineEdit
var host_btn: Button
var join_btn: Button
var lobby_status: Label
var top_label: Label
var qm_panel: PanelContainer
var q_edit: LineEdit
var ask_btn: Button
var reveal_btn: Button
var next_btn: Button
var qm_status: Label
var player_panel: PanelContainer
var fwd_btn: Button
var stay_btn: Button
var player_status: Label
var wall_label: Label3D


func _ready() -> void:
	randomize()
	dedicated = "--server" in OS.get_cmdline_user_args() or OS.has_feature("dedicated_server")

	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	if dedicated:
		if _start_server():
			print("Dedicated server listening on port %d. First player to join is the Question Master." % PORT)
		return

	_build_world()
	_build_ui()
	_update_ui()


# =============================================================================
# Networking
# =============================================================================

func _start_server() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		var msg := "Could not open port %d (error %d)." % [PORT, err]
		if dedicated:
			push_error(msg)
		else:
			lobby_status.text = msg
		return false
	multiplayer.multiplayer_peer = peer
	return true


func _host() -> void:
	my_name = _clean_name(name_edit.text, "Host")
	if not _start_server():
		return
	in_game = true
	qm_id = 1
	qm_name = my_name
	phase = "waiting"
	_broadcast()


func _join() -> void:
	my_name = _clean_name(name_edit.text, "Player")
	var addr := addr_edit.text.strip_edges()
	if addr == "":
		lobby_status.text = "Enter the host's address first."
		return
	var url := addr
	if not (addr.begins_with("ws://") or addr.begins_with("wss://")):
		url = "ws://" + addr if ":" in addr else "ws://%s:%d" % [addr, PORT]
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		lobby_status.text = "Could not connect (error %d)." % err
		return
	multiplayer.multiplayer_peer = peer
	lobby_status.text = "Connecting to %s ..." % url
	host_btn.disabled = true
	join_btn.disabled = true


func _leave() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
	_reset_to_lobby.call_deferred("You left the game.")


func _on_connected_to_server() -> void:
	in_game = true
	rpc_id(1, "register_player", my_name)
	_update_ui()


func _on_connection_failed() -> void:
	_reset_to_lobby.call_deferred("Connection failed. Check the address and that the host is running.")


func _on_server_disconnected() -> void:
	_reset_to_lobby.call_deferred("The host ended the game.")


func _on_peer_disconnected(id: int) -> void:
	if not multiplayer.is_server():
		return
	players.erase(id)
	if id == qm_id:
		# Hand the Question Master role to the longest-connected player.
		var ids := players.keys()
		ids.sort()
		qm_id = ids[0] if ids.size() > 0 else 0
		phase = "waiting"
		question = ""
		_reset_choices()
		if dedicated:
			print("Question Master left. New QM: %d" % qm_id)
	_broadcast()


func _reset_to_lobby(msg: String) -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	in_game = false
	players = {}
	phase = "waiting"
	question = ""
	qm_id = 0
	my_choice = -1
	last_round = -1
	for id in avatars:
		avatars[id].queue_free()
	avatars.clear()
	host_btn.disabled = OS.has_feature("web")
	join_btn.disabled = false
	lobby_status.text = msg
	_update_ui()


# --- RPCs: client -> server -------------------------------------------------

@rpc("any_peer", "reliable")
func register_player(player_name: String) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if players.has(id):
		return
	players[id] = {"name": _clean_name(player_name, "Player"), "color": next_look, "choice": -1}
	next_look += 1
	if dedicated and qm_id == 0:
		qm_id = id
	if dedicated:
		print("%s joined (%d)" % [players[id]["name"], id])
	_broadcast()


@rpc("any_peer", "reliable")
func submit_choice(choice: int) -> void:
	if not multiplayer.is_server():
		return
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id) or id == qm_id or phase != "answering":
		return
	players[id]["choice"] = clampi(choice, 0, 1)
	_broadcast()


@rpc("any_peer", "reliable")
func request_ask(text: String) -> void:
	if not _sender_is_qm():
		return
	text = text.strip_edges().substr(0, 120)
	if text == "":
		text = _random_question()
	question = text
	phase = "answering"
	round_num += 1
	_reset_choices()
	_broadcast()


@rpc("any_peer", "reliable")
func request_reveal() -> void:
	if not _sender_is_qm() or phase != "answering":
		return
	phase = "reveal"
	_broadcast()


@rpc("any_peer", "reliable")
func request_next() -> void:
	if not _sender_is_qm():
		return
	phase = "waiting"
	question = ""
	_reset_choices()
	_broadcast()


func _sender_is_qm() -> bool:
	if not multiplayer.is_server():
		return false
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:  # called locally by the host
		sender = multiplayer.get_unique_id()
	return sender == qm_id


func _qm_call(method: String, arg = null) -> void:
	# The host calls the function directly; a remote QM sends it to the server.
	if multiplayer.is_server():
		if arg == null:
			call(method)
		else:
			call(method, arg)
	else:
		if arg == null:
			rpc_id(1, method)
		else:
			rpc_id(1, method, arg)


func _reset_choices() -> void:
	for id in players:
		players[id]["choice"] = -1


# --- RPCs: server -> clients ------------------------------------------------

func _broadcast() -> void:
	if not multiplayer.is_server():
		return
	if dedicated and players.has(qm_id):
		qm_name = players[qm_id]["name"]
	var full := _state(false)
	var masked := _state(true)
	for peer in multiplayer.get_peers():
		rpc_id(peer, "sync_state", full if peer == qm_id else masked)
	if not dedicated:
		_apply_state(full)


func _state(mask: bool) -> Dictionary:
	var p := {}
	for id in players:
		var e: Dictionary = players[id].duplicate()
		# Keep choices secret until the reveal: only show "has answered".
		if mask and phase != "reveal" and int(e["choice"]) >= 0:
			e["choice"] = 2
		p[id] = e
	return {
		"players": p,
		"question": question,
		"phase": phase,
		"round": round_num,
		"qm_id": qm_id,
		"qm_name": qm_name,
	}


@rpc("authority", "call_remote", "reliable")
func sync_state(st: Dictionary) -> void:
	_apply_state(st)


func _apply_state(st: Dictionary) -> void:
	players = st["players"]
	question = st["question"]
	phase = st["phase"]
	round_num = st["round"]
	qm_id = st["qm_id"]
	qm_name = st["qm_name"]
	if round_num != last_round:
		last_round = round_num
		my_choice = -1
	_sync_avatars()
	_update_ui()


# =============================================================================
# 3D world
# =============================================================================

func _build_world() -> void:
	# Sky + ambient light
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color("1d1340")
	sky_mat.sky_horizon_color = Color("7b4fb0")
	sky_mat.ground_horizon_color = Color("7b4fb0")
	sky_mat.ground_bottom_color = Color("120c26")
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env_node.environment = env
	add_child(env_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -25, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	# Ground, stage, the line, and a back wall that shows the question
	_add_box(Vector3(60, 0.2, 60), Vector3(0, -0.3, 0), Color("231b3d"))
	_add_box(Vector3(22, 0.3, 9), Vector3(0, -0.15, 1.8), Color("c99a5b"))
	_add_box(Vector3(22, 0.02, 3.0), Vector3(0, 0.01, FORWARD_Z + 0.3), Color("3fbf7f"), 0.0)
	_add_box(Vector3(22, 0.03, 0.2), Vector3(0, 0.02, LINE_Z), Color("ffd23f"), 1.5)
	_add_box(Vector3(24, 7, 0.4), Vector3(0, 3.2, -3.6), Color("3a2468"))
	_add_box(Vector3(24.4, 0.25, 0.5), Vector3(0, 6.7, -3.55), Color("ffd23f"), 1.0)

	var floor_text := Label3D.new()
	floor_text.text = "STEP FORWARD"
	floor_text.font_size = 110
	floor_text.pixel_size = 0.01
	floor_text.modulate = Color(1, 1, 1, 0.75)
	floor_text.rotation_degrees = Vector3(-90, 0, 0)
	floor_text.position = Vector3(0, 0.04, FORWARD_Z + 1.3)
	add_child(floor_text)

	wall_label = Label3D.new()
	wall_label.text = "STEP FORWARD\nIF YOU HAVE..."
	wall_label.font_size = 96
	wall_label.pixel_size = 0.01
	wall_label.outline_size = 16
	wall_label.outline_modulate = Color("1b1b2f")
	wall_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	wall_label.width = 2000
	wall_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wall_label.position = Vector3(0, 4.2, -3.35)
	add_child(wall_label)

	var cam := Camera3D.new()
	cam.fov = 55
	cam.position = Vector3(0, 6.5, 13.0)
	add_child(cam)
	cam.look_at(Vector3(0, 1.3, 1.0))
	cam.current = true


func _add_box(size: Vector3, pos: Vector3, color: Color, glow := -1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if glow > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = glow
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


func _stage_ids() -> Array:
	var ids := []
	for id in players:
		if id != qm_id:
			ids.append(id)
	ids.sort()
	return ids


func _sync_avatars() -> void:
	var ids := _stage_ids()
	for id in avatars.keys():
		if not ids.has(id):
			avatars[id].queue_free()
			avatars.erase(id)

	var n := ids.size()
	var spacing := minf(1.9, 19.0 / maxf(float(n), 1.0))
	for i in n:
		var id = ids[i]
		var info: Dictionary = players[id]
		if not avatars.has(id):
			avatars[id] = _make_avatar(info, id)
		var av: Node3D = avatars[id]
		var choice := int(info["choice"])
		var forward := phase == "reveal" and choice == 1
		var x := (i - (n - 1) / 2.0) * spacing
		av.set_meta("target", Vector3(x, 0, FORWARD_Z if forward else BASE_Z))

		var spr: Sprite3D = av.get_node("Sprite")
		spr.frame = 1 if forward else 0

		var status: Label3D = av.get_node("Status")
		status.text = ""
		if phase == "answering":
			status.text = "READY" if choice >= 0 else "..."
			status.modulate = Color("7cff9b") if choice >= 0 else Color("cccccc")
		elif phase == "reveal" and forward:
			status.text = "ME!"
			status.modulate = Color("ffd23f")


## Builds one player: a billboard Sprite3D (2-frame sheet: idle / cheering),
## a name tag and a status tag, plus a soft blob shadow.
func _make_avatar(info: Dictionary, id: int) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(randf_range(-6, 6), 0, -2.5)  # walk on from the back
	add_child(root)

	var shadow := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.55
	disc.bottom_radius = 0.55
	disc.height = 0.02
	shadow.mesh = disc
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0, 0, 0, 0.35)
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shadow.material_override = smat
	shadow.position.y = 0.04
	shadow.name = "Shadow"
	root.add_child(shadow)

	var spr := Sprite3D.new()
	spr.name = "Sprite"
	spr.texture = _make_character_texture(int(info["color"]))
	spr.hframes = 2
	spr.frame = 0
	spr.pixel_size = 0.05
	spr.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.shaded = false
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.position.y = 1.2
	root.add_child(spr)

	var tag := Label3D.new()
	tag.name = "Name"
	var is_me := in_game and id == multiplayer.get_unique_id()
	tag.text = ("%s (you)" % info["name"]) if is_me else String(info["name"])
	tag.modulate = Color("ffd23f") if is_me else Color.WHITE
	tag.font_size = 56
	tag.outline_size = 12
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.position.y = 2.75
	root.add_child(tag)

	var status := Label3D.new()
	status.name = "Status"
	status.font_size = 48
	status.outline_size = 12
	status.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	status.no_depth_test = true
	status.position.y = 3.2
	root.add_child(status)

	root.set_meta("target", Vector3(0, 0, BASE_Z))
	return root


func _process(delta: float) -> void:
	anim_time += delta
	for id in avatars:
		var av: Node3D = avatars[id]
		var target: Vector3 = av.get_meta("target")
		var flat := Vector3(av.position.x, 0, av.position.z)
		var moving := flat.distance_to(target) > 0.02
		flat = flat.move_toward(target, delta * WALK_SPEED)
		var hop := 0.0
		if moving:
			hop = absf(sin(anim_time * 14.0 + float(id % 7))) * 0.25
		av.position = Vector3(flat.x, hop, flat.z)
		# gentle idle sway so the stage feels alive
		var spr: Sprite3D = av.get_node("Sprite")
		spr.position.y = 1.2 + sin(anim_time * 2.5 + float(id % 11)) * 0.03


# =============================================================================
# Procedural pixel-art characters (original designs, generated at runtime)
# =============================================================================

func _make_character_texture(look: int) -> ImageTexture:
	var shirt: Color = SHIRT_COLORS[look % SHIRT_COLORS.size()]
	var skin: Color = SKIN_COLORS[(look * 7 + 3) % SKIN_COLORS.size()]
	var hair: Color = HAIR_COLORS[(look * 5 + 1) % HAIR_COLORS.size()]
	var img := Image.create(64, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_draw_character(img, 0, shirt, skin, hair, false)   # frame 0: idle
	_draw_character(img, 32, shirt, skin, hair, true)   # frame 1: cheering
	_outline(img)
	return ImageTexture.create_from_image(img)


func _rect(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, c)


func _draw_character(img: Image, ox: int, shirt: Color, skin: Color, hair: Color, cheer: bool) -> void:
	var pants := shirt.darkened(0.55)
	var shoe := Color("222222")
	# legs + shoes
	_rect(img, ox + 11, 38, ox + 14, 44, pants)
	_rect(img, ox + 17, 38, ox + 20, 44, pants)
	_rect(img, ox + 10, 45, ox + 14, 46, shoe)
	_rect(img, ox + 17, 45, ox + 21, 46, shoe)
	# arms (drawn before the head so the head overlaps them)
	if cheer:
		_rect(img, ox + 5, 12, ox + 7, 25, shirt)
		_rect(img, ox + 24, 12, ox + 26, 25, shirt)
		_rect(img, ox + 5, 9, ox + 7, 11, skin)
		_rect(img, ox + 24, 9, ox + 26, 11, skin)
	else:
		_rect(img, ox + 5, 24, ox + 7, 35, shirt)
		_rect(img, ox + 24, 24, ox + 26, 35, shirt)
		_rect(img, ox + 5, 36, ox + 7, 38, skin)
		_rect(img, ox + 24, 36, ox + 26, 38, skin)
	# body
	_rect(img, ox + 10, 22, ox + 21, 22, shirt)
	_rect(img, ox + 9, 23, ox + 22, 38, shirt)
	_rect(img, ox + 9, 30, ox + 22, 31, shirt.lightened(0.35))
	# neck
	_rect(img, ox + 14, 20, ox + 17, 22, skin)
	# head with hair
	var c := Vector2(ox + 15.5, 12.0)
	for y in range(2, 22):
		for x in range(ox + 6, ox + 26):
			var d := Vector2(x, y) - c
			if d.length() <= 8.3:
				var is_hair := y <= 7 or (y <= 11 and absf(d.x) >= 6.0)
				img.set_pixel(x, y, hair if is_hair else skin)
	# eyes
	_rect(img, ox + 12, 11, ox + 13, 13, Color.BLACK)
	_rect(img, ox + 18, 11, ox + 19, 13, Color.BLACK)
	# cheeks
	img.set_pixel(ox + 11, 15, skin.darkened(0.15))
	img.set_pixel(ox + 20, 15, skin.darkened(0.15))
	# mouth
	var mouth := Color("7a1f2b")
	if cheer:
		_rect(img, ox + 14, 15, ox + 17, 17, mouth)
	else:
		img.set_pixel(ox + 13, 16, mouth)
		_rect(img, ox + 14, 17, ox + 17, 17, mouth)
		img.set_pixel(ox + 18, 16, mouth)


func _outline(img: Image) -> void:
	var src: Image = img.duplicate()
	var w := img.get_width()
	var h := img.get_height()
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for y in h:
		for x in w:
			if src.get_pixel(x, y).a > 0.5:
				continue
			for o in dirs:
				var nx: int = x + o.x
				var ny: int = y + o.y
				if nx >= 0 and ny >= 0 and nx < w and ny < h and src.get_pixel(nx, ny).a > 0.5:
					img.set_pixel(x, y, OUTLINE_COLOR)
					break


# =============================================================================
# UI
# =============================================================================

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var theme := Theme.new()
	theme.default_font_size = 22
	root.theme = theme
	layer.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# --- top banner ---
	var top := PanelContainer.new()
	root.add_child(top)
	top_label = Label.new()
	top_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top_label.add_theme_font_size_override("font_size", 26)
	top.add_child(top_label)
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_MINSIZE, 10)

	# --- lobby ---
	lobby_panel = PanelContainer.new()
	root.add_child(lobby_panel)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 10)
	lobby_panel.add_child(lv)
	var title := Label.new()
	title.text = "Step Forward If You Have..."
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	lv.add_child(title)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Your name"
	name_edit.max_length = MAX_NAME
	name_edit.text = "Player%d" % randi_range(10, 99)
	lv.add_child(name_edit)
	addr_edit = LineEdit.new()
	addr_edit.placeholder_text = "Host IP or ws:// / wss:// address"
	addr_edit.text = "127.0.0.1"
	lv.add_child(addr_edit)
	var lh := HBoxContainer.new()
	lh.add_theme_constant_override("separation", 10)
	lv.add_child(lh)
	host_btn = _button("Host (Question Master)", _host)
	host_btn.disabled = OS.has_feature("web")  # browsers can't open servers
	lh.add_child(host_btn)
	join_btn = _button("Join", _join)
	lh.add_child(join_btn)
	lobby_status = Label.new()
	lobby_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lobby_status.custom_minimum_size = Vector2(360, 0)
	lobby_status.text = "Host a game, or join one with the host's address."
	lv.add_child(lobby_status)
	lobby_panel.custom_minimum_size = Vector2(380, 0)
	lobby_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	lobby_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	lobby_panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	# --- Question Master controls ---
	qm_panel = PanelContainer.new()
	root.add_child(qm_panel)
	var qv := VBoxContainer.new()
	qv.add_theme_constant_override("separation", 8)
	qm_panel.add_child(qv)
	var qlabel := Label.new()
	qlabel.text = "Step forward if you have..."
	qv.add_child(qlabel)
	var qh := HBoxContainer.new()
	qv.add_child(qh)
	q_edit = LineEdit.new()
	q_edit.placeholder_text = "e.g. ever seen snow"
	q_edit.max_length = 120
	q_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	q_edit.text_submitted.connect(func(_t): _on_ask())
	qh.add_child(q_edit)
	qh.add_child(_button("Random", func(): q_edit.text = _random_question()))
	var qb := HBoxContainer.new()
	qb.add_theme_constant_override("separation", 8)
	qv.add_child(qb)
	ask_btn = _button("Ask", _on_ask, true)
	reveal_btn = _button("Reveal!", func(): _qm_call("request_reveal"), true)
	next_btn = _button("Next round", func(): _qm_call("request_next"), true)
	qb.add_child(ask_btn)
	qb.add_child(reveal_btn)
	qb.add_child(next_btn)
	qb.add_child(_button("Leave", _leave))
	qm_status = Label.new()
	qm_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	qv.add_child(qm_status)
	qm_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 10)
	qm_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN

	# --- player controls ---
	player_panel = PanelContainer.new()
	root.add_child(player_panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 8)
	player_panel.add_child(pv)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 10)
	pv.add_child(ph)
	fwd_btn = _button("Step Forward", func(): _choose(1), true)
	stay_btn = _button("Stay", func(): _choose(0), true)
	fwd_btn.custom_minimum_size.y = 72
	stay_btn.custom_minimum_size.y = 72
	ph.add_child(fwd_btn)
	ph.add_child(stay_btn)
	var pb := HBoxContainer.new()
	pv.add_child(pb)
	player_status = Label.new()
	player_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	player_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pb.add_child(player_status)
	pb.add_child(_button("Leave", _leave))
	player_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 10)
	player_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _button(text: String, cb: Callable, expand := false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	if expand:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b


func _on_ask() -> void:
	var t := q_edit.text.strip_edges()
	if t == "":
		t = _random_question()
	q_edit.text = ""
	_qm_call("request_ask", t)


func _choose(choice: int) -> void:
	if phase != "answering":
		return
	my_choice = choice
	rpc_id(1, "submit_choice", choice)
	_update_ui()


func _update_ui() -> void:
	if dedicated:
		return
	lobby_panel.visible = not in_game
	var me := multiplayer.get_unique_id()
	var is_qm := in_game and me == qm_id
	qm_panel.visible = is_qm
	player_panel.visible = in_game and not is_qm

	if not in_game:
		top_label.text = "A party game: one person asks, everyone else steps forward or stays."
		wall_label.text = "STEP FORWARD\nIF YOU HAVE..."
		return

	var ids := _stage_ids()
	var answered := 0
	var fwd_names := PackedStringArray()
	var stay_names := PackedStringArray()
	var wait_names := PackedStringArray()
	for id in ids:
		var c := int(players[id]["choice"])
		var n := String(players[id]["name"])
		if c >= 0:
			answered += 1
		if c == 1:
			fwd_names.append(n)
		elif c == 0:
			stay_names.append(n)
		elif c == -1:
			wait_names.append(n)

	var full_q := "Step forward if you have %s" % question
	match phase:
		"waiting":
			wall_label.text = "STEP FORWARD\nIF YOU HAVE..."
			if ids.is_empty():
				top_label.text = "Waiting for players to join..."
			else:
				top_label.text = "%d on stage. %s is picking a question..." % [ids.size(), qm_name]
		"answering":
			wall_label.text = full_q
			top_label.text = full_q + "\n(%d/%d decided)" % [answered, ids.size()]
		"reveal":
			wall_label.text = full_q
			top_label.text = full_q + "\n%d stepped forward, %d stayed" % [fwd_names.size(), ids.size() - fwd_names.size()]

	if is_qm:
		ask_btn.disabled = phase == "answering"
		reveal_btn.disabled = phase != "answering"
		next_btn.disabled = phase != "reveal"
		var s := ""
		if multiplayer.is_server():
			var ips := _lan_ips()
			s += "You are hosting. Players join at: %s\n" % (ips if ips != "" else "this computer's IP")
		if phase == "waiting":
			s += "Type an ending (or tap Random), then Ask."
		else:
			s += "Forward: %s\nStay: %s\nDeciding: %s" % [_names(fwd_names), _names(stay_names), _names(wait_names)]
		qm_status.text = s
	else:
		var can := phase == "answering"
		fwd_btn.disabled = not can
		stay_btn.disabled = not can
		fwd_btn.text = "> STEP FORWARD <" if my_choice == 1 else "Step Forward"
		stay_btn.text = "> STAY <" if my_choice == 0 else "Stay"
		match phase:
			"waiting":
				player_status.text = "%s is the Question Master. Get ready!" % qm_name
			"answering":
				if my_choice == -1:
					player_status.text = "Be honest! Your choice stays secret until the reveal."
				else:
					player_status.text = "Locked in (you can still change it before the reveal)."
			"reveal":
				player_status.text = "Revealed! Wait for the next question."


func _names(arr: PackedStringArray) -> String:
	return "-" if arr.is_empty() else ", ".join(arr)


func _lan_ips() -> String:
	var out := PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254"):
			out.append(a)
	return ", ".join(out)


func _random_question() -> String:
	var i := randi() % QUESTIONS.size()
	if i == last_q_index:
		i = (i + 1) % QUESTIONS.size()
	last_q_index = i
	return QUESTIONS[i]


func _clean_name(raw: String, fallback: String) -> String:
	var n := raw.strip_edges().substr(0, MAX_NAME)
	return fallback if n == "" else n
