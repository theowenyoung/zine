# Zine Contributor Guide

## Prerequisites
- Install [Zig 0.15.1](https://ziglang.org/download/) and make sure `zig version` prints `0.15.1`.
- Install Git; the workflow assumes commands are run from the repo root (`zine-fork/zine`).
- Optional but helpful: `mise` (to manage Zig), a terminal with UTF-8, and an editor that understands Zig's LSP (VS Code + `ziglang` extension or Helix/Neovim with built-in Zig support).

## Project Layout
- `src/` – core CLI sources. Entry point is `src/main.zig`; rendering logic lives in `src/root.zig`, `src/Variant.zig`, and `src/worker.zig`.
- `build/` – helper tools (e.g. `build/camera.zig` used by snapshot tests).
- `tests/` – snapshot fixtures grouped by feature (`tests/rendering/*`, `tests/content-scanning/*`, etc.).
- `zig-out/` – build artifacts when you install binaries (`zig build install`). Git ignores this; delete it if you need a clean slate.
- `frontmatter.ziggy-schema` – Ziggy schema shared by unit tests and tooling. Update it when frontmatter attributes change.

## Everyday Commands
```sh
# Compile the zine CLI (Debug)
zig build

# Run the built tool against the sample site in standalone-test/
zig build run

# Produce an optimized binary
zig build -Doptimize=ReleaseFast

# Execute snapshot + integration tests
zig build test
```
`zig build test` regenerates snapshots and stages them with `git add`; inspect diffs in `tests/**/snapshot*` before committing.

## Working on the Codebase
1. **Create a branch**: `git switch -c feat/my-improvement`.
2. **Edit**: Zig has no formatter yet for whole projects; run `zig fmt path/to/file.zig` on changed files.
3. **Quick feedback**: use `zig build` after small edits—Zig’s error messages point directly to files/lines.
4. **Update tests**: after behavior changes, rerun `zig build test` and review any new or modified snapshots.
5. **Commit**: use concise, present-tense messages (e.g. `feat: add taxonomy list rendering`).

## Using the CLI Locally
```sh
# Build into zig-out/bin/zine and install assets under zig-out/
zig build install

# Serve a site from your project (replace with your path)
zig-out/bin/zine /path/to/site
```
By default the executable looks for `zine.ziggy` in the working directory. Use `--help` for all runtime flags (draft mode, profiling, etc.).

## Working with Taxonomies
1. **Declare them in `zine.ziggy`:**
   ```zig
   const root = @import("root.zig");

   pub const site = root.Site{
       .host_url = "https://example.com",
       .layouts_dir_path = "layouts",
       .content_dir_path = "content",
       .assets_dir_path = "assets",
       .taxonomies = &.{
           .{
               .name = "tags",
               .paginate_by = 10,
               .paginate_path = "page",
               .render = true,
           },
       },
   };
   ```
   - `name` must contain ASCII letters/digits/`_-`.
  - When `render = true`, the renderer expects templates in `layouts/`:
    * `taxonomy_list.shtml` (or `layouts/tags/list.shtml` for a specific taxonomy).
    * `taxonomy_single.shtml` (or `layouts/tags/single.shtml`).
     These templates get the usual `$site`, `$page` plus `$taxonomy` (list context) and `$taxonomy_term` (term page); the current path/url are available via `$current_path`/`$current_url`.

2. **Assign terms in page frontmatter:**
   ```zig
   ++++
   const root = @import("root.zig");

   pub const frontmatter = .{
       .title = "Zig 语言初体验",
       .taxonomies = .{
           .tags = &.{ "zig", "static-site" },
       },
   };
   ++++
   ```
   Invalid names/empty terms/heterogeneous arrays are reported during `zig build test`.

3. **Render the pages:**
   - `zig build` or `zig build install` writes taxonomy list/term HTML under the same output tree as pages, e.g. `tags/index.html`, `tags/zig/index.html`.
   - During development `zig build run` will also expose taxonomy routes if your sample site includes them.

4. **Test coverage:**
   - Add fixture sites under `tests/rendering/` (e.g. `tests/rendering/taxonomies/...`) and run `zig build test`.
   - Snapshot files (`snapshot/` and `snapshot.txt`) capture both rendered HTML and CLI diagnostics so regressions are easy to spot.

## Debugging Tips for Zig Newcomers
- **Read stack traces**: Zig prints exact call stacks; the last frame is usually in `src/root.zig` or `src/worker.zig`.
- **Print debugging**: `std.debug.print("value={d}\n", .{x});` works anywhere; remember to remove noise before committing.
- **Allocator errors** (`error.OutOfMemory`): check that arena allocators are reset (`defer arena_state.deinit();`) and avoid holding on to temporary slices.

## Next Steps
- Browse existing templates under `tests/**/snapshot` to see what the renderer outputs.
- Explore `src/context/*.zig` to understand which fields are available inside templates (`$site`, `$page`, `$taxonomy`, etc.).
- When adding features, keep the docs in sync—update `README.md` and the docs site if public behavior changes. Document your testing steps in PR descriptions for reviewers.***
