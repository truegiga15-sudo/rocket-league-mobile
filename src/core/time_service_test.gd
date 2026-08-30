## WS05 — Time Step & Determinism self-test
extends SceneTree
const TimeSvc = preload("res://src/core/time_service.gd")
const PC = preload("res://src/core/constants.gd")
func _init() -> void:
	var result := run_checks()
	for line in result["log"]: print(line)
	if result["ok"]: print("[WS05] ALL CHECKS PASSED")
	else:
		printerr("[WS05] CHECKS FAILED")
		for e in result["errors"]: printerr("  - " + e)
	quit(0 if result["ok"] else 1)
static func run_checks() -> Dictionary:
	var log: Array[String] = []
	var errors: Array[String] = []
	log.append("[WS05] Time Step & Determinism checks")
	log.append("  -- 1) Tick constants")
	log.append("    TICK_DELTA=%.8f MIN=%.8f MAX=%.8f TPS=%d" % [TimeSvc.TICK_DELTA, TimeSvc.DELTA_MIN, TimeSvc.DELTA_MAX, TimeSvc.PHYSICS_TICKS_PER_SECOND])
	if TimeSvc.PHYSICS_TICKS_PER_SECOND != 120: errors.append("TPS !=120")
	if TimeSvc.PHYSICS_TICKS_PER_SECOND != PC.PHYSICS_TICKS_PER_SECOND: errors.append("TPS mismatch")
	if not is_equal_approx(TimeSvc.TICK_DELTA, 1.0/120.0): errors.append("TICK_DELTA !=1/120")
	if not is_equal_approx(TimeSvc.TICK_DELTA, PC.PHYSICS_TICK_DELTA): errors.append("TICK_DELTA != PC")
	if not is_equal_approx(TimeSvc.DELTA_MIN, 1.0/240.0): errors.append("DELTA_MIN !=1/240")
	if not is_equal_approx(TimeSvc.DELTA_MAX, 1.0/30.0): errors.append("DELTA_MAX !=1/30")
	if not is_equal_approx(TimeSvc.clamp_delta(0.0), TimeSvc.DELTA_MIN): errors.append("clamp 0")
	if not is_equal_approx(TimeSvc.clamp_delta(1.0), TimeSvc.DELTA_MAX): errors.append("clamp 1")
	if not is_equal_approx(TimeSvc.clamp_delta(0.016), 0.016): errors.append("clamp passthrough")
	var ps_rate: int = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", -999))
	log.append("    project.godot physics_ticks_per_second=%d" % ps_rate)
	if ps_rate != 120: errors.append("project.godot !=120 got %d" % ps_rate)
	log.append("  -- 2) Accumulator")
	var svc := TimeSvc.new(); svc.reset()
	var tot: int = 0
	for i in 3:
		var t: int = svc.advance(1.0/60.0); tot+=t
		log.append("    advance(1/60) -> %d acc=%.6f ticks=%d" % [t, svc.get_accumulator(), svc.get_tick_count()])
	if tot != 6: errors.append("3x 1/60 !=6 got %d" % tot)
	if svc.get_tick_count()!=6: errors.append("tick_count !=6")
	if not is_equal_approx(svc.get_total_time(), 6.0/120.0): errors.append("total_time")
	if absf(svc.get_accumulator())>0.0001: errors.append("acc not 0")
	if svc.get_alpha() <0.0 or svc.get_alpha() >=1.0: errors.append("alpha range")
	svc.reset()
	if svc.advance(0.0001)!=0: errors.append("small delta should be 0")
	if svc.advance(TimeSvc.DELTA_MIN)!=1: errors.append("second MIN should be 1")
	svc.reset()
	if svc.advance(0.5)!=4: errors.append("0.5 should be 4")
	if svc.advance(1.0)!=4: errors.append("1.0 second should be 4")
	svc.reset()
	if svc.advance(-0.1)!=0: errors.append("-0.1 should clamp to 0 ticks")
	svc.reset(); svc.advance(0.016)
	var bt:=svc.get_tick_count(); var ba:=svc.get_accumulator()
	var dry:=svc.ticks_for_delta(0.016)
	if svc.get_tick_count()!=bt: errors.append("dry mutated ticks")
	if not is_equal_approx(svc.get_accumulator(), ba): errors.append("dry mutated acc")
	svc.reset()
	if svc.get_tick_count()!=0 or not is_equal_approx(svc.get_accumulator(),0.0): errors.append("reset")
	svc.free()
	log.append("  -- 3) Input quantization")
	if TimeSvc.quantize_axis(1.0)!=127: errors.append("q 1.0")
	if TimeSvc.quantize_axis(-1.0)!=-127: errors.append("q -1")
	if TimeSvc.quantize_axis(0.0)!=0: errors.append("q 0")
	if TimeSvc.quantize_axis(2.0)!=127: errors.append("q clamp high")
	for v in [-1.0, -0.5, 0.0, 0.33, 0.5, 1.0]:
		var q:=TimeSvc.quantize_axis(v); var v2:=TimeSvc.dequantize_axis(q)
		if absf(v-v2) > 0.5/127.0 + 0.0001: errors.append("roundtrip %f" % v)
	var qv:=TimeSvc.quantize_vector2(Vector2(0.7,-0.4))
	if qv != Vector2i(89,-51): errors.append("qvec %s" % str(qv))
	var qi:=TimeSvc.quantize_input(Vector2(1,0), Vector2(0.5,-0.5), true,false,true,false)
	if qi["move_x"]!=127 or qi["boost"]!=1 or qi["drift"]!=1: errors.append("qi %s" % str(qi))
	var dqi:=TimeSvc.dequantize_input(qi)
	if not (dqi["move"] as Vector2).is_equal_approx(Vector2(1,0)): errors.append("dqi")
	log.append("  -- 4) Replay determinism")
	var a:=TimeSvc.new(); var b:=TimeSvc.new(); a.reset(); b.reset()
	var deltas: Array[float] = [0.016,0.016,0.016,0.008,0.033,0.004,0.016]
	var ta: Array[int] = []; var tb: Array[int] = []
	for d in deltas: ta.append(a.advance(d))
	for d in deltas: tb.append(b.advance(d))
	if str(ta)!=str(tb): errors.append("determinism ticks")
	if a.get_tick_count()!=b.get_tick_count(): errors.append("determinism count")
	if not is_equal_approx(a.get_total_time(), b.get_total_time()): errors.append("determinism time")
	a.free(); b.free()
	log.append("  -- 5) debug_export & validate")
	var s2:=TimeSvc.new(); s2.reset(); s2.advance(0.016)
	var dbg:=s2.debug_export(); log.append("    dbg %s" % str(dbg))
	for k in ["physics_ticks_per_second","tick_delta","delta_min","delta_max","accumulator","tick_count","total_time","is_fixed_timestep","alpha","input_quant_steps"]:
		if not dbg.has(k): errors.append("dbg missing "+k)
	if dbg.get("physics_ticks_per_second",-1)!=120: errors.append("dbg tps")
	if dbg.get("is_fixed_timestep",false)!=true: errors.append("dbg fixed")
	var perf:=s2.perf_mark()
	if not perf.has("tick_count") or not perf.has("accumulator_ms"): errors.append("perf missing")
	var val:=s2.validate_config()
	if not val["ok"]:
		for e in val["errors"]: errors.append("validate "+str(e))
	s2.free()
	log.append("  -- 6) Replay log format")
	var replay: Dictionary = {"version":1,"meta":{"ticks_per_second":120,"tick_delta":1.0/120.0,"quant_steps":127,"created_at":int(Time.get_unix_time_from_system()),"match_id":"ws05_test_001","map":"dfh_stadium"},"ticks":[]}
	var s3:=TimeSvc.new(); s3.reset()
	for i in 5:
		var q:=TimeSvc.quantize_input(Vector2(0.5,0), Vector2.ZERO, i%2==0, false,false,true)
		s3.advance(TimeSvc.TICK_DELTA)
		var entry: Dictionary = {"tick": s3.get_tick_count()-1, "t": float(s3.get_tick_count()-1)*TimeSvc.TICK_DELTA}
		for k in q.keys(): entry[k]=q[k]
		(replay["ticks"] as Array).append(entry)
	if (replay["ticks"] as Array).size()!=5: errors.append("replay size")
	for entry in replay["ticks"] as Array:
		var e: Dictionary = entry as Dictionary
		if int(e["move_x"]) < -127 or int(e["move_x"]) >127: errors.append("range")
		var exp:=float(int(e["tick"]))*1.0/120.0
		if not is_equal_approx(float(e["t"]), exp): errors.append("t mismatch")
	s3.free()
	return {"ok": errors.is_empty(), "errors": errors, "log": log}
