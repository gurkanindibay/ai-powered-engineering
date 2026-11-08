//! Turkish text folding shared by ledger designation, reconciliation matching,
//! and tenant slug generation.

/// Case- and diacritic-insensitive form of Turkish text for matching bank
/// narratives, which arrive upper-cased and often ASCII-only ("EKIM 2026",
/// "EYLUL 2026"): lower-cases and maps ı/i̇/ş/ğ/ü/ö/ç to their ASCII letters.
///
/// Lower-casing `İ` (U+0130) yields `i` followed by U+0307 COMBINING DOT ABOVE;
/// the combining dot is dropped so that `İ`, `I`, `ı`, and `i` all fold to `i`.
/// Decomposed (NFD) input such as `S` + U+0327 is folded the same way.
pub fn fold_turkish(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| !matches!(c, '\u{0307}' | '\u{0306}' | '\u{0308}' | '\u{0327}'))
        .map(|c| match c {
            'ı' => 'i',
            'ş' => 's',
            'ğ' => 'g',
            'ü' => 'u',
            'ö' => 'o',
            'ç' => 'c',
            other => other,
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::fold_turkish;

    #[test]
    fn folds_turkish_letters_in_both_cases() {
        let cases = [
            ("İSTANBUL", "istanbul"),
            ("ISPARTA", "isparta"),
            ("ılık", "ilik"),
            ("EKİM 2026", "ekim 2026"),
            ("ŞUBAT", "subat"),
            ("Ağustos", "agustos"),
            ("ÜSKÜDAR", "uskudar"),
            ("ÖĞRETMEN", "ogretmen"),
            ("ÇAĞLAYAN", "caglayan"),
            ("Yıldız Park Evleri", "yildiz park evleri"),
        ];
        for (input, expected) in cases {
            assert_eq!(fold_turkish(input), expected, "{input}");
        }
    }

    #[test]
    fn folds_decomposed_input_like_composed_input() {
        // "Şiş" written with combining cedilla (NFD) and "İ" as I + combining dot.
        assert_eq!(fold_turkish("S\u{0327}is\u{0327}"), "sis");
        assert_eq!(fold_turkish("I\u{0307}zmir"), "izmir");
        assert_eq!(fold_turkish("g\u{0306}u\u{0308}o\u{0308}c\u{0327}"), "guoc");
    }

    #[test]
    fn keeps_punctuation_and_whitespace() {
        assert_eq!(fold_turkish("  A-Blok / D:14 "), "  a-blok / d:14 ");
    }
}
