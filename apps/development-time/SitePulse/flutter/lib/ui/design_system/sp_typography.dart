/// Font-size tokens for screens that set a size explicitly (prefer the theme's
/// text styles). Sizes never go below the 12 px floor.
abstract final class SpFontSize {
  /// Secondary lines, captions, chips.
  static const double caption = 12;

  /// Body text in dense cards and lists.
  static const double body = 13;

  /// Section headings inside a page.
  static const double title = 15;
}
