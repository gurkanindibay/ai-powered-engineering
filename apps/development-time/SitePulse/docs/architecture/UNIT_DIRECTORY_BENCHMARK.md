# Unit directory filter and sort benchmark

Run from `flutter/` with:

```text
flutter test --no-pub test/unit_directory_benchmark_test.dart --reporter=expanded
```

The benchmark prebuilds unit records, then measures the combined resident query filter, result-list allocation, and natural unit sort. It warms up once and reports the median of five samples. Object creation, widget layout, network access, and database work are excluded. The separate `sp_directory_scaffold_test.dart` verifies that a 1,000 or 10,000 unit input builds fewer than 25 rows on the initial page.

## Local result

Recorded on Linux x86_64 with an Intel Core Ultra 7 155H, using the Dart VM test runner:

| Units | Median filter and sort |
| ---: | ---: |
| 1,000 | 10.6 ms |
| 10,000 | 133.1 ms |

The 1,000 unit result is below the design target of 200 ms. At 10,000 units the local operation remains below 200 ms. This supports client-side filtering and sorting for the current directory size, with local page rendering capped at 25 rows by default. Recheck on representative mobile hardware before raising the expected directory size; move search and paging server-side if measured updates exceed the 200 ms target.
