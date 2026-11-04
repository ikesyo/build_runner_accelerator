//! Opt-in, allocation-free production scanner timing. Input setup is untimed.
use super::declares_part_directive;
use std::hint::black_box;
use std::time::Instant;

#[test]
#[ignore = "performance measurement; run release with --ignored --nocapture"]
fn part_scanner_benchmark() {
    let mut inputs = Vec::new();
    for size in [128, 4096, 65536] {
        for case in [
            "absent",
            "early",
            "late",
            "identifiers",
            "dense-p",
            "late-dense-p",
        ] {
            let filler = match case {
                "identifiers" => "var departure = 123; // parts\n",
                "dense-p" | "late-dense-p" => "pppppppppppppppppppppppppppppppp\n",
                _ => "final value = 123; // ordinary Dart code\n",
            };
            let body = filler.repeat(size / filler.len() + 1);
            let source = match case {
                "early" => format!("part 'model.g.dart';\n{body}"),
                "late" => format!("{body}part 'model.g.dart';"),
                "late-dense-p" => format!("// ordinary prefix\n{body}\npart 'model.g.dart';"),
                _ => body,
            };
            inputs.push((format!("{size}-{case}"), source, "model.g.dart"));
        }
    }
    inputs.push((
        "fixture-model".to_owned(),
        include_str!("../../../fixtures/riverpod_app/lib/model.dart").to_owned(),
        "model.g.dart",
    ));
    inputs.push((
        "fixture-secondary".to_owned(),
        include_str!("../../../fixtures/riverpod_app/lib/secondary.dart").to_owned(),
        "secondary.g.dart",
    ));
    inputs.push((
        "fixture-json".to_owned(),
        include_str!("../../../fixtures/current_json_app/lib/model_01.dart").to_owned(),
        "model_01.g.dart",
    ));
    for (case, source, expected) in inputs {
        let repeats = (4_000_000 / source.len()).max(100);
        for sample in 0..9 {
            let start = Instant::now();
            for _ in 0..repeats {
                black_box(declares_part_directive(
                    black_box(&source),
                    black_box(expected),
                ));
            }
            eprintln!(
                "part-scan,{case},{},{sample},{:.3}",
                source.len(),
                start.elapsed().as_secs_f64() * 1e9 / repeats as f64
            );
        }
    }
}

#[test]
fn dense_candidates_do_not_hide_later_keywords_or_identifier_boundaries() {
    let dense = "p".repeat(65536);
    assert!(!declares_part_directive(&dense, "model.g.dart"));
    assert!(!declares_part_directive(
        &format!("{dense}part 'model.g.dart';"),
        "model.g.dart"
    ));
    assert!(declares_part_directive(
        &format!("const payload = '{dense}';\npart 'model.g.dart';"),
        "model.g.dart"
    ));
}

#[test]
fn scanner_candidate_offsets_and_tails_preserve_conservative_decisions() {
    for offset in 0..=128 {
        let prefix = "é ordinary code; ".repeat(offset);
        for (tail, expected) in [
            ("", false),
            ("p", false),
            ("pa", false),
            ("par", false),
            ("part", false),
            ("part 'model.g.dart';", true),
            ("part 'other.dart';", false),
            ("departure 'model.g.dart';", false),
            ("part /* unterminated", true),
            ("part 'unterminated", true),
            ("part 'escaped\\uri';", true),
            ("part of 'model.g.dart';", false),
        ] {
            assert_eq!(
                declares_part_directive(&format!("{prefix}{tail}"), "model.g.dart"),
                expected,
                "offset={offset} tail={tail:?}"
            );
        }
    }
}
