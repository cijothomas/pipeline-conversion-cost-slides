# rename-bench

Micro-benchmarks supporting the "Renaming an Attribute Should Be Cheap" slide.

## Run

```bash
cargo bench --bench rename
```

Output: criterion prints mean ± stderr per case to the terminal, and writes
an HTML report to `target/criterion/report/index.html`.

## Cases

| # | Bench id | What |
|---|---|---|
| 1 | `1_string_swap` | bare `String` reassignment |
| 2 | `2_top_level_field` | direct field write on a struct |
| 3 | `3_vec_attrs_8` | `Vec<(String,String)>` of 8 attrs, linear scan |
| 4 | `4_hashmap_attrs_8` | `HashMap<String,String>` of 8 attrs |
| 5 | `5_batch_500_records` | case 4 across 500 records |

All cases rename `exception.type` → `exception.kind`.
