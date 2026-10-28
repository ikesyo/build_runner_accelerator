use crate::workspace::matches_glob;
use std::io;

/// Deliberately bounded URI/Glob syntax, mirrored by the launcher's early gate.
#[derive(Clone, Debug)]
pub(crate) struct BuildFilter {
    package: Option<String>,
    path: String,
}

impl BuildFilter {
    /// Parses the supported URI/path glob subset. Unsupported spellings are
    /// errors and never broaden the supported subset by guessing.
    pub(crate) fn parse(value: &str) -> io::Result<Self> {
        let unsupported = || io::Error::other(format!("Unsupported native build filter: {value}"));
        if value.is_empty()
            || !value
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_./*:-".contains(c))
        {
            return Err(unsupported());
        }
        let (package, path) = if let Some((scheme, rest)) = value.split_once(':') {
            if !matches!(scheme, "package" | "asset")
                || rest.is_empty()
                || rest.starts_with('/')
                || rest.contains(':')
                || (scheme == "asset" && !rest.contains('/'))
            {
                return Err(unsupported());
            }
            let (package, path) = rest.split_once('/').unwrap_or((rest, ""));
            (
                Some(package.to_owned()),
                if scheme == "package" {
                    if path.is_empty() {
                        "lib".to_owned()
                    } else {
                        format!("lib/{path}")
                    }
                } else {
                    path.to_owned()
                },
            )
        } else {
            (None, value.to_owned())
        };
        // URI segments are not normalized by guessing. More elaborate spelling
        // belongs to stock, along with braces/classes/escaping and non-ASCII.
        let lexical_path = value.split_once(':').map_or(value, |(_, rest)| rest);
        if lexical_path.starts_with('/')
            || lexical_path.ends_with('/')
            || lexical_path.contains("//")
            || lexical_path
                .split('/')
                .any(|s| s == "." || s == ".." || (s.contains("**") && s != "**"))
        {
            return Err(unsupported());
        }
        Ok(Self { package, path })
    }

    /// Matches a logical `package|path` output, defaulting unqualified paths
    /// to the root package. This selects roots only; it does not restrict the
    /// outputs an action may publish.
    pub(crate) fn matches(&self, asset: &str, root: &str) -> bool {
        asset.split_once('|').is_some_and(|(package, path)| {
            matches_glob(self.package.as_deref().unwrap_or(root), package)
                && matches_glob(&self.path, path)
        })
    }
}

/// Runtime filters, output policies, artifact modes and retired deletion flags
/// do not configure builders. Canonicalize parsed release/config flags while retaining defines.
pub(crate) fn configuration_arguments(
    settings: &crate::cli::BuildSettings,
) -> io::Result<Vec<String>> {
    let mut result = Vec::new();
    if settings.workspace {
        result.push("--workspace".to_owned());
    }
    if settings.release {
        result.push("--release".to_owned());
    }
    if let Some(path) = settings.config_path()? {
        result.push("--config".to_owned());
        result.push(path);
    }
    for value in &settings.defines {
        result.push("--define".to_owned());
        result.push(value.clone());
    }
    if !settings.experiments.is_empty() {
        result.push(format!(
            "--enable-experiment={}",
            settings.experiments.join(",")
        ));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn workspace_scope_changes_configuration_identity() {
        let single = crate::cli::BuildSettings::default();
        let workspace = crate::cli::BuildSettings::parse(&["--workspace".into()]).unwrap();
        assert_ne!(
            configuration_arguments(&single).unwrap(),
            configuration_arguments(&workspace).unwrap()
        );
    }
    #[test]
    fn experiments_change_configuration_identity() {
        let default = crate::cli::BuildSettings::default();
        let enabled =
            crate::cli::BuildSettings::parse(&["--enable-experiment=enhanced-parts".into()])
                .unwrap();
        assert_ne!(
            configuration_arguments(&default).unwrap(),
            configuration_arguments(&enabled).unwrap()
        );
        assert_eq!(
            configuration_arguments(&enabled).unwrap(),
            ["--enable-experiment=enhanced-parts"]
        );
    }
    #[test]
    fn stock_basic_paths_and_package_globs() {
        for (filter, matches) in [
            ("lib/*.final", true),
            ("lib/**", true),
            ("package:ap*/a.final", true),
            ("package:**/a.final", true),
            ("asset:*/lib/a.final", true),
            ("lib/none", false),
            ("package:other/a.final", false),
        ] {
            assert_eq!(
                BuildFilter::parse(filter)
                    .unwrap()
                    .matches("app|lib/a.final", "app"),
                matches,
                "{filter}"
            );
        }
        for unsupported in [
            "",
            "asset:app",
            "http:bad",
            "lib/[ab].final",
            "lib/{a,b}",
            "lib/a?.final",
            "./lib/a.final",
            "lib/**a",
            "asset:",
            "lib/a%20b",
            "/lib/a",
            "lib/a#b",
        ] {
            assert!(BuildFilter::parse(unsupported).is_err(), "{unsupported}");
        }
    }
    #[test]
    fn filter_demand_does_not_change_configuration_identity() {
        fn canonical(arguments: &[String]) -> Vec<String> {
            let settings = crate::cli::BuildSettings::parse(arguments).unwrap();
            configuration_arguments(&settings).unwrap()
        }
        let args = [
            "--define",
            "b=key=--build-filter=literal",
            "--build-filter",
            "lib/a",
            "--release",
            "--keep-modified-outputs",
            "--build-filter=lib/b",
        ];
        assert_eq!(
            canonical(&args.map(str::to_owned)),
            ["--release", "--define", "b=key=--build-filter=literal"]
        );
        assert_eq!(
            canonical(&["--force-aot".to_owned(), "-dr".to_owned()]),
            ["--release"]
        );
        assert_eq!(
            canonical(&["--config".to_owned(), "--force-aot".to_owned()]),
            ["--config", "build.--force-aot.yaml"]
        );
        assert_eq!(
            canonical(&[
                "--force-jit".to_owned(),
                "-d".to_owned(),
                "--only-check".to_owned()
            ]),
            Vec::<String>::new()
        );
    }
}
