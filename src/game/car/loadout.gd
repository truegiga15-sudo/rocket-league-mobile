## WS55 -- Car Selection Loadout Persistence (budget-aware <12 calls, deterministic)
## Persists equipped car/paint/decal via SaveService WS08. Uses Garage WS52 catalog
## and constants WS04. Deterministic, no random, no procedural, no per-frame allocation.
## Budget: <12 calls per load/save (FileAccess 1, JSON 1, checksum 1, SaveService 2).
## Depends on: src/core/constants.gd (WS04), src/core/save_service.gd (WS08),
##             src/ui/garage.gd (WS52), src/game/car/car_shader.gd (WS48),
##             src/game/car/decals.gd (WS50)
extends RefCounted
class_name CarLoadout

const PC = preload("res://src/core/constants.gd")
const GarageRef = preload("res://src/ui/garage.gd")
const CarShaderRef = preload("res://src/game/car/car_shader.gd")
const CarDecalsRef = preload("res://src/game/car/decals.gd")

# ---------------------------------------------------------------------------
# Catalog -- mirrors Garage WS52 / CarShader WS48 / CarDecals WS50 (single source)
# ---------------------------------------------------------------------------

const CAR_OCTANE: String = "octane"
const CAR_DOMINUS: String = "dominus"
const CAR_KEYS: Array[String] = [CAR_OCTANE, CAR_DOMINUS]
const CAR_COUNT: int = 2
const DEFAULT_CAR: String = CAR_OCTANE

const PAINT_GLOSS: String = "gloss"
const PAINT_MATTE: String = "matte"
const PAINT_METALLIC: String = "metallic"
const PAINT_PEARL: String = "pearl"
const PAINT_KEYS: Array[String] = [PAINT_GLOSS, PAINT_MATTE, PAINT_METALLIC, PAINT_PEARL]
const PAINT_COUNT: int = 4
const DEFAULT_PAINT: String = PAINT_GLOSS

const DECAL_NONE: String = "none"
const DECAL_STRIPES: String = "stripes"
const DECAL_FLAMES: String = "flames"
const DECAL_LIGHTNING: String = "lightning"
const DECAL_WINGS: String = "wings"
const DECAL_KEYS: Array[String] = [DECAL_NONE, DECAL_STRIPES, DECAL_FLAMES, DECAL_LIGHTNING, DECAL_WINGS]
const DECAL_COUNT: int = 5
const DEFAULT_DECAL: String = DECAL_NONE

# SaveService garage keys -- extends WS08 default which has equipped_car/decal/wheels
# WS55 adds equipped_paint + equipped_team for full loadout
const SAVE_KEY_CAR: String = "equipped_car"
const SAVE_KEY_PAINT: String = "equipped_paint"
const SAVE_KEY_DECAL: String = "equipped_decal"
const SAVE_KEY_TEAM: String = "equipped_team"
const SAVE_KEY_WHEELS: String = "equipped_wheels"

# Budget
const MAX_CALLS_PER_OP: int = 12
const BUDGET_CALLS: int = 12
const TICK_HZ: int = 120
const TICK_DELTA: float = 1.0 / 120.0

# ---------------------------------------------------------------------------
# Signals -- deterministic
# ---------------------------------------------------------------------------
signal loadout_loaded(selection: Dictionary)
signal loadout_saved(selection: Dictionary)
signal loadout_error(reason: String)

# ---------------------------------------------------------------------------
# State -- current in-memory loadout (mirrors SaveService garage)
# ---------------------------------------------------------------------------
var _car: String = DEFAULT_CAR
var _paint: String = DEFAULT_PAINT
var _decal: String = DEFAULT_DECAL
var _team: int = CarShaderRef.TEAM_BLUE
var _loaded: bool = false
var _last_save_ok: bool = false

# ---------------------------------------------------------------------------
# Validation helpers -- pure, 0 API calls
# ---------------------------------------------------------------------------
static func is_valid_car(car: String) -> bool:
	return CAR_KEYS.has(car)

static func is_valid_paint(paint: String) -> bool:
	return PAINT_KEYS.has(paint)

static func is_valid_decal(decal: String) -> bool:
	return DECAL_KEYS.has(decal)

static func is_valid_team(team: int) -> bool:
	return team == CarShaderRef.TEAM_BLUE or team == CarShaderRef.TEAM_ORANGE

static func sanitize_selection(car: String, paint: String, decal: String, team: int = CarShaderRef.TEAM_BLUE) -> Dictionary:
	var c: String = car if CAR_KEYS.has(car) else DEFAULT_CAR
	var p: String = paint if PAINT_KEYS.has(paint) else DEFAULT_PAINT
	var d: String = decal if DECAL_KEYS.has(decal) else DEFAULT_DECAL
	var t: int = team if is_valid_team(team) else CarShaderRef.TEAM_BLUE
	return {"car": c, "paint": p, "decal": d, "team": t}

static func default_selection() -> Dictionary:
	return {"car": DEFAULT_CAR, "paint": DEFAULT_PAINT, "decal": DEFAULT_DECAL, "team": CarShaderRef.TEAM_BLUE}

# ---------------------------------------------------------------------------
# SaveService resolution -- budget: 1-2 get_node calls
# ---------------------------------------------------------------------------
func _get_save_service() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var root: Window = tree.root
		if root != null:
			var svc := root.get_node_or_null("SaveService")
			if svc != null:
				return svc
		var alt := tree.get_root().get_node_or_null("/root/SaveService")
		if alt != null:
			return alt
	if Engine.has_singleton("SaveService"):
		return Engine.get_singleton("SaveService")
	return null

static func _get_save_service_static() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		var root: Window = tree.root
		if root != null:
			var svc := root.get_node_or_null("SaveService")
			if svc != null:
				return svc
		var alt := tree.get_root().get_node_or_null("/root/SaveService")
		if alt != null:
			return alt
	return null

# ---------------------------------------------------------------------------
# Garage helpers -- reuse WS52 defaults when SaveService missing
# ---------------------------------------------------------------------------
func _default_garage_section() -> Dictionary:
	return {
		"equipped_car": DEFAULT_CAR,
		"equipped_paint": DEFAULT_PAINT,
		"equipped_decal": DEFAULT_DECAL,
		"equipped_team": CarShaderRef.TEAM_BLUE,
		"equipped_wheels": "default",
		"owned_cars": [CAR_OCTANE],
		"owned_decals": [DECAL_NONE],
		"owned_wheels": ["default"],
	}

func _payload_to_selection(payload: Dictionary) -> Dictionary:
	if payload.is_empty() or not payload.has("garage"):
		return default_selection()
	var g: Dictionary = payload["garage"] as Dictionary
	var car: String = str(g.get(SAVE_KEY_CAR, DEFAULT_CAR))
	var paint: String = str(g.get(SAVE_KEY_PAINT, DEFAULT_PAINT))
	var decal: String = str(g.get(SAVE_KEY_DECAL, DEFAULT_DECAL))
	var team: int = int(g.get(SAVE_KEY_TEAM, CarShaderRef.TEAM_BLUE))
	return sanitize_selection(car, paint, decal, team)

func _selection_to_garage_payload(payload: Dictionary, selection: Dictionary) -> Dictionary:
	if not payload.has("garage"):
		payload["garage"] = _default_garage_section()
	var g: Dictionary = payload["garage"] as Dictionary
	g[SAVE_KEY_CAR] = selection.get("car", DEFAULT_CAR)
	g[SAVE_KEY_PAINT] = selection.get("paint", DEFAULT_PAINT)
	g[SAVE_KEY_DECAL] = selection.get("decal", DEFAULT_DECAL)
	g[SAVE_KEY_TEAM] = selection.get("team", CarShaderRef.TEAM_BLUE)
	# Ensure owned arrays contain equipped (no duplicates) -- budget: array has/append
	if not (g.get("owned_cars", []) as Array).has(g[SAVE_KEY_CAR]):
		(g["owned_cars"] as Array).append(g[SAVE_KEY_CAR])
	if not (g.get("owned_decals", []) as Array).has(g[SAVE_KEY_DECAL]):
		(g["owned_decals"] as Array).append(g[SAVE_KEY_DECAL])
	return payload

# ---------------------------------------------------------------------------
# Public API -- load / save / equip (budget <12 calls per op)
# ---------------------------------------------------------------------------
func get_selection() -> Dictionary:
	return {"car": _car, "paint": _paint, "decal": _decal, "team": _team}

func get_car() -> String:
	return _car

func get_paint() -> String:
	return _paint

func get_decal() -> String:
	return _decal

func get_team() -> int:
	return _team

## Load loadout from SaveService. Returns sanitized selection. Budget: <12 calls.
## Calls: SaveService.load_save (1) + payload parse (0) + sanitize (0) = 1-2.
func load_loadout() -> Dictionary:
	var svc := _get_save_service()
	var payload: Dictionary = {}
	var calls: int = 0
	if svc != null and svc.has_method("load_save"):
		payload = svc.load_save() as Dictionary
		calls += 1
	else:
		payload = {"garage": _default_garage_section()}
	var sel := _payload_to_selection(payload)
	_car = sel["car"] as String
	_paint = sel["paint"] as String
	_decal = sel["decal"] as String
	_team = sel["team"] as int
	_loaded = true
	loadout_loaded.emit(get_selection())
	return get_selection()

## Save current or provided loadout to SaveService. Returns true on success. Budget: <12 calls.
## Calls: load_save (1) + save_game (1) = 2.
func save_loadout(car: String = "", paint: String = "", decal: String = "", team: int = -999) -> bool:
	var sel := get_selection()
	if car != "":
		sel["car"] = car
	if paint != "":
		sel["paint"] = paint
	if decal != "":
		sel["decal"] = decal
	if team != -999:
		sel["team"] = team
	sel = sanitize_selection(sel["car"] as String, sel["paint"] as String, sel["decal"] as String, sel["team"] as int)
	# Update in-memory
	_car = sel["car"] as String
	_paint = sel["paint"] as String
	_decal = sel["decal"] as String
	_team = sel["team"] as int
	var svc := _get_save_service()
	if svc == null or not svc.has_method("load_save") or not svc.has_method("save_game"):
		push_warning("[CarLoadout] SaveService unavailable -- in-memory only")
		loadout_error.emit("no_save_service")
		return false
	var payload: Dictionary = svc.load_save() as Dictionary
	if payload.is_empty():
		payload = {"garage": _default_garage_section()}
	payload = _selection_to_garage_payload(payload, sel)
	var ok: bool = svc.save_game(payload) as bool
	_last_save_ok = ok
	if ok:
		loadout_saved.emit(sel)
	else:
		loadout_error.emit("save_failed")
		push_warning("[CarLoadout] save_game failed")
	return ok

## Equip new car/paint/decal (and optional team) and persist. Returns result dict.
## Budget: delegates to save_loadout (2 calls) + sanitize (0).
func equip(car: String, paint: String, decal: String, team: int = -999) -> Dictionary:
	var sanitized := sanitize_selection(car, paint, decal, team if team != -999 else _team)
	var ok := save_loadout(sanitized["car"] as String, sanitized["paint"] as String, sanitized["decal"] as String, sanitized["team"] as int)
	return {"ok": ok, "selection": get_selection(), "sanitized": sanitized}

func equip_car(car: String) -> bool:
	if not is_valid_car(car):
		return false
	return save_loadout(car, "", "", -999)

func equip_paint(paint: String) -> bool:
	if not is_valid_paint(paint):
		return false
	return save_loadout("", paint, "", -999)

func equip_decal(decal: String) -> bool:
	if not is_valid_decal(decal):
		return false
	return save_loadout("", "", decal, -999)

func configure(car: String, paint: String, decal: String, team: int = -999) -> Dictionary:
	var car_ok := is_valid_car(car)
	var paint_ok := is_valid_paint(paint)
	var decal_ok := is_valid_decal(decal)
	var sanitized := sanitize_selection(car, paint, decal, team if team != -999 else _team)
	# Use sanitized values only if original was valid; otherwise keep current
	var target_car: String = sanitized["car"] as String if car_ok else _car
	var target_paint: String = sanitized["paint"] as String if paint_ok else _paint
	var target_decal: String = sanitized["decal"] as String if decal_ok else _decal
	var target_team: int = sanitized["team"] as int if team != -999 and is_valid_team(team) else _team
	var ok := save_loadout(target_car, target_paint, target_decal, target_team)
	return {"car_ok": car_ok, "paint_ok": paint_ok, "decal_ok": decal_ok, "ok": ok, "selection": get_selection()}

## Apply current loadout to a Garage instance (syncs Garage selection without extra save)
## Budget: 1 call (Garage.configure)
func apply_to_garage(garage: GarageRef) -> bool:
	if garage == null or not is_instance_valid(garage):
		return false
	if garage.has_method("configure"):
		garage.configure(_car, _paint, _decal, _team)
		return true
	return false

## Sync from Garage instance into loadout (pulls Garage selection)
func sync_from_garage(garage: GarageRef) -> Dictionary:
	if garage == null or not is_instance_valid(garage):
		return get_selection()
	var sel: Dictionary = {}
	if garage.has_method("get_selection"):
		sel = garage.get_selection() as Dictionary
	else:
		sel = {"car": garage.get(" _car"), "paint": garage.get("_paint"), "decal": garage.get("_decal"), "team": garage.get("_team")}
	var car: String = str(sel.get("car", _car))
	var paint: String = str(sel.get("paint", _paint))
	var decal: String = str(sel.get("decal", _decal))
	var team: int = int(sel.get("team", _team))
	var sanitized := sanitize_selection(car, paint, decal, team)
	_car = sanitized["car"] as String
	_paint = sanitized["paint"] as String
	_decal = sanitized["decal"] as String
	_team = sanitized["team"] as int
	return get_selection()

# ---------------------------------------------------------------------------
# Validation -- deterministic, no I/O
# ---------------------------------------------------------------------------
static func debug_validate_static() -> Dictionary:
	var errors: Array[String] = []
	if CAR_COUNT != CAR_KEYS.size():
		errors.append("CAR_COUNT %d != CAR_KEYS.size() %d" % [CAR_COUNT, CAR_KEYS.size()])
	if PAINT_COUNT != PAINT_KEYS.size():
		errors.append("PAINT_COUNT %d != PAINT_KEYS.size() %d" % [PAINT_COUNT, PAINT_KEYS.size()])
	if DECAL_COUNT != DECAL_KEYS.size():
		errors.append("DECAL_COUNT %d != DECAL_KEYS.size() %d" % [DECAL_COUNT, DECAL_KEYS.size()])
	if not CAR_KEYS.has(DEFAULT_CAR):
		errors.append("DEFAULT_CAR %s not in CAR_KEYS %s" % [DEFAULT_CAR, str(CAR_KEYS)])
	if not PAINT_KEYS.has(DEFAULT_PAINT):
		errors.append("DEFAULT_PAINT %s not in PAINT_KEYS" % DEFAULT_PAINT)
	if not DECAL_KEYS.has(DEFAULT_DECAL):
		errors.append("DEFAULT_DECAL %s not in DECAL_KEYS" % DEFAULT_DECAL)
	# Cross-check with Garage WS52
	if GarageRef.CAR_KEYS != CAR_KEYS:
		errors.append("CAR_KEYS mismatch with Garage.CAR_KEYS")
	if GarageRef.DEFAULT_CAR != DEFAULT_CAR:
		errors.append("DEFAULT_CAR mismatch with Garage.DEFAULT_CAR")
	if GarageRef.PAINT_KEYS != PAINT_KEYS and CarShaderRef.PAINT_KEYS != PAINT_KEYS:
		# Garage may mirror CarShader; check at least one matches
		errors.append("PAINT_KEYS mismatch with Garage/CarShader")
	if CarShaderRef.PAINT_KEYS != PAINT_KEYS:
		errors.append("PAINT_KEYS mismatch with CarShader.PAINT_KEYS %s" % str(CarShaderRef.PAINT_KEYS))
	if CarDecalsRef.DECAL_KEYS != DECAL_KEYS:
		errors.append("DECAL_KEYS mismatch with CarDecals.DECAL_KEYS")
	# Team constants
	if CarShaderRef.TEAM_BLUE != 0 or CarShaderRef.TEAM_ORANGE != 1:
		errors.append("Team constants unexpected")
	# Budget
	if MAX_CALLS_PER_OP != 12 and BUDGET_CALLS != 12:
		errors.append("BUDGET_CALLS must be 12")
	if MAX_CALLS_PER_OP > 12:
		errors.append("MAX_CALLS_PER_OP %d > 12" % MAX_CALLS_PER_OP)
	# Constants coupling -- PC physics tick must be 120
	if PC.PHYSICS_TICKS_PER_SECOND != 120:
		errors.append("PHYSICS_TICKS %d != 120" % PC.PHYSICS_TICKS_PER_SECOND)
	return {"ok": errors.is_empty(), "errors": errors}

func debug_validate() -> Dictionary:
	var base := debug_validate_static()
	var errors: Array[String] = []
	for e in base["errors"]:
		errors.append(e)
	if not is_valid_car(_car):
		errors.append("live _car %s invalid" % _car)
	if not is_valid_paint(_paint):
		errors.append("live _paint %s invalid" % _paint)
	if not is_valid_decal(_decal):
		errors.append("live _decal %s invalid" % _decal)
	if not is_valid_team(_team):
		errors.append("live _team %d invalid" % _team)
	return {"ok": errors.is_empty(), "errors": errors}

# ---------------------------------------------------------------------------
# Telemetry / perf -- conventions §11
# ---------------------------------------------------------------------------
static func debug_export_static() -> Dictionary:
	return {
		"car_keys": CAR_KEYS,
		"paint_keys": PAINT_KEYS,
		"decal_keys": DECAL_KEYS,
		"default_car": DEFAULT_CAR,
		"default_paint": DEFAULT_PAINT,
		"default_decal": DEFAULT_DECAL,
		"budget_calls": BUDGET_CALLS,
		"tick_hz": TICK_HZ,
	}

func debug_export() -> Dictionary:
	var d := debug_export_static()
	d["selection"] = get_selection()
	d["loaded"] = _loaded
	d["last_save_ok"] = _last_save_ok
	return d

static func perf_mark_static() -> Dictionary:
	return {"scope": "CarLoadout", "budget_calls": BUDGET_CALLS, "tick_hz": TICK_HZ}

func perf_mark() -> Dictionary:
	return {"scope": "CarLoadout", "selection": get_selection(), "budget_calls": BUDGET_CALLS, "loaded": _loaded}

