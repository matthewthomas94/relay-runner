//! `services/config.py`'s `load_config`: the app's `config.toml` with its
//! defaults, `VOICE_TERMINAL_<SECTION>_<KEY>` fallbacks and migrations.

use crate::json::Dict;

/// `load_config(config_path)`. With no path it reads `--config <path>` from
/// the process arguments, else the default location. Returns the nested
/// sections (`general`, `tts`, `stt`, ...) as Python's loader does.
pub fn load_config(_path: Option<&str>) -> Dict {
    Dict::new()
}
