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
    /// errors so the caller can preserve stock `build_runner` diagnostics.
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

/// Runtime filters, artifact modes and retired deletion flags do not configure
/// builders. Canonicalize parsed release/config flags while retaining defines.
pub(crate) fn configuration_arguments(arguments: &[String]) -> io::Result<Vec<String>> {
    let settings = crate::cli::BuildSettings::parse(arguments)?;
    let mut result = Vec::new();
    if settings.release {
        result.push("--release".to_owned());
    }
    if let Some(path) = settings.config_path()? {
        result.push("--config".to_owned());
        result.push(path);
    }
    for value in settings.defines {
        result.push("--define".to_owned());
        result.push(value);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let args = [
            "--define",
            "b=key=--build-filter=literal",
            "--build-filter",
            "lib/a",
            "--release",
            "--build-filter=lib/b",
        ];
        assert_eq!(
            configuration_arguments(&args.map(str::to_owned)).unwrap(),
            ["--release", "--define", "b=key=--build-filter=literal"]
        );
        assert_eq!(
            configuration_arguments(&["--force-aot".to_owned(), "-dr".to_owned()]).unwrap(),
            ["--release"]
        );
        assert_eq!(
            configuration_arguments(&["--config".to_owned(), "--force-aot".to_owned()]).unwrap(),
            ["--config", "build.--force-aot.yaml"]
        );
        assert_eq!(
            configuration_arguments(&["--force-jit".to_owned(), "-d".to_owned()]).unwrap(),
            Vec::<String>::new()
        );
    }
}
