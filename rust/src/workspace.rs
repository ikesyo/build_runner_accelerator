use crate::digest::digest_bytes;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Copy, Default)]
pub struct WorkspaceReadMetrics {
    pub asset_read_cache_hits: u64,
    pub asset_read_cache_misses: u64,
}

#[derive(Debug, Clone)]
pub struct Workspace {
    pub root: PathBuf,
    pub root_package: String,
    packages: BTreeMap<String, PathBuf>,
    package_config_identity: String,
    asset_index: Arc<Mutex<BTreeMap<String, Vec<String>>>>,
    find_assets_cache: Arc<Mutex<BTreeMap<(String, String), Vec<String>>>>,
    asset_read_cache: Arc<Mutex<BTreeMap<String, Arc<Vec<u8>>>>>,
    asset_read_cache_hits: Arc<AtomicU64>,
    asset_read_cache_misses: Arc<AtomicU64>,
}

#[derive(Debug, Deserialize)]
struct PackageConfigFile {
    #[serde(rename = "configVersion")]
    config_version: Option<u32>,
    packages: Vec<PackageConfigEntry>,
}

#[derive(Debug, Deserialize)]
struct PackageConfigEntry {
    name: String,
    #[serde(rename = "rootUri")]
    root_uri: String,
    #[serde(rename = "packageUri", default)]
    package_uri: String,
    #[serde(rename = "languageVersion", default)]
    language_version: String,
}

impl Workspace {
    pub fn load(root: PathBuf) -> io::Result<Self> {
        let root = fs::canonicalize(root)?;
        let root_package = package_name(&root.join("pubspec.yaml"))?;
        let package_config_path = root.join(".dart_tool/package_config.json");
        let package_config = fs::read_to_string(&package_config_path)?;
        let parsed: PackageConfigFile = serde_json::from_str(&package_config).map_err(io::Error::other)?;
        let package_config_identity = stable_package_config_identity(&parsed);
        let config_dir = package_config_path
            .parent()
            .ok_or_else(|| io::Error::other("package_config.json has no parent"))?;

        let mut packages = BTreeMap::new();
        for entry in parsed.packages {
            let package_root = resolve_uri(config_dir, &entry.root_uri);
            packages.insert(entry.name, package_root);
        }
        packages.insert(root_package.clone(), root.clone());

        Ok(Self {
            root,
            root_package,
            packages,
            package_config_identity,
            asset_index: Arc::new(Mutex::new(BTreeMap::new())),
            find_assets_cache: Arc::new(Mutex::new(BTreeMap::new())),
            asset_read_cache: Arc::new(Mutex::new(BTreeMap::new())),
            asset_read_cache_hits: Arc::new(AtomicU64::new(0)),
            asset_read_cache_misses: Arc::new(AtomicU64::new(0)),
        })
    }

    pub fn builder_manifest_fingerprint(&self) -> io::Result<String> {
        let mut bytes = b"build-runner-accelerator-manifest-v2\0".to_vec();
        bytes.extend_from_slice(self.package_config_identity.as_bytes());
        bytes.push(0);
        if let Ok(contents) = fs::read(self.root.join("pubspec.lock")) {
            bytes.extend_from_slice(&normalize_text_bytes(&contents));
            bytes.push(0xfe);
        }
        for (package, root) in &self.packages {
            bytes.extend_from_slice(package.as_bytes());
            bytes.push(0);
            let config_path = root.join("build.yaml");
            match fs::read(config_path) {
                Ok(contents) => {
                    bytes.push(1);
                    bytes.extend_from_slice(&normalize_text_bytes(&contents));
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => bytes.push(0),
                Err(error) => return Err(error),
            }
            bytes.push(0xff);
        }
        Ok(digest_bytes(&bytes))
    }

    pub(crate) fn package_config_identity(&self) -> &str {
        &self.package_config_identity
    }

    /// Convert an absolute compiler dependency path into a machine-independent
    /// identity so AOT metadata can be restored on another CI runner.
    pub(crate) fn logical_dependency_key(&self, path: &Path) -> Option<String> {
        let path = fs::canonicalize(path).ok()?;
        if let Ok(relative) = path.strip_prefix(&self.root) {
            return Some(format!(
                "workspace:{}",
                normalized_relative_path(relative)
            ));
        }

        let mut best = None;
        for (package, package_root) in &self.packages {
            let Ok(package_root) = fs::canonicalize(package_root) else {
                continue;
            };
            let Ok(relative) = path.strip_prefix(&package_root) else {
                continue;
            };
            let depth = package_root.components().count();
            let key = format!(
                "package:{package}:{}",
                normalized_relative_path(relative)
            );
            if best.as_ref().is_none_or(|(best_depth, _)| depth > *best_depth) {
                best = Some((depth, key));
            }
        }
        best.map(|(_, key)| key)
    }

    /// Resolve an identity emitted by [`logical_dependency_key`] against the
    /// current workspace and package roots.
    pub(crate) fn resolve_logical_dependency(&self, key: &str) -> Option<PathBuf> {
        if let Some(relative) = key.strip_prefix("workspace:") {
            return safe_relative_path(&self.root, relative);
        }
        let rest = key.strip_prefix("package:")?;
        let (package, relative) = rest.split_once(':')?;
        let root = self.packages.get(package)?;
        safe_relative_path(root, relative)
    }

    pub fn package_root(&self, package: &str) -> io::Result<&Path> {
        self.packages
            .get(package)
            .map(PathBuf::as_path)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("unknown package: {package}")))
    }

    pub fn package_roots(&self) -> Vec<PathBuf> {
        let mut roots = self.packages.values().cloned().collect::<Vec<_>>();
        roots.sort();
        roots.dedup();
        roots
    }

    pub fn path_for_asset(&self, asset: &str) -> io::Result<PathBuf> {
        let (package, path) = split_asset(asset)?;
        let root = self.package_root(package)?;
        validate_relative_path(path)?;
        Ok(root.join(path))
    }

    pub fn read_asset(&self, asset: &str) -> io::Result<Vec<u8>> {
        fs::read(self.path_for_asset(asset)?)
    }

    pub fn cache_path_for_asset(&self, asset: &str) -> io::Result<PathBuf> {
        let (package, path) = split_asset(asset)?;
        validate_relative_path(path)?;
        Ok(self
            .root
            .join(".dart_tool/build_runner_accelerator/cache")
            .join(package)
            .join(path))
    }

    pub fn read_asset_or_cache(&self, asset: &str) -> io::Result<Vec<u8>> {
        Ok(self.read_asset_or_cache_shared(asset)?.as_ref().clone())
    }

    /// Read an asset once per Workspace build and share the bytes across workers.
    ///
    /// The cache is deliberately scoped to this Workspace instance. A new
    /// Workspace is loaded for every build, and watch iterations therefore do
    /// not reuse bytes from a previous filesystem state.
    pub fn read_asset_or_cache_shared(&self, asset: &str) -> io::Result<Arc<Vec<u8>>> {
        if let Some(bytes) = self
            .asset_read_cache
            .lock()
            .map_err(|_| io::Error::other("asset read cache mutex is poisoned"))?
            .get(asset)
        {
            self.asset_read_cache_hits.fetch_add(1, Ordering::Relaxed);
            return Ok(Arc::clone(bytes));
        }

        self.asset_read_cache_misses.fetch_add(1, Ordering::Relaxed);
        match self.read_asset(asset) {
            Ok(bytes) => self.cache_read_bytes(asset, bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                self.cache_read_bytes(asset, fs::read(self.cache_path_for_asset(asset)?)?)
            }
            Err(error) => Err(error),
        }
    }

    pub fn read_metrics(&self) -> WorkspaceReadMetrics {
        WorkspaceReadMetrics {
            asset_read_cache_hits: self.asset_read_cache_hits.load(Ordering::Relaxed),
            asset_read_cache_misses: self.asset_read_cache_misses.load(Ordering::Relaxed),
        }
    }

    pub fn asset_exists_or_cache(&self, asset: &str) -> io::Result<bool> {
        Ok(self.path_for_asset(asset)?.is_file() || self.cache_path_for_asset(asset)?.is_file())
    }

    pub fn list_package_assets(&self, package: &str) -> io::Result<Vec<(String, PathBuf)>> {
        let root = self.package_root(package)?.to_path_buf();
        let mut files = Vec::new();
        collect_files(&root, &root, &mut files)?;
        files.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(files
            .into_iter()
            .map(|(path, absolute)| (format!("{package}|{path}"), absolute))
            .collect())
    }

    pub fn find_assets(&self, package: &str, pattern: &str) -> io::Result<Vec<String>> {
        let cache_key = (package.to_owned(), pattern.to_owned());
        if let Some(assets) = self
            .find_assets_cache
            .lock()
            .map_err(|_| io::Error::other("find assets cache mutex is poisoned"))?
            .get(&cache_key)
        {
            return Ok(assets.clone());
        }

        let assets = self.package_asset_index(package)?;
        let literal_prefix = glob_literal_prefix(pattern);
        let mut result = Vec::new();
        if literal_prefix.is_empty() {
            for asset in &assets {
                let Some((_, path)) = asset.split_once('|') else {
                    continue;
                };
                if matches_glob(pattern, path) {
                    result.push(asset.clone());
                }
            }
        } else {
            let asset_prefix = format!("{package}|{literal_prefix}");
            let start = lower_bound(&assets, &asset_prefix);
            for asset in assets[start..]
                .iter()
                .take_while(|asset| asset.starts_with(&asset_prefix))
            {
                let Some((_, path)) = asset.split_once('|') else {
                    continue;
                };
                if matches_glob(pattern, path) {
                    result.push(asset.clone());
                }
            }
        }
        result.sort();
        result.dedup();
        self.find_assets_cache
            .lock()
            .map_err(|_| io::Error::other("find assets cache mutex is poisoned"))?
            .insert(cache_key, result.clone());
        Ok(result)
    }

    /// Clear the per-build index after Rust commits new generated/cache files.
    ///
    /// Worker requests during a build only observe filesystem state from before
    /// the commit plus the explicit overlay, so reusing the index is safe until
    /// the commit boundary.
    pub fn clear_asset_caches(&self) -> io::Result<()> {
        self.asset_index
            .lock()
            .map_err(|_| io::Error::other("asset index mutex is poisoned"))?
            .clear();
        self.find_assets_cache
            .lock()
            .map_err(|_| io::Error::other("find assets cache mutex is poisoned"))?
            .clear();
        self.asset_read_cache
            .lock()
            .map_err(|_| io::Error::other("asset read cache mutex is poisoned"))?
            .clear();
        Ok(())
    }

    fn cache_read_bytes(&self, asset: &str, bytes: Vec<u8>) -> io::Result<Arc<Vec<u8>>> {
        let bytes = Arc::new(bytes);
        let mut cache = self
            .asset_read_cache
            .lock()
            .map_err(|_| io::Error::other("asset read cache mutex is poisoned"))?;
        if let Some(existing) = cache.get(asset) {
            return Ok(Arc::clone(existing));
        }
        cache.insert(asset.to_owned(), Arc::clone(&bytes));
        Ok(bytes)
    }

    fn package_asset_index(&self, package: &str) -> io::Result<Vec<String>> {
        let mut index = self
            .asset_index
            .lock()
            .map_err(|_| io::Error::other("asset index mutex is poisoned"))?;
        if let Some(assets) = index.get(package) {
            return Ok(assets.clone());
        }

        let mut assets = self
            .list_package_assets(package)?
            .into_iter()
            .map(|(asset, _)| asset)
            .chain(
                self.list_cached_package_assets(package)?
                    .into_iter()
                    .map(|(asset, _)| asset),
            )
            .collect::<Vec<_>>();
        assets.sort();
        assets.dedup();
        index.insert(package.to_owned(), assets.clone());
        Ok(assets)
    }

    fn list_cached_package_assets(&self, package: &str) -> io::Result<Vec<(String, PathBuf)>> {
        let cache_root = self
            .root
            .join(".dart_tool/build_runner_accelerator/cache")
            .join(package);
        if !cache_root.is_dir() {
            return Ok(Vec::new());
        }
        let mut files = Vec::new();
        collect_files(&cache_root, &cache_root, &mut files)?;
        Ok(files
            .into_iter()
            .map(|(path, absolute)| (format!("{package}|{path}"), absolute))
            .collect())
    }
}

fn stable_package_config_identity(config: &PackageConfigFile) -> String {
    let mut entries = config
        .packages
        .iter()
        .map(|entry| {
            format!(
                "{}\0{}\0{}\0",
                entry.name, entry.package_uri, entry.language_version
            )
        })
        .collect::<Vec<_>>();
    entries.sort();

    let mut bytes = b"package-config-v2\0".to_vec();
    if let Some(version) = config.config_version {
        bytes.extend_from_slice(version.to_string().as_bytes());
    }
    bytes.push(0);
    for entry in entries {
        bytes.extend_from_slice(entry.as_bytes());
    }
    digest_bytes(&bytes)
}

fn normalize_text_bytes(contents: &[u8]) -> Vec<u8> {
    let mut normalized = Vec::with_capacity(contents.len());
    let mut index = 0;
    while index < contents.len() {
        if contents[index] == b'\r' {
            normalized.push(b'\n');
            if contents.get(index + 1) == Some(&b'\n') {
                index += 1;
            }
        } else {
            normalized.push(contents[index]);
        }
        index += 1;
    }
    normalized
}

fn normalized_relative_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn safe_relative_path(root: &Path, relative: &str) -> Option<PathBuf> {
    let relative = Path::new(relative);
    if relative.is_absolute()
        || relative
            .components()
            .any(|component| component == std::path::Component::ParentDir)
    {
        return None;
    }
    Some(root.join(relative))
}

fn package_name(path: &Path) -> io::Result<String> {
    let contents = fs::read_to_string(path)?;
    for line in contents.lines() {
        let trimmed = line.trim();
        if let Some(value) = trimmed.strip_prefix("name:") {
            let value = value.trim().trim_matches(['\'', '"']);
            if !value.is_empty() {
                return Ok(value.to_owned());
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        format!("could not find package name in {}", path.display()),
    ))
}

fn resolve_uri(base: &Path, uri: &str) -> PathBuf {
    let decoded = percent_decode(uri);
    let path = decoded.strip_prefix("file://").unwrap_or(&decoded);
    let path = PathBuf::from(path);
    if path.is_absolute() {
        path
    } else {
        base.join(path)
    }
}

fn percent_decode(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = &value[index + 1..index + 3];
            if let Ok(decoded) = u8::from_str_radix(hex, 16) {
                result.push(decoded as char);
                index += 3;
                continue;
            }
        }
        result.push(bytes[index] as char);
        index += 1;
    }
    result
}

fn lower_bound(values: &[String], target: &str) -> usize {
    let mut low = 0;
    let mut high = values.len();
    while low < high {
        let middle = low + (high - low) / 2;
        if values[middle].as_str() < target {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    low
}

fn collect_files(root: &Path, current: &Path, result: &mut Vec<(String, PathBuf)>) -> io::Result<()> {
    for entry in fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if matches!(name.as_ref(), ".dart_tool" | ".git" | "build" | "target") {
            continue;
        }
        if path.is_dir() {
            collect_files(root, &path, result)?;
        } else if path.is_file() {
            let relative = path
                .strip_prefix(root)
                .map_err(io::Error::other)?
                .to_string_lossy()
                .replace('\\', "/");
            result.push((relative, path));
        }
    }
    Ok(())
}

fn split_asset(asset: &str) -> io::Result<(&str, &str)> {
    asset.split_once('|').ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("invalid AssetId: {asset}"))
    })
}

fn validate_relative_path(path: &str) -> io::Result<()> {
    let path = Path::new(path);
    if path.is_absolute() || path.components().any(|component| component == std::path::Component::ParentDir) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("asset path escapes package: {path:?}"),
        ));
    }
    Ok(())
}

pub fn matches_glob(pattern: &str, path: &str) -> bool {
    if !path.starts_with(glob_literal_prefix(pattern)) {
        return false;
    }
    if !pattern.split('/').any(|segment| segment == "**") {
        return matches_non_recursive_glob(pattern, path);
    }
    let pattern_segments: Vec<&str> = pattern.split('/').collect();
    let path_segments: Vec<&str> = path.split('/').collect();
    glob_segments(&pattern_segments, &path_segments)
}

pub fn glob_literal_prefix(pattern: &str) -> &str {
    let wildcard = pattern
        .find(|character| character == '*' || character == '?')
        .unwrap_or(pattern.len());
    &pattern[..wildcard]
}

fn matches_non_recursive_glob(pattern: &str, path: &str) -> bool {
    let mut pattern_segments = pattern.split('/');
    let mut path_segments = path.split('/');
    loop {
        match (pattern_segments.next(), path_segments.next()) {
            (None, None) => return true,
            (Some(pattern), Some(path)) if segment_matches(pattern, path) => {}
            _ => return false,
        }
    }
}

fn glob_segments(pattern: &[&str], path: &[&str]) -> bool {
    if pattern.is_empty() {
        return path.is_empty();
    }
    if pattern[0] == "**" {
        return glob_segments(&pattern[1..], path)
            || (!path.is_empty() && glob_segments(pattern, &path[1..]));
    }
    !path.is_empty()
        && segment_matches(pattern[0], path[0])
        && glob_segments(&pattern[1..], &path[1..])
}

fn segment_matches(pattern: &str, value: &str) -> bool {
    if !pattern
        .as_bytes()
        .iter()
        .any(|byte| matches!(byte, b'*' | b'?'))
    {
        return pattern == value;
    }

    let mut pattern_index = 0;
    let mut value_index = 0;
    let mut star_pattern_index = None;
    let mut star_value_index = 0;

    while value_index < value.len() {
        let pattern_char = pattern[pattern_index..].chars().next();
        let value_char = value[value_index..]
            .chars()
            .next()
            .expect("value_index must be a character boundary");
        let mut matched = false;

        if let Some(pattern_char) = pattern_char {
            match pattern_char {
                '*' => {
                    star_pattern_index = Some(pattern_index + pattern_char.len_utf8());
                    star_value_index = value_index;
                    pattern_index += pattern_char.len_utf8();
                    matched = true;
                }
                '?' => {
                    pattern_index += pattern_char.len_utf8();
                    value_index += value_char.len_utf8();
                    matched = true;
                }
                character if character == value_char => {
                    pattern_index += pattern_char.len_utf8();
                    value_index += value_char.len_utf8();
                    matched = true;
                }
                _ => {}
            }
        }

        if matched {
            continue;
        }

        let Some(star_pattern_index) = star_pattern_index else {
            return false;
        };
        if star_value_index >= value.len() {
            return false;
        }
        let star_char = value[star_value_index..]
            .chars()
            .next()
            .expect("star_value_index must be a character boundary");
        star_value_index += star_char.len_utf8();
        value_index = star_value_index;
        pattern_index = star_pattern_index;
    }

    while let Some(pattern_char) = pattern[pattern_index..].chars().next() {
        if pattern_char != '*' {
            return false;
        }
        pattern_index += pattern_char.len_utf8();
    }
    true
}

#[cfg(test)]
mod tests {
    use super::{glob_literal_prefix, lower_bound, matches_glob};

    #[test]
    fn glob_supports_recursive_and_single_segment_wildcards() {
        assert!(matches_glob("lib/**/*.dart", "lib/model.dart"));
        assert!(matches_glob("lib/**/*.dart", "lib/src/model.dart"));
        assert!(matches_glob("lib/*.dart", "lib/model.dart"));
        assert!(!matches_glob("lib/*.dart", "lib/src/model.dart"));
        assert!(matches_glob("lib/??.dart", "lib/ab.dart"));
        assert!(!matches_glob("lib/??.dart", "lib/a.dart"));
        assert!(matches_glob("lib/model_*.g.part", "lib/model_001.g.part"));
        assert!(matches_glob("lib/*.*.part", "lib/modèle.generated.part"));
        assert!(matches_glob("lib/*a*b*", "lib/aaabbb"));
        assert!(matches_glob("lib/*.dart", "lib/.dart"));
        assert!(!matches_glob("lib/model_*.g.part", "lib/model_001.g.dart"));
        assert!(matches_glob("lib/**/model.dart", "lib/src/deep/model.dart"));
        assert!(matches_glob("lib/**/model.dart", "lib/model.dart"));
        assert_eq!(glob_literal_prefix("lib/model_*.g.part"), "lib/model_");
        assert_eq!(glob_literal_prefix("**/*.dart"), "");

        let values = vec!["a|one".to_owned(), "b|two".to_owned(), "b|three".to_owned()];
        assert_eq!(lower_bound(&values, "a|one"), 0);
        assert_eq!(lower_bound(&values, "b|two"), 1);
        assert_eq!(lower_bound(&values, "c|none"), 3);
    }
}
