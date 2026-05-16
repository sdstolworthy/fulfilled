/// Breakpoint constants. Architecture §1.
///
/// `compactMax` is the **exclusive** upper bound for compact (so `< 600` is
/// compact, `>= 600` is medium). `mediumMax` is the same: `< 1024` is medium,
/// `>= 1024` is expanded. Aligning to Material 3's window-size classes.
class Breakpoints {
  const Breakpoints._();

  static const double compactMax = 600;
  static const double mediumMax = 1024;
}
