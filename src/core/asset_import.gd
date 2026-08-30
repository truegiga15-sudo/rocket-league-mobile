# src/core/asset_import.gd — WS03 Authoritative Asset Import Validator
# Deterministic import pipeline: no runtime noise as content, LFS for large binaries,
# naming category_name_variant_author_v01.ext, power-of-two textures, triangulated meshes.
# See docs/architecture/asset-pipeline.md for full spec.
extends RefCounted
class_name AssetImport

const LFS_THRESHOLD_BYTES: int = 1_048_576
const LFS_REVIEW_THRESHOLD_BYTES: int = 52_428_800
const LFS_EXTENSIONS: Array[String] = [".glb", ".gltf", ".fbx", ".png", ".wav", ".ogg", ".mp3", ".mp4", ".webp", ".jpg", ".jpeg"]
const ASSET_NAMING_PATTERN := "^[a-z0-9]+(?:_[a-z0-9]+){2,}_v\\d{2}\\.[a-z0-9]+$"
const POWER_OF_TWO_SIZES: Array[int] = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096]
const AUTHORED_ROOT := "res://assets/authored"
const IMPORT_PRESETS := {
	"texture": {"compress/mode": 2, "compress/high_quality": false, "mipmaps/generate": true, "mipmaps/limit": -1, "detect_3d": false, "svg/scale": 1.0, "fix_alpha_border": true, "allowed_sizes": "power_of_two", "max_size": 4096},
	"mesh": {"nodes/root_type": "Node3D", "meshes/ensure_tangents": true, "meshes/generate_lods": false, "meshes/create_shadow_meshes": true, "meshes/light_baking": 1, "skins/use_named_skins": true, "animation/import": true, "require_triangulated": true, "scale": 1.0},
	"audio": {"import/mp3/quality": 0.9, "import/wav/trim": false, "import/loop": false, "bus": "SFX"},
}
static func is_power_of_two(n: int) -> bool: return n > 0 and (n & (n - 1)) == 0
static func is_valid_power_of_two_size(n: int) -> bool: return n in POWER_OF_TWO_SIZES
static func is_valid_asset_name(filename: String) -> bool:
	var re := RegEx.new(); re.compile(ASSET_NAMING_PATTERN); return re.search(filename) != null
static func parse_asset_name(filename: String) -> Dictionary:
	var result := {"valid": false, "filename": filename}
	var re := RegEx.new(); re.compile(ASSET_NAMING_PATTERN)
	if re.search(filename) == null: result["error"] = "Does not match category_name_variant_author_v01.ext"; return result
	var dot := filename.rfind("."); var stem := filename.substr(0, dot); var ext := filename.substr(dot + 1)
	var v_re := RegEx.new(); v_re.compile("^(.*)_v(\\d{2})$"); var vm := v_re.search(stem)
	if vm == null: result["error"] = "Missing _vNN suffix"; return result
	var without_version := vm.get_string(1); var version := vm.get_string(2); var parts := without_version.split("_")
	if parts.size() < 4: result["error"] = "Need at least category_name_variant_author before _vNN (got %d parts)" % parts.size(); return result
	result["valid"] = true; result["category"] = parts[0]; result["author"] = parts[parts.size() - 1]; result["variant"] = parts[parts.size() - 2]; result["name"] = "_".join(parts.slice(1, parts.size() - 2)); result["version"] = version; result["ext"] = ext; return result
static func requires_lfs(extension: String, file_size_bytes: int) -> bool: return extension.to_lower() in LFS_EXTENSIONS and file_size_bytes > LFS_THRESHOLD_BYTES
static func requires_lfs_review(file_size_bytes: int) -> bool: return file_size_bytes > LFS_REVIEW_THRESHOLD_BYTES
static func validate_texture_dimensions(width: int, height: int) -> Dictionary:
	var errors: Array[String] = []; var warnings: Array[String] = []
	if not is_power_of_two(width): errors.append("Texture width %d is not power-of-two (allowed: %s)" % [width, str(POWER_OF_TWO_SIZES)])
	if not is_power_of_two(height): errors.append("Texture height %d is not power-of-two (allowed: %s)" % [height, str(POWER_OF_TWO_SIZES)])
	if width > 4096 or height > 4096: errors.append("Texture %dx%d exceeds max 4096x4096" % [width, height])
	if width != height and (width > 2048 or height > 2048): warnings.append("Non-square texture %dx%d >2048 may waste VRAM; prefer square POT" % [width, height])
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "width": width, "height": height}
static func validate_mesh_metadata(meta: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	if meta.get("has_ngons", false): errors.append("Mesh contains ngons/quads — must be triangulated on export")
	if not meta.get("triangulated", true): errors.append("Mesh is not triangulated")
	var scale: float = meta.get("scale", 1.0)
	if not is_equal_approx(scale, 1.0): errors.append("Mesh import scale %f != 1.0 (1 unit = 1 meter, no rescaling)" % scale)
	return {"ok": errors.is_empty(), "errors": errors}
static func validate_import_preset(category: String, preset: Dictionary) -> Dictionary:
	var expected: Dictionary = IMPORT_PRESETS.get(category, {})
	if expected.is_empty(): return {"ok": false, "errors": ["Unknown preset category '%s'" % category]}
	var errors: Array[String] = []
	for key in expected:
		if key == "allowed_sizes" or key == "max_size": continue
		if not preset.has(key): errors.append("Import preset '%s' missing key '%s' (expected %s)" % [category, key, str(expected[key])])
		elif preset[key] != expected[key]: errors.append("Import preset '%s' key '%s' is %s, expected %s" % [category, key, str(preset[key]), str(expected[key])])
	return {"ok": errors.is_empty(), "errors": errors}
static func validate_file(path: String) -> Dictionary:
	var errors: Array[String] = []; var warnings: Array[String] = []; var filename := path.get_file()
	if not is_valid_asset_name(filename): errors.append("File '%s' name '%s' violates category_name_variant_author_v01.ext" % [path, filename])
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var size := int(f.get_length()); f.close()
			var ext := "." + filename.get_extension().to_lower()
			if requires_lfs(ext, size): warnings.append("File '%s' is %d bytes >1MB and should be LFS-tracked (.gitattributes)" % [filename, size])
			if requires_lfs_review(size): errors.append("File '%s' is %d bytes >50MB — requires LFS review before commit" % [filename, size])
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "path": path}
static func validate_authored_directory(dir_path: String) -> Dictionary:
	var errors: Array[String] = []; var warnings: Array[String] = []
	var da := DirAccess.open(dir_path)
	if da == null: return {"ok": false, "errors": ["Directory not found: '%s'" % dir_path], "warnings": warnings}
	da.list_dir_begin(); var fname := da.get_next()
	while fname != "":
		if fname == "." or fname == ".." or fname == ".gitkeep" or fname == "README.md": fname = da.get_next(); continue
		var full := dir_path.path_join(fname)
		if da.current_is_dir():
			var sub := validate_authored_directory(full); errors.append_array(sub["errors"]); warnings.append_array(sub["warnings"])
		else:
			var res := validate_file(full); errors.append_array(res["errors"]); warnings.append_array(res["warnings"])
		fname = da.get_next()
	da.list_dir_end(); return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings}
static func debug_export() -> Dictionary:
	return {"lfs_threshold_bytes": LFS_THRESHOLD_BYTES, "lfs_review_threshold_bytes": LFS_REVIEW_THRESHOLD_BYTES, "lfs_extensions": LFS_EXTENSIONS, "naming_pattern": ASSET_NAMING_PATTERN, "power_of_two_sizes": POWER_OF_TWO_SIZES, "import_presets": IMPORT_PRESETS}
static func perf_mark() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	for i in 1000: is_valid_asset_name("car_octane_body_a_v01.glb")
	var elapsed := Time.get_ticks_usec() - t0; return {"asset_import_validate_1000_usec": elapsed}
